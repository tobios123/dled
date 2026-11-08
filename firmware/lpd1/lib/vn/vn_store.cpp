// vn_store.cpp -- VnServer::saveShow / loadShow: the LPD-1's own show file
// (not the app's .show XML; the box only needs to keep its show over a
// reset). Little-endian, strings as [u8 length][bytes]:
//
//   "LPD1" u16 version (2; 1 is read too)
//   device: alias, u32 artnetUniverse, u8 artnetEnabled, u32 sacnUniverse, u8 sacnEnabled,
//     (version 2:) u32 staticIp, u32 staticMask (0 = DHCP)
//   u8 fixtures, per fixture: u8 slot, u16 address, u8 flags (1 invert pan,
//     2 invert tilt, 4 swap, 8 virtual dimmer), u8 count, count x u8 codes,
//     name, manufacturer, model, mode, profile
//   u8 playbacks, per playback: u8 index, u8 goMode, u8 repeat, u8 flags
//     (1 background, 2 exclusive), f32 intensity, f32 speed, label,
//     u16 cues, per cue: u32 fadeMs, u32 delayMs, u8 follow, label,
//     u8 records, per record: u8 slot, 50 bytes
//
// The intensity memory is not kept: the LPU loses it at a power cycle too
// (lpd/DMX_ENGINE.md 8).

#include <string.h>

#include "vn_server.h"

namespace lpd {

namespace {

constexpr uint16_t kVersion = 2;

// Writes into pieces of at most [max] bytes (each reserved at once).
struct Writer {
  std::vector<std::vector<uint8_t>> &out;
  size_t max;
  void u8(uint8_t v) {
    if (out.empty() || out.back().size() >= max) {
      out.emplace_back();
      out.back().reserve(max);
    }
    out.back().push_back(v);
  }
  void u16(uint16_t v) { u8(v), u8(v >> 8); }
  void u32(uint32_t v) { u16(v), u16(v >> 16); }
  void f32(float f) {
    uint32_t v;
    memcpy(&v, &f, 4);
    u32(v);
  }
  void str(const std::string &s) {
    size_t n = s.size() < 255 ? s.size() : 255;
    u8(n);
    bytes((const uint8_t *)s.data(), n);
  }
  void bytes(const uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) u8(b[i]);
  }
};

struct Reader {
  const uint8_t *p, *end;
  bool ok = true;
  Reader(const uint8_t *data, const uint8_t *e) : p(data), end(e) {}
  bool need(size_t n) {
    if ((size_t)(end - p) < n) ok = false;
    return ok;
  }
  uint8_t u8() { return need(1) ? *p++ : 0; }
  uint16_t u16() {
    uint16_t a = u8();
    return a | u8() << 8;
  }
  uint32_t u32() {
    uint32_t a = u16();
    return a | (uint32_t)u16() << 16;
  }
  float f32() {
    uint32_t v = u32();
    float f;
    memcpy(&f, &v, 4);
    return f;
  }
  std::string str() {
    size_t n = u8();
    if (!need(n)) return "";
    std::string s((const char *)p, n);
    p += n;
    return s;
  }
  void bytes(uint8_t *out, size_t n) {
    if (!need(n)) return;
    memcpy(out, p, n);
    p += n;
  }
};

}  // namespace

std::vector<uint8_t> VnServer::saveShow() const {
  std::vector<uint8_t> d;
  for (const auto &p : saveShowPieces()) d.insert(d.end(), p.begin(), p.end());
  return d;
}

