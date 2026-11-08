// vn_server.cpp -- see vn_server.h. Frame layout (analysis/FINDINGS.md 20):
//   0 op, 1 value type (bit 7: notification), 2 property, 3 0,
//   4 / 6 / 8 index 1-3 (u16 LE), 10 mask (ffff; 0000 in notifications),
//   12 body length, 14 sequence number, 16 0 (u32), 20 body.
// Type 1d = a read / an action without a body; every other type is a write,
// which the LPU echoes byte for byte before it acts on it.

#include "vn_server.h"

#include <stdio.h>
#include <string.h>

#include <algorithm>
#include <cmath>

namespace lpd {

namespace {

constexpr uint8_t kStr = 0x00, kU32 = 0x01, kBool = 0x02, kFloat = 0x03, kBlob = 0x05, kPage = 0x0a, kNoBody = 0x1d;
constexpr uint8_t kFixture = 0x1f, kAction = 0x28, kPlaybackObj = 0x29, kCueObj = 0x2b, kGlobal = 0x2c, kProg = 0x2d,
                  kArtnet = 0x0a, kSacn = 0x0b;
constexpr uint32_t kNotifyTtl = 15000;  // ms a client keeps getting notifications without traffic
constexpr int kBlockSize = 800, kPerBlock = 16;
constexpr uint32_t kMaxCues = 48;  // per playback, as the LPU

uint32_t u32(const uint8_t *b, size_t len) { return len >= 4 ? b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24 : 0; }

float f32(const uint8_t *b, size_t len) {
  float f = 0;
  if (len >= 4) memcpy(&f, b, 4);
  return f;
}

void putU32(uint8_t *b, uint32_t v) {
  b[0] = v, b[1] = v >> 8, b[2] = v >> 16, b[3] = v >> 24;
}

void putF32(uint8_t *b, float f) { memcpy(b, &f, 4); }

std::string str(const uint8_t *b, size_t len) {
  size_t n = 0;
  while (n < len && b[n]) n++;
  return std::string((const char *)b, n);
}

std::string ipText(uint32_t ip) {
  char buf[16];
  snprintf(buf, sizeof buf, "%u.%u.%u.%u", (unsigned)(ip >> 24), (unsigned)(ip >> 16 & 255),
           (unsigned)(ip >> 8 & 255), (unsigned)(ip & 255));
  return buf;
}

int hexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  c |= 0x20;
  return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

// Programmer attribute 6-16 (the EDIT sliders) -> engine attribute
// (dled_flutter/lib/core/cue_codec.dart otherAttrs).
const Attr kOtherAttr[11] = {kCol, kSh, kGobo, kRota, kPrism, kFocus, kIris, kFrost, kZoom, kC1, kC2};

uint16_t clampU16(double v) { return v < 0 ? 0 : (v > 65535 ? 65535 : (uint16_t)std::lround(v)); }

int16_t recordI16(const uint8_t *rec, int at) { return (int16_t)(rec[at] | rec[at + 1] << 8); }
uint16_t recordU16(const uint8_t *rec, int at) { return rec[at] | rec[at + 1] << 8; }

const Cue *cueAt(const Playback &p, int cue) { return cue >= 0 && cue < (int)p.cues.size() ? &p.cues[cue] : nullptr; }

}  // namespace

VnServer::VnServer(Engine &engine, Send send) : engine_(engine), send_(std::move(send)) {
  for (int &c : lastCue_) c = -1;
  for (int a = 0; a < 17; a++) attrs_[a] = attrDefault(a);
}

// --- frames -------------------------------------------------------------------

std::vector<uint8_t> VnServer::frame(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint16_t i2, uint16_t i3,
                                     const uint8_t *body, size_t len, uint16_t seq, bool notification) const {
  std::vector<uint8_t> d(20 + len, 0);
  d[0] = op, d[1] = notification ? type | 0x80 : type, d[2] = prop;
  d[4] = i1, d[5] = i1 >> 8, d[6] = i2, d[7] = i2 >> 8, d[8] = i3, d[9] = i3 >> 8;
  d[10] = d[11] = notification ? 0 : 0xff;
  d[12] = len, d[13] = len >> 8, d[14] = seq, d[15] = seq >> 8;
  if (len) memcpy(d.data() + 20, body, len);
  return d;
}

void VnServer::reply(const Frame &f, Peer to, uint8_t type, const uint8_t *body, size_t len) {
  send(frame(f.op, type, f.prop, f.i1, f.i2, f.i3, body, len, f.seq, false), to);
}

void VnServer::replyU32(const Frame &f, Peer to, uint8_t type, uint32_t v) {
  uint8_t b[4];
  putU32(b, v);
  reply(f, to, type, b, 4);
}

void VnServer::replyStr(const Frame &f, Peer to, const std::string &s) {
  reply(f, to, kStr, (const uint8_t *)s.c_str(), s.size() + 1);
}

void VnServer::notify(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint16_t i2, uint16_t i3,
                      const uint8_t *body, size_t len) {
  std::vector<uint8_t> d = frame(op, type, prop, i1, i2, i3, body, len, 0, true);
  for (const Seen &c : clients_) send(d, c.peer);
}

void VnServer::notifyU32(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint32_t v) {
  uint8_t b[4];
  putU32(b, v);
  notify(op, type, prop, i1, 0, 0, b, 4);
}

// "Something changed here" (01 00 with a change code); the app reads it again.
void VnServer::changed(uint8_t op, uint16_t i1, uint16_t i2, uint32_t code) {
  uint8_t b[4];
  putU32(b, code);
  notify(op, kU32, 0x00, i1, i2, 0, b, 4);
}

// --- the way in ----------------------------------------------------------------

// The LPD-1 introduces itself as what it is (its own name and version), not
// as an LPU-1: apps find it by the protocol, not by the label.
std::string VnServer::identifyXml() const {
  return "<?xml version=\"1.0\" ?> <visual_identify label=\"LPD-1\"> <version>1.0</version> "
         "<os>Embedded</os> <ip>" +
         ipText(dev_.ip) + "</ip> <port>" + std::to_string(dev_.port) + "</port> </visual_identify>";
}

void VnServer::handle(const uint8_t *data, size_t len, Peer from, uint32_t now) {
  if (len == 0) return;
  if (from.ip == dev_.ip && from.port == dev_.port) return;  // our own broadcasts
  if (len > 5 && memcmp(data, "<?xml", 5) == 0) {
    // another LPU announcing itself: its answers look like writes, and echoing
    // them starts an endless loop with it (seen with the emulator, 2026-10-23)
    if (std::find(otherLpus_.begin(), otherLpus_.end(), from.ip) == otherLpus_.end()) otherLpus_.push_back(from.ip);
    return;
  }
  if (std::find(otherLpus_.begin(), otherLpus_.end(), from.ip) != otherLpus_.end()) return;

  // every client gets the notifications while it keeps talking
  bool known = false;
  for (Seen &c : clients_) {
    if (c.peer == from) c.at = now, known = true;
  }
  if (!known) {
    if (clients_.size() >= 16) clients_.erase(clients_.begin());
    clients_.push_back({from, now});
  }

  if (len == 1 && data[0] == 0xff) return;  // keepalive
  if (len >= 15 && memcmp(data, "visual_identify", 15) == 0) {
    std::string x = identifyXml();
    send_((const uint8_t *)x.c_str(), x.size() + 1, from);
    return;
  }
  if (len < 20 && data[0] == 0) {
    shortProperty(data, len, from);
    return;
  }
  if (len < 20) return;
  Frame f;
  f.op = data[0], f.type = data[1], f.prop = data[2];
  f.i1 = data[4] | data[5] << 8, f.i2 = data[6] | data[7] << 8, f.i3 = data[8] | data[9] << 8;
  f.seq = data[14] | data[15] << 8;
  size_t bodyLen = data[12] | data[13] << 8;
  f.body = data + 20;
  f.len = std::min(bodyLen, len - 20);
  if (f.type & 0x80) return;  // a notification: not for us
  // At most 48 cues per playback: the LPU does not answer a cue count above
  // 48 (no echo, nothing changes; measured 2026-10-28) - nor, we assume,
  // writes to a cue past 48.
  if (f.op == kPlaybackObj && f.prop == 0x48 && f.type != kNoBody && u32(f.body, f.len) > kMaxCues) return;
  if (f.op == kCueObj && f.type != kNoBody && f.i2 >= kMaxCues) return;
  // the box's own limit (RAM): a block that would go over kMaxRecords is not
  // taken either, the same way
  if (f.op == kCueObj && f.prop == 0x47 && f.type != kNoBody && !blockFits(f)) return;
  if (f.type == kNoBody) {
    request(f, data, len, from, now);
  } else {
    send_(data, len, from);  // the LPU echoes every write
    write(f, now);
  }
  announce();
}

void VnServer::tick(uint32_t now) {
  // forget clients that went quiet
  clients_.erase(std::remove_if(clients_.begin(), clients_.end(),
                                [&](const Seen &c) { return now - c.at > kNotifyTtl; }),
                 clients_.end());
  engine_.update(now);  // fades, follows and releases that ended
  announce();
  if ((int32_t)(now - nextAnnounce_) >= 0 && dev_.ip) {
    nextAnnounce_ = now + 1000;
    std::string x = identifyXml();
    send_((const uint8_t *)x.c_str(), x.size() + 1, Peer{kBroadcast, dev_.port});
  }
}

// --- short device properties (9-byte frames) -------------------------------------

void VnServer::shortProperty(const uint8_t *data, size_t len, Peer from) {
  if (len < 2) return;
  uint8_t prop = data[1];
  if (len > 9) {  // a write: [00 prop 0 x6 len value]
    if ((prop == 0x02 || prop == 0x04) && len >= 13) {  // IP / mask, 4 bytes + 00 00; all 0 = DHCP
      uint32_t v = (uint32_t)data[9] << 24 | data[10] << 16 | data[11] << 8 | data[12];
      (prop == 0x02 ? dev_.staticIp : dev_.staticMask) = v;
      showVersion_++;
      networkVersion_++;
    }
    if (prop == 0x12) {
      dev_.alias = str(data + 9, std::min<size_t>(data[8], len - 9));
      showVersion_++;
      notifyU32(0x02, kU32, 0x00, 0, 0);
    }
    send_(data, len, from);
    return;
  }
  uint8_t v[32] = {};
  size_t n = 4;
  switch (prop) {
    case 0x00: memcpy(v, dev_.mac, 6), n = 6; break;
    case 0x03: putU32(v, __builtin_bswap32(dev_.subnet)), n = 6; break;  // 255 255 255 0, 0 0
    case 0x09: v[0] = 1, v[1] = 0, n = 2; break;                           // firmware 1.0 (the LPD-1's own)
    case 0x0a: v[0] = 1, v[1] = 0, n = 2; break;                           // board 1.0
    case 0x11:
      n = std::min<size_t>(dev_.alias.size(), sizeof v - 1) + 1;
      memcpy(v, dev_.alias.c_str(), n - 1);
      break;
    case 0x34: putU32(v, dev_.artnetUniverse); break;
    case 0xce: putU32(v, dev_.artnetEnabled); break;
    case 0xea: putU32(v, 1); break;  // meaning unknown; the LPU said 1 (2026-10-22)
    case 0xef: putU32(v, dev_.sacnEnabled); break;
    case 0xf0: putU32(v, dev_.sacnUniverse); break;
    default: break;
  }
  uint8_t out[9 + sizeof v] = {0, prop};
  out[8] = n;
  memcpy(out + 9, v, n);
  send_(out, 9 + n, from);
}

// --- fixtures / playbacks as the app reads them -------------------------------------

std::string VnServer::definition(int slot) const {
  const FixtureInfo &i = info_[slot];
  if (!engine_.show().fixtures[slot].patched) return "\"\",\"\",\"\",\"\"";
  return "\"" + i.manufacturer + "\",\"" + i.model + "\",\"" + i.mode + "\",\"" + i.profile + "\"";
}

uint32_t VnServer::fixtureState(int slot) const {
  const Fixture &f = engine_.show().fixtures[slot];
  if (!f.patched) return 0xffff0000;
  uint32_t flags = 0;
  if (f.has(0x02) || f.has(0x03)) {  // the LPU ignores the flags without pan / tilt
    flags = (f.invertPan ? 1 : 0) | (f.invertTilt ? 2 : 0) | (f.swapPanTilt ? 4 : 0);
  }
  return (uint32_t)f.address << 16 | flags;
}

void VnServer::playbackState(int pb, uint8_t out[4], uint32_t now) {
  const Playback &p = engine_.show().playbacks[pb];
  if (!used_[pb] && p.cues.empty()) {
    out[0] = out[1] = out[2] = 0, out[3] = 0xff;
    return;
  }
  int phase = engine_.phase(pb, now), cur = engine_.cueIndex(pb);
  int state = phase != 1 ? phase : (p.cues.empty() ? 0 : 1);
  out[0] = p.goMode << 4 | (p.exclusive ? 2 : 0) | (p.background ? 1 : 0);
  out[1] = p.repeat << 4 | state;
  out[2] = p.cues.size();
  out[3] = cur >= 0 ? cur : 0xff;
}

// The first free DMX address for [channels] after the patched fixtures, as the
// LPU picks it when a fixture is added (FINDINGS 20, patch screen); 1 when it
// does not fit.
uint16_t VnServer::nextAddress(int channels) const {
  std::vector<std::pair<int, int>> used;
  for (const Fixture &f : engine_.show().fixtures) {
    if (f.patched && f.address < 0xffff) used.push_back({f.address, f.address + std::max<int>(f.count, 1) - 1});
  }
  std::sort(used.begin(), used.end());
  int addr = 1;
  for (auto &u : used) {
    if (addr + channels - 1 < u.first) break;
    addr = std::max(addr, u.second + 1);
  }
  return addr + channels - 1 <= 512 ? addr : 1;
}

void VnServer::playbackChanged(int pb) { changed(kPlaybackObj, pb, 0, 3); }

// The playbacks' events (engine.h PbEvent) as the LPU's notifications:
// active cue 2f and phase 24.
void VnServer::announce() {
  for (const PbEvent &e : engine_.takeEvents()) {
    int pb = e.pb;
    switch (e.kind) {
      case PbEvent::kStart:
      case PbEvent::kFollow:
        if (e.cue != lastCue_[pb]) notifyU32(kPlaybackObj, kU32, 0x2f, pb, e.cue);
        lastCue_[pb] = e.cue;
        if (e.kind == PbEvent::kStart) notifyU32(kPlaybackObj, kU32, 0x24, pb, 2);
        break;
      case PbEvent::kRestart:
        notifyU32(kPlaybackObj, kU32, 0x24, pb, 4);
        notifyU32(kPlaybackObj, kU32, 0x24, pb, 2);
        break;
      case PbEvent::kDone: notifyU32(kPlaybackObj, kU32, 0x24, pb, 3); break;
      case PbEvent::kReleasing: notifyU32(kPlaybackObj, kU32, 0x24, pb, 4); break;
      case PbEvent::kReleased:
        notifyU32(kPlaybackObj, kU32, 0x2f, pb, 0xff);
        notifyU32(kPlaybackObj, kU32, 0x24, pb, 1);
        lastCue_[pb] = -1;
        break;
    }
  }
}

void VnServer::readBlock(int pb, int cue, int block, uint8_t out[kBlockSize]) const {
  memset(out, 0, kBlockSize);
  const Cue *c = cueAt(engine_.show().playbacks[pb], cue);
  if (!c) return;
  for (const Record &r : c->records) {
    if (r.slot / kPerBlock == block) memcpy(out + (r.slot % kPerBlock) * kRecordSize, r.bytes, kRecordSize);
  }
}

bool VnServer::blockFits(const Frame &f) const {
  const Show &show = engine_.show();
  size_t total = 0;
  for (const Playback &p : show.playbacks) {
    for (const Cue &c : p.cues) total += c.records.size();
  }
  const Cue *c = f.i1 < kPlaybacks ? cueAt(show.playbacks[f.i1], f.i2) : nullptr;
  int added = 0;
  for (int r = 0; r < kPerBlock && (size_t)(r + 1) * kRecordSize <= f.len; r++) {
    bool any = false;
    for (int i = 0; i < kRecordSize; i++) any |= f.body[r * kRecordSize + i] != 0;
    int slot = f.i3 * kPerBlock + r;
    bool had = c && std::any_of(c->records.begin(), c->records.end(), [&](const Record &x) { return x.slot == slot; });
    added += (any ? 1 : 0) - (had ? 1 : 0);
  }
  return added <= 0 || total + added <= kMaxRecords;
}

void VnServer::writeBlock(int pb, int cue, int block, const uint8_t *data, size_t len) {
  Cue &c = engine_.show().playbacks[pb].cues[cue];
  for (int r = 0; r < kPerBlock; r++) {
    int slot = block * kPerBlock + r;
    const uint8_t *rec = (size_t)(r + 1) * kRecordSize <= len ? data + r * kRecordSize : nullptr;
    bool any = false;
    for (int i = 0; rec && i < kRecordSize; i++) any |= rec[i] != 0;
    auto it = std::find_if(c.records.begin(), c.records.end(), [&](const Record &x) { return x.slot == slot; });
    if (!any) {
      if (it != c.records.end()) c.records.erase(it);
      continue;
    }
    if (it == c.records.end()) {
      Record x{(uint8_t)slot, {}};
      memcpy(x.bytes, rec, kRecordSize);
      // keep the records in slot order (the engine does not need it; reads are simpler)
      c.records.insert(std::upper_bound(c.records.begin(), c.records.end(), x,
                                        [](const Record &a, const Record &b) { return a.slot < b.slot; }),
                       x);
    } else {
      memcpy(it->bytes, rec, kRecordSize);
    }
  }
}

// --- reads, deletes and actions (type 1d) ---------------------------------------------

void VnServer::request(const Frame &f, const uint8_t *raw, size_t rawLen, Peer from, uint32_t now) {
  Show &show = engine_.show();
  auto echo = [&] { send_(raw, rawLen, from); };
  if (f.prop == 0x38 && (f.op == kFixture || f.op == kPlaybackObj || f.op == kGlobal)) {  // delete / CLEAR
    echo();
    if (f.op == kFixture && f.i1 < kSlots && show.fixtures[f.i1].patched) {
      show.fixtures[f.i1] = Fixture();
      info_[f.i1] = FixtureInfo();
      std::string d = definition(f.i1);
      notify(kFixture, kStr, 0x07, f.i1, 0, 0, (const uint8_t *)d.c_str(), d.size() + 1);
      changed(kFixture, f.i1, 0, 0x121);
      showVersion_++;
    } else if (f.op == kPlaybackObj && f.i1 < kPlaybacks && (used_[f.i1] || !show.playbacks[f.i1].cues.empty())) {
      engine_.release(f.i1, now);
      show.playbacks[f.i1] = Playback();
      used_[f.i1] = false;
      changed(kPlaybackObj, f.i1, 0, 0x121);
      showVersion_++;
    } else if (f.op == kGlobal) {
      clearProgrammer();
      engine_.programmerClear();
    }
    return;
  }
  if (f.op == kFixture && f.i1 < kSlots) {
    const Fixture &fx = show.fixtures[f.i1];
    switch (f.prop) {
      case 0x05: return replyStr(f, from, fx.patched ? info_[f.i1].name : "");
      case 0x07: return replyStr(f, from, definition(f.i1));
      case 0x0b: return replyU32(f, from, kU32, fx.patched ? fx.address : 0xffff);
      case 0x30: return replyU32(f, from, kU32, fixtureState(f.i1));
      case 0x0d: return replyU32(f, from, kBool, fx.patched && fx.invertPan);
      case 0x0f: return replyU32(f, from, kBool, fx.patched && fx.invertTilt);
      case 0x11: return replyU32(f, from, kBool, fx.patched && fx.swapPanTilt);
      case 0x13: return replyU32(f, from, kBool, fx.patched && fx.virtualDimmer);
      default: break;
    }
  }
  if (f.op == kPlaybackObj && f.i1 < kPlaybacks) {
    const Playback &p = show.playbacks[f.i1];
    uint8_t b[4];
    switch (f.prop) {
      case 0x30: playbackState(f.i1, b, now); return reply(f, from, kU32, b, 4);
      case 0x05: return replyStr(f, from, p.label);
      case 0x17: putF32(b, p.intensity); return reply(f, from, kFloat, b, 4);
      case 0x15: putF32(b, p.speed); return reply(f, from, kFloat, b, 4);
      case 0x3d: return replyU32(f, from, kU32, p.cues.size());
      case 0x2d: return replyU32(f, from, kU32, p.repeat);
      case 0x1d: return replyU32(f, from, kBool, p.background);
      case 0x39: return replyU32(f, from, kBool, p.exclusive);
      case 0x42:  // RELEASE of one playback
        echo();
        engine_.release(f.i1, now);
        return;
      case 0x04: {  // delete cues i2 .. i2 + i3 - 1
        echo();
        Playback &pw = show.playbacks[f.i1];
        int from0 = f.i2, n = std::max<int>(1, f.i3);
        int to = std::min<int>(pw.cues.size(), from0 + n);
        if (from0 < to) {
          pw.cues.erase(pw.cues.begin() + from0, pw.cues.begin() + to);
          engine_.cuesDeleted(f.i1, from0, to - from0, now);
          showVersion_++;
          playbackChanged(f.i1);
          // like the LPU: the deleted cues are announced as changed too
          for (int q = from0; q < to; q++) changed(kCueObj, f.i1, q, 0x121);
        }
        return;
      }
      default: break;
    }
  }
  if (f.op == kCueObj && f.i1 < kPlaybacks) {
    const Cue *c = cueAt(show.playbacks[f.i1], f.i2);
    if (!c && (f.prop == 0x46 || f.prop == 0x05 || f.prop == 0x27 || f.prop == 0x29 || f.prop == 0x2b)) {
      return;  // the LPU does not answer reads of cues that do not exist
    }
    switch (f.prop) {
      case 0x46: {
        uint8_t block[kBlockSize];
        readBlock(f.i1, f.i2, f.i3, block);
        return reply(f, from, kPage, block, kBlockSize);
      }
      case 0x05: return replyStr(f, from, c->label);
      case 0x27: return replyU32(f, from, kU32, c->follow);
      case 0x29: return replyU32(f, from, kU32, c->fadeMs);
      case 0x2b: return replyU32(f, from, kU32, c->delayMs);
      default: break;
    }
  }
  if (f.op == kGlobal) {
    switch (f.prop) {
      case 0x34: return replyU32(f, from, kU32, chooseMode_);
      case 0x3e: return replyU32(f, from, kU32, editPb_);
      case 0x3b: {
        uint8_t b[8];
        for (int i = 0; i < 8; i++) b[i] = selection_ >> (8 * i);
        return reply(f, from, kBlob, b, 8);
      }
      case 0x45: return replyU32(f, from, kBool, attrsSet_);
      // LOAD / RECORD only while the edited playback (3f) is one: otherwise
      // the LPU drops LOAD without an answer and echoes RECORD but records
      // nothing (DMX_ENGINE.md 12, 2026-10-28)
      case 0x36:  // LOAD a cue into the programmer: the echo after the values
        if (editPb_ >= kPlaybacks) return;
        loadCue(f.i1, f.i2, now);
        return echo();
      case 0x37:  // RECORD the programmer into a cue
        echo();
        if (editPb_ < kPlaybacks) recordCue(f.i1, f.i2);
        return;
      default: break;
    }
  }
  if (f.op == kProg && f.prop == 0x32 && f.i1 < 17) {
    const ProgAttr &a = attrs_[f.i1];
    return reply(f, from, a.type, a.body, a.len);
  }
  if (f.op == kArtnet || f.op == kSacn) {
    bool art = f.op == kArtnet;
    if (f.prop == 0x25) return replyU32(f, from, kBool, art ? dev_.artnetEnabled : dev_.sacnEnabled);
    if (f.prop == 0x32) return replyU32(f, from, kU32, art ? dev_.artnetUniverse : dev_.sacnUniverse);
  }
  if (f.op == kAction) {
    switch (f.prop) {
      case 0x4f: return replyU32(f, from, kBool, 0);
      case 0x42:  // RELEASE ALL
        echo();
        engine_.releaseAll(now);
        return;
      case 0x49:  // swap playbacks i1 <-> i2: both stop at once
        echo();
        if (f.i1 < kPlaybacks && f.i2 < kPlaybacks && f.i1 != f.i2) {
          engine_.swapPlaybacks(f.i1, f.i2, now);
          std::swap(used_[f.i1], used_[f.i2]);
          announce();  // both stopped (test live_edit)
          showVersion_++;
          playbackChanged(f.i2);
          playbackChanged(f.i1);
          for (int pb : {(int)f.i1, (int)f.i2}) {
            changed(kPlaybackObj, pb, 0, 0x121);
            changed(kPlaybackObj, pb, 0, 0);
          }
        }
        return;
      default: break;
    }
  }
  echo();  // anything else: echoed, as the LPU does
}

// --- writes ----------------------------------------------------------------------------

void VnServer::write(const Frame &f, uint32_t now) {
  Show &show = engine_.show();
  uint32_t u = u32(f.body, f.len);
  if (f.op == kFixture && f.i1 < kSlots) {
    Fixture &fx = show.fixtures[f.i1];
    FixtureInfo &info = info_[f.i1];
    if (f.prop == 0x08) {  // definition "manufacturer","model","mode","profile"
      std::string s = str(f.body, f.len);
      std::vector<std::string> parts;
      size_t at = 0;
      while (true) {
        size_t next = s.find("\",\"", at);
        parts.push_back(s.substr(at, next == std::string::npos ? std::string::npos : next - at));
        if (next == std::string::npos) break;
        at = next + 3;
      }
      if (parts.size() != 4) return;
      for (std::string &p : parts) {
        if (!p.empty() && p.front() == '"') p.erase(0, 1);
        if (!p.empty() && p.back() == '"') p.pop_back();
      }
      uint8_t codes[64];
      int n = 0;
      for (size_t i = 0; i + 1 < parts[3].size() && n < 64; i += 2) {
        int hi = hexDigit(parts[3][i]), lo = hexDigit(parts[3][i + 1]);
        if (hi < 0 || lo < 0) break;
        codes[n++] = hi << 4 | lo;
      }
      int count = 0;  // the LPU ends a profile at code 00 (DMX_ENGINE.md 14)
      while (count < n && codes[count]) count++;
      bool was = fx.patched;
      uint16_t address = was ? fx.address : nextAddress(std::max(n, 1));
      fx.patched = true;
      fx.address = address;
      fx.count = count;
      memcpy(fx.codes, codes, count);
      if (!was) fx.invertPan = fx.invertTilt = fx.swapPanTilt = fx.virtualDimmer = false, info.name.clear();
      info.manufacturer = parts[0];
      info.model = parts[1].substr(0, 29);
      info.mode = parts[2];
      info.profile = parts[3];
      showVersion_++;
      changed(kFixture, f.i1, 0, 0x14);
      std::string d = definition(f.i1);
      notify(kFixture, kStr, 0x07, f.i1, 0, 0, (const uint8_t *)d.c_str(), d.size() + 1);
      return;
    }
    if (!fx.patched) return;
    showVersion_++;
    switch (f.prop) {
      case 0x0c: fx.address = u; break;
      case 0x06:
        info.name = str(f.body, f.len);
        changed(kFixture, f.i1, 0, 0x121);
        break;
      case 0x0e: fx.invertPan = u; break;
      case 0x10: fx.invertTilt = u; break;
      case 0x12: fx.swapPanTilt = u; break;
      case 0x14:
        fx.virtualDimmer = u;
        notifyU32(kFixture, kBool, 0x13, f.i1, u);
        break;
      default: showVersion_--; break;
    }
    return;
  }
  if (f.op == kPlaybackObj && f.i1 < kPlaybacks) {
    Playback &p = show.playbacks[f.i1];
    switch (f.prop) {
      case 0x48:  // cue count (the upload allocates the cues first)
        used_[f.i1] = true;
        p.cues.resize(std::min<uint32_t>(u, 255));
        showVersion_++;
        notifyU32(kPlaybackObj, kU32, 0x24, f.i1, 1);
        changed(kPlaybackObj, f.i1, 0, 3);
        return;
      case 0x03: {  // INSERT a cue (u: position, ffffffff = at the end)
        if (p.cues.size() >= kMaxCues) return;
        used_[f.i1] = true;
        size_t pos = u == 0xffffffff || u > p.cues.size() ? p.cues.size() : u;
        Cue c;  // the LPU's new cue: fade 2 s, delay 2 s, follow on (read back 2026-10-28)
        c.fadeMs = 2000, c.delayMs = 2000, c.follow = true;
        p.cues.insert(p.cues.begin() + pos, c);
        showVersion_++;
        changed(kCueObj, f.i1, pos, 0);
        playbackChanged(f.i1);
        return;
      }
      case 0x22:  // GO pressed / let go
        notifyU32(kPlaybackObj, kBool, 0x50, f.i1, u ? 1 : 0);
        engine_.goButton(f.i1, u != 0, now);
        return;
      case 0x23:  // FLASH pressed / let go
        engine_.flashButton(f.i1, u != 0, now);
        return;
      case 0x18:
        engine_.setIntensity(f.i1, f32(f.body, f.len), now);
        notify(kPlaybackObj, kFloat, 0x17, f.i1, 0, 0, f.body, std::min<size_t>(f.len, 4));
        return;
      case 0x16:
        engine_.setSpeed(f.i1, f32(f.body, f.len), now);
        p.speed = f32(f.body, f.len);
        notify(kPlaybackObj, kFloat, 0x15, f.i1, 0, 0, f.body, std::min<size_t>(f.len, 4));
        return;
      default: break;
    }
    used_[f.i1] = true;
    showVersion_++;
    switch (f.prop) {
      case 0x06:
        p.label = str(f.body, f.len);
        changed(kPlaybackObj, f.i1, 0, 0x121);
        break;
      case 0x21:
        p.goMode = u < 4 ? (GoMode)u : kGo;
        changed(kPlaybackObj, f.i1, 0, 0x79);
        break;
      case 0x2e:
        p.repeat = u < 4 ? (Repeat)u : kLoop;
        changed(kPlaybackObj, f.i1, 0, 0x123);
        break;
      case 0x1e:
        p.background = u;
        notifyU32(kPlaybackObj, kBool, 0x1d, f.i1, u);
        break;
      case 0x3a:
        p.exclusive = u;
        changed(kPlaybackObj, f.i1, 0, 0x2e);
        break;
      default: showVersion_--; break;
    }
    return;
  }
  if (f.op == kCueObj && f.i1 < kPlaybacks && f.i2 < 255) {
    Playback &p = show.playbacks[f.i1];
    used_[f.i1] = true;
    if (p.cues.size() <= f.i2) p.cues.resize(f.i2 + 1);
    showVersion_++;
    switch (f.prop) {
      case 0x47: {  // a block of 16 records
        if (f.i3 >= 4) return;
        writeBlock(f.i1, f.i2, f.i3, f.body, f.len);
        bool any = false;
        for (size_t i = 0; i < f.len; i++) any |= f.body[i] != 0;
        if (any) changed(kCueObj, f.i1, f.i2, 0x128);
        break;
      }
      // label, fade, delay, condition: the reference app writes several selected
      // cues at once, i3 = how many from cue i2 on (0 / 1 = one; seen
      // 2026-10-28, 2b 01 2c [pb, cue, 2])
      case 0x06:
      case 0x2a:
      case 0x2c:
      case 0x28: {
        int last = std::min<int>(p.cues.size(), f.i2 + std::max<int>(f.i3, 1));
        for (int q = f.i2; q < last; q++) {
          Cue &cq = p.cues[q];
          if (f.prop == 0x06) cq.label = str(f.body, f.len), changed(kCueObj, f.i1, q, 0x121);
          if (f.prop == 0x2a) cq.fadeMs = u, changed(kCueObj, f.i1, q, 0x1a);
          if (f.prop == 0x2c) cq.delayMs = u, changed(kCueObj, f.i1, q, 0x36);
          if (f.prop == 0x28) cq.follow = u, changed(kCueObj, f.i1, q, 0x5a);
        }
        break;
      }
      default: break;
    }
    return;
  }
  if (f.op == kGlobal) {
    switch (f.prop) {
      case 0x3c: {  // fixture selection, bit n = fixture n + 1
        uint8_t b[8] = {};
        memcpy(b, f.body, std::min<size_t>(f.len, 8));
        selection_ = 0;
        for (int i = 0; i < 8; i++) selection_ |= (uint64_t)b[i] << (8 * i);
        engine_.select(selection_);
        notify(kGlobal, kBlob, 0x3b, 0, 0, 0, b, 8);
        // then the programmer values for the app's sliders (test live_edit)
        for (int a = 0; a < 17; a++) notify(kGlobal, attrs_[a].type, 0x32, a, 0, 0, attrs_[a].body, attrs_[a].len);
        break;
      }
      case 0x35:  // 0 = the EDIT page is open
        chooseMode_ = u;
        engine_.setEditing(u == 0, now);
        changed(kGlobal, 0, 0, 0x126);
        break;
      case 0x3f:  // the edited playback; announced only when it changes, as the LPU
        if (editPb_ != u) changed(kGlobal, 0, 0, 0x190);
        editPb_ = u;
        break;
      default: break;
    }
    return;
  }
  if (f.op == kProg && f.prop == 0x33 && f.i1 < 17) {
    ProgAttr &a = attrs_[f.i1];
    a.type = f.type;
    a.len = std::min<size_t>(f.len, sizeof a.body);
    memcpy(a.body, f.body, a.len);
    programmerToEngine(f.i1, now);
    notify(kProg, f.type, 0x32, f.i1, 0, 0, a.body, a.len);
    attrMask_ |= 1u << f.i1;
    if (!attrsSet_) notifyU32(kGlobal, kBool, 0x45, 0, 1);  // after the first value, as the LPU
    attrsSet_ = true;
    return;
  }
  if (f.op == kArtnet || f.op == kSacn) {
    bool art = f.op == kArtnet;
    if (f.prop == 0x26 || f.prop == 0x33) showVersion_++;
    if (f.prop == 0x26) {
      (art ? dev_.artnetEnabled : dev_.sacnEnabled) = u;
      changed(f.op, 0, 0, 0x13);
    } else if (f.prop == 0x33) {
      (art ? dev_.artnetUniverse : dev_.sacnUniverse) = u;
      (art ? dev_.artnetEnabled : dev_.sacnEnabled) = true;
      changed(f.op, 0, 0, 0x13);
      changed(f.op, 0, 0, 0x17);
    }
  }
}

// --- the programmer ----------------------------------------------------------------------

// The value of an attribute nobody set (as the LPU sends them after CLEAR):
// 0 intensity float, 1 / 3 / 5 FX (4 bytes), 2 position (2 floats), 4 colour
// (5 x u16), 6-16 floats.
VnServer::ProgAttr VnServer::attrDefault(int attr) {
  ProgAttr a;
  if (attr == 1 || attr == 3 || attr == 5) a.type = 0x07, a.len = 4;
  if (attr == 2) a.type = 0x06, a.len = 8;
  if (attr == 4) a.type = 0x08, a.len = 10;
  return a;
}

// CLEAR: the LPU announces only the attributes that had a value, on the
// programmer object, then the "programmer set" flag; nothing when it was
// empty (test live_edit).
void VnServer::clearProgrammer() {
  for (int a = 0; a < 17; a++) {
    attrs_[a] = attrDefault(a);
    if (attrMask_ >> a & 1) notify(kProg, attrs_[a].type, 0x32, a, 0, 0, attrs_[a].body, attrs_[a].len);
  }
  if (attrsSet_) notifyU32(kGlobal, kBool, 0x45, 0, 0);
  attrsSet_ = false;
  attrMask_ = 0;
}

void VnServer::programmerToEngine(int attr, uint32_t now) {
  const ProgAttr &a = attrs_[attr];
  // cut off, not rounded, as the LPU records them (0.5 -> 32767, pan 0.3 ->
  // 9830, -0.3 -> -9830; 2026-11-02)
  if (attr == 0) {
    engine_.programmerAttr(kIn, clampU16(std::floor(f32(a.body, a.len) * 65535.0)));
  } else if (attr == 2 && a.len >= 8) {
    auto pos = [](float f) { return clampU16(32767 + std::trunc((f < -1 ? -1 : (f > 1 ? 1 : f)) * 32767.0)); };
    engine_.programmerPosition(pos(f32(a.body, 4)), pos(f32(a.body + 4, 4)));
  } else if (attr == 4 && a.len >= 10) {
    uint16_t c[5];
    for (int i = 0; i < 5; i++) c[i] = recordU16(a.body, 2 * i);
    engine_.programmerColour(c);
  } else if ((attr == 1 || attr == 3 || attr == 5) && a.len >= 4) {
    engine_.programmerFx((FxGen)(attr / 2), Fx(a.body[0], a.body[1], a.body[2], a.body[3]), now);
  } else if (attr >= 6 && attr <= 16) {
    engine_.programmerAttr(kOtherAttr[attr - 6], clampU16(std::floor(f32(a.body, a.len) * 65535.0)));
  }
}

// LOAD: the engine loads the cue (DMX); the app gets the programmer values of
// the cue's first fixture (17 notifications), the "programmer set" flag and
// the cue's fixtures as the selection (what the LPU sent, FINDINGS 20.5a).
void VnServer::loadCue(int pb, int cue, uint32_t now) {
  if (pb >= kPlaybacks) return;
  engine_.load(pb, cue, now);
  const Cue *c = cueAt(engine_.show().playbacks[pb], cue);
  for (int a = 0; a < 17; a++) attrs_[a] = attrDefault(a);
  attrsSet_ = false;
  attrMask_ = 0;
  selection_ = 0;
  const Record *first = nullptr;
  if (c) {
    for (const Record &r : c->records) {
      if (!engine_.show().fixtures[r.slot].patched) continue;
      selection_ |= 1ull << r.slot;
      if (!first || r.slot < first->slot) first = &r;
    }
  }
  if (first) {
    const uint8_t *rec = first->bytes;
    attrsSet_ = true;
    attrMask_ = (1u << 17) - 1;
    putF32(attrs_[0].body, recordU16(rec, 16) / 65535.0f);
    for (int g = 0; g < 3; g++) memcpy(attrs_[1 + 2 * g].body, rec + 4 * g, 4);
    putF32(attrs_[2].body, recordI16(rec, 12) / 32767.0f);
    putF32(attrs_[2].body + 4, recordI16(rec, 14) / 32767.0f);
    memcpy(attrs_[4].body, rec + 20, 10);
    for (int a = 6; a <= 16; a++) putF32(attrs_[a].body, recordU16(rec, 12 + 2 * kOtherAttr[a - 6]) / 65535.0f);
  }
  for (int a = 0; a < 17; a++) notify(kGlobal, attrs_[a].type, 0x32, a, 0, 0, attrs_[a].body, attrs_[a].len);
  notifyU32(kGlobal, kBool, 0x45, 0, attrsSet_);
  engine_.select(selection_);
}

// RECORD: the cue becomes the programmer, every fixture with its own values
// and FX; a fixture without any is not in it, selected or not (2026-11-02,
// DMX_ENGINE.md 12).
void VnServer::recordCue(int pb, int cue) {
  if (pb >= kPlaybacks) return;
  Playback &p = engine_.show().playbacks[pb];
  // only into a cue that exists: the LPU ignores one past the end (the app
  // INSERTs it first; 2026-10-28)
  if (cue < 0 || cue >= (int)p.cues.size()) return;
  // on the heap only while recording (RAM is short at power-up)
  std::vector<uint8_t> blocks(4 * kBlockSize);
  int count = 0;
  for (int slot = 0; slot < kSlots; slot++) {
    if (engine_.programmerRecord(slot, blocks.data() + slot * kRecordSize)) count++;
  }
  // the box's own limit (RAM), as for a block written by the app
  size_t total = 0;
  for (const Playback &q : engine_.show().playbacks) {
    for (const Cue &c : q.cues) total += c.records.size();
  }
  if (total - p.cues[cue].records.size() + count > kMaxRecords) return;
  for (int b = 0; b < 4; b++) writeBlock(pb, cue, b, blocks.data() + b * kBlockSize, kBlockSize);
  showVersion_++;
  changed(kCueObj, pb, cue, 0x6b);
  changed(kCueObj, pb, cue, 0x128);
}

}  // namespace lpd