std::vector<std::vector<uint8_t>> VnServer::saveShowPieces(size_t piece) const {
  std::vector<std::vector<uint8_t>> d;
  Writer w{d, piece};
  w.bytes((const uint8_t *)"LPD1", 4);
  w.u16(kVersion);
  w.str(dev_.alias);
  w.u32(dev_.artnetUniverse), w.u8(dev_.artnetEnabled), w.u32(dev_.sacnUniverse), w.u8(dev_.sacnEnabled);
  w.u32(dev_.staticIp), w.u32(dev_.staticMask);
  const Show &show = engine_.show();
  int n = 0;
  for (const Fixture &f : show.fixtures) n += f.patched;
  w.u8(n);
  for (int slot = 0; slot < kSlots; slot++) {
    const Fixture &f = show.fixtures[slot];
    if (!f.patched) continue;
    w.u8(slot), w.u16(f.address);
    w.u8((f.invertPan ? 1 : 0) | (f.invertTilt ? 2 : 0) | (f.swapPanTilt ? 4 : 0) | (f.virtualDimmer ? 8 : 0));
    w.u8(f.count), w.bytes(f.codes, f.count);
    const FixtureInfo &i = info_[slot];
    w.str(i.name), w.str(i.manufacturer), w.str(i.model), w.str(i.mode), w.str(i.profile);
  }
  n = 0;
  for (int pb = 0; pb < kPlaybacks; pb++) n += used_[pb] || !show.playbacks[pb].cues.empty();
  w.u8(n);
  for (int pb = 0; pb < kPlaybacks; pb++) {
    const Playback &p = show.playbacks[pb];
    if (!used_[pb] && p.cues.empty()) continue;
    w.u8(pb), w.u8(p.goMode), w.u8(p.repeat), w.u8((p.background ? 1 : 0) | (p.exclusive ? 2 : 0));
    w.f32(p.intensity), w.f32(p.speed), w.str(p.label);
    w.u16(p.cues.size());
    for (const Cue &c : p.cues) {
      w.u32(c.fadeMs), w.u32(c.delayMs), w.u8(c.follow), w.str(c.label);
      w.u8(c.records.size());
      for (const Record &r : c.records) w.u8(r.slot), w.bytes(r.bytes, kRecordSize);
    }
  }
  return d;
}

bool VnServer::loadShow(const uint8_t *data, size_t len) {
  Reader r{data, data + len};
  uint8_t magic[4];
  r.bytes(magic, 4);
  uint16_t version = r.ok && memcmp(magic, "LPD1", 4) == 0 ? r.u16() : 0;
  if (version < 1 || version > kVersion) return false;
  // read everything into new objects first: a broken file changes nothing
  VnDevice dev = dev_;
  dev.alias = r.str();
  dev.artnetUniverse = r.u32(), dev.artnetEnabled = r.u8(), dev.sacnUniverse = r.u32(), dev.sacnEnabled = r.u8();
  if (version >= 2) dev.staticIp = r.u32(), dev.staticMask = r.u32();
  Show *show = new Show();
  std::vector<FixtureInfo> info(kSlots);
  std::vector<bool> used(kPlaybacks, false);
  int n = r.u8();
  for (int k = 0; k < n && r.ok; k++) {
    int slot = r.u8();
    if (slot >= kSlots) r.ok = false;
    if (!r.ok) break;
    Fixture &f = show->fixtures[slot];
    f.patched = true;
    f.address = r.u16();
    uint8_t flags = r.u8();
    f.invertPan = flags & 1, f.invertTilt = flags & 2, f.swapPanTilt = flags & 4, f.virtualDimmer = flags & 8;
    f.count = r.u8();
    if (f.count > sizeof f.codes) r.ok = false;
    r.bytes(f.codes, f.count);
    FixtureInfo &i = info[slot];
    i.name = r.str(), i.manufacturer = r.str(), i.model = r.str(), i.mode = r.str(), i.profile = r.str();
  }
  n = r.u8();
  for (int k = 0; k < n && r.ok; k++) {
    int pb = r.u8();
    if (pb >= kPlaybacks) r.ok = false;
    if (!r.ok) break;
    Playback &p = show->playbacks[pb];
    used[pb] = true;
    uint8_t gm = r.u8(), rp = r.u8(), flags = r.u8();
    p.goMode = gm < 4 ? (GoMode)gm : kGo;
    p.repeat = rp < 4 ? (Repeat)rp : kLoop;
    p.background = flags & 1, p.exclusive = flags & 2;
    p.intensity = r.f32(), p.speed = r.f32(), p.label = r.str();
    int cues = r.u16();
    if (cues > 255) r.ok = false;
    for (int c = 0; c < cues && r.ok; c++) {
      Cue cue;
      cue.fadeMs = r.u32(), cue.delayMs = r.u32(), cue.follow = r.u8(), cue.label = r.str();
      int recs = r.u8();
      for (int q = 0; q < recs && r.ok; q++) {
        Record rec;
        rec.slot = r.u8();
        if (rec.slot >= kSlots) r.ok = false;
        r.bytes(rec.bytes, kRecordSize);
        cue.records.push_back(rec);
      }
      p.cues.push_back(cue);
    }
  }
  if (!r.ok) {
    delete show;
    return false;
  }
  engine_.releaseAll(0);
  // moved, not copied: two copies of a big show did not fit in the heap at
  // power-up (abort() in a boot loop, 2026-11-02)
  engine_.show() = std::move(*show);
  delete show;
  dev_ = dev;
  for (int i = 0; i < kSlots; i++) info_[i] = info[i];
  for (int i = 0; i < kPlaybacks; i++) used_[i] = used[i];
  return true;
}

}  // namespace lpd
