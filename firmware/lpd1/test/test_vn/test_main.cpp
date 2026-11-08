// The VN server (lib/vn) without a network: frames in, frames out.
// The whole protocol is checked against the reference app's captures with
//   python analysis/scripts/emulator_conformance.py CAPTURES --target 127.0.0.1:26945
// on the PC build (env pc); these tests pin the parts the box relies on.

#include <string.h>
#include <unity.h>

#include <string>
#include <vector>

#include "engine.h"
#include "vn_server.h"

using namespace lpd;

namespace {

struct Sent {
  std::vector<uint8_t> d;
  Peer to;
};

const Peer kApp{0xc0a801ab, 50000};  // 192.168.1.171

struct Rig {
  Engine engine;
  std::vector<Sent> out;
  VnServer vn{engine, [this](const uint8_t *d, size_t n, Peer to) { out.push_back({{d, d + n}, to}); }};
  Rig() { vn.device().ip = 0xc0a8010c; }  // 192.168.1.12

  std::vector<uint8_t> frame(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1 = 0, uint16_t i2 = 0,
                             uint16_t i3 = 0, std::vector<uint8_t> body = {}, uint16_t seq = 0x100) {
    std::vector<uint8_t> d(20, 0);
    d[0] = op, d[1] = type, d[2] = prop;
    d[4] = i1, d[5] = i1 >> 8, d[6] = i2, d[7] = i2 >> 8, d[8] = i3, d[9] = i3 >> 8;
    d[10] = d[11] = 0xff;
    d[12] = body.size(), d[13] = body.size() >> 8, d[14] = seq, d[15] = seq >> 8;
    d.insert(d.end(), body.begin(), body.end());
    return d;
  }
  void in(const std::vector<uint8_t> &d, uint32_t now = 1000) { vn.handle(d.data(), d.size(), kApp, now); }
  // The last answer that is not a notification.
  const Sent *answer() const {
    for (auto it = out.rbegin(); it != out.rend(); ++it) {
      if (it->d.size() >= 20 && !(it->d[1] & 0x80)) return &*it;
    }
    return nullptr;
  }
  int notifications(uint8_t op, uint8_t prop) const {
    int n = 0;
    for (const Sent &s : out) n += s.d.size() >= 20 && s.d[0] == op && (s.d[1] & 0x80) && s.d[2] == prop;
    return n;
  }
};

std::vector<uint8_t> u32(uint32_t v) { return {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)}; }
std::vector<uint8_t> str(const std::string &s) {
  std::vector<uint8_t> b(s.begin(), s.end());
  b.push_back(0);
  return b;
}
uint32_t bodyU32(const Sent *s) { return s->d[20] | s->d[21] << 8 | s->d[22] << 16 | (uint32_t)s->d[23] << 24; }

void writesAreEchoed() {
  Rig r;
  auto f = r.frame(0x29, 0x00, 0x06, 2, 0, 0, str("label"));
  r.in(f);
  TEST_ASSERT_TRUE(r.out.size() >= 1);
  TEST_ASSERT_TRUE(r.out[0].d == f);
  TEST_ASSERT_TRUE(r.out[0].to == kApp);
  TEST_ASSERT_EQUAL_STRING("label", r.engine.show().playbacks[2].label.c_str());
}

void fixtureDefinitionPatches() {
  Rig r;
  r.in(r.frame(0x1f, 0x00, 0x08, 0, 0, 0, str("\"Showtec\",\"Par\",\"6-Ch\",\"010405060C80\"")));
  r.in(r.frame(0x1f, 0x00, 0x08, 1, 0, 0, str("\"Showtec\",\"Par\",\"6-Ch\",\"010405060C80\"")));
  const Fixture &f = r.engine.show().fixtures[1];
  TEST_ASSERT_TRUE(f.patched);
  TEST_ASSERT_EQUAL(7, f.address);  // after fixture 1 (1-6), as the LPU assigns it
  TEST_ASSERT_EQUAL(6, f.count);
  r.in(r.frame(0x1f, 0x1d, 0x07, 1));
  const Sent *a = r.answer();
  TEST_ASSERT_EQUAL_STRING("\"Showtec\",\"Par\",\"6-Ch\",\"010405060C80\"", (const char *)a->d.data() + 20);
  r.in(r.frame(0x1f, 0x1d, 0x30, 1));
  TEST_ASSERT_EQUAL_HEX32(7u << 16, bodyU32(r.answer()));  // address, no pan / tilt flags
  r.in(r.frame(0x1f, 0x1d, 0x30, 5));
  TEST_ASSERT_EQUAL_HEX32(0xffff0000, bodyU32(r.answer()));  // not patched
}

void blocksRoundTrip() {
  Rig r;
  r.in(r.frame(0x29, 0x01, 0x48, 3, 0, 0, u32(2)));  // 2 cues
  std::vector<uint8_t> block(800, 0);
  for (int i = 0; i < 50; i++) block[50 * 5 + i] = i + 1;  // fixture 6 (slot 5)
  r.in(r.frame(0x2b, 0x0a, 0x47, 3, 1, 0, block));
  TEST_ASSERT_EQUAL(1, (int)r.engine.show().playbacks[3].cues[1].records.size());
  TEST_ASSERT_EQUAL(5, r.engine.show().playbacks[3].cues[1].records[0].slot);
  r.in(r.frame(0x2b, 0x1d, 0x46, 3, 1, 0));
  const Sent *a = r.answer();
  TEST_ASSERT_EQUAL(0x0a, a->d[1]);
  TEST_ASSERT_EQUAL(820, (int)a->d.size());
  TEST_ASSERT_TRUE(std::vector<uint8_t>(a->d.begin() + 20, a->d.end()) == block);
  // a zero block removes the records
  r.in(r.frame(0x2b, 0x0a, 0x47, 3, 1, 0, std::vector<uint8_t>(800, 0)));
  TEST_ASSERT_EQUAL(0, (int)r.engine.show().playbacks[3].cues[1].records.size());
  // a cue that does not exist: no answer, like the LPU
  size_t before = r.out.size();
  r.in(r.frame(0x2b, 0x1d, 0x29, 3, 7, 0));
  TEST_ASSERT_EQUAL(before, r.out.size());
}

void goNotifiesTheActiveCue() {
  Rig r;
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(2)));
  std::vector<uint8_t> block(800, 0);
  block[16] = 0xff, block[17] = 0xff;  // fixture 1 intensity 100 %
  r.in(r.frame(0x2b, 0x0a, 0x47, 0, 0, 0, block));
  r.in(r.frame(0x2b, 0x0a, 0x47, 0, 1, 0, block));
  r.vn.tick(1000);
  r.out.clear();
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(1)), 1100);  // GO pressed
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(0)), 1150);  // let go
  r.vn.tick(1200);
  TEST_ASSERT_EQUAL(0, r.engine.currentCue(0, 1200));
  TEST_ASSERT_EQUAL(1, r.notifications(0x29, 0x2f));
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(1)), 1300);  // GO again: cue 2 on let go
  TEST_ASSERT_EQUAL(0, r.engine.currentCue(0, 1320));
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(0)), 1350);
  r.vn.tick(1400);
  TEST_ASSERT_EQUAL(1, r.engine.currentCue(0, 1400));
  r.in(r.frame(0x29, 0x1d, 0x42, 0), 1500);  // RELEASE
  r.vn.tick(1600);
  TEST_ASSERT_EQUAL(-1, r.engine.currentCue(0, 1600));
  TEST_ASSERT_EQUAL(3, r.notifications(0x29, 0x2f));
  r.in(r.frame(0x29, 0x1d, 0x30, 0), 1700);
  const Sent *a = r.answer();
  TEST_ASSERT_EQUAL(2, a->d[22]);     // 2 cues
  TEST_ASSERT_EQUAL(0xff, a->d[23]);  // no active cue
  // Go mode, GO held 1 s: released while held, nothing on let go (test go_hold)
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(1)), 2000);
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(0)), 2100);
  TEST_ASSERT_EQUAL(0, r.engine.currentCue(0, 2100));
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(1)), 3000);
  TEST_ASSERT_EQUAL(0, r.engine.currentCue(0, 3990));
  TEST_ASSERT_EQUAL(-1, r.engine.currentCue(0, 4000));
  r.in(r.frame(0x29, 0x02, 0x22, 0, 0, 0, u32(0)), 4500);
  TEST_ASSERT_EQUAL(-1, r.engine.currentCue(0, 4600));
}

void shortPropertiesAndAlias() {
  Rig r;
  std::vector<uint8_t> q = {0, 0x11, 0, 0, 0, 0, 0, 0, 0};
  r.vn.handle(q.data(), q.size(), kApp, 1000);
  TEST_ASSERT_EQUAL_STRING("LPD-1", (const char *)r.out.back().d.data() + 9);
  std::vector<uint8_t> w = {0, 0x12, 0, 0, 0, 0, 0, 0, 4, 'B', 'O', 'X', 0};
  r.vn.handle(w.data(), w.size(), kApp, 1000);
  TEST_ASSERT_EQUAL_STRING("BOX", r.vn.device().alias.c_str());
  std::vector<uint8_t> id = {'v', 'i', 's', 'u', 'a', 'l', '_', 'i', 'd', 'e', 'n', 't', 'i', 'f', 'y'};
  r.vn.handle(id.data(), id.size(), kApp, 1000);
  std::string xml((const char *)r.out.back().d.data());
  TEST_ASSERT_TRUE(xml.find("<ip>192.168.1.12</ip>") != std::string::npos);
}

void loadSendsTheProgrammer() {
  Rig r;
  r.in(r.frame(0x1f, 0x00, 0x08, 0, 0, 0, str("\"a\",\"b\",\"c\",\"010405\"")));
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(1)));
  std::vector<uint8_t> block(800, 0);
  block[16] = 0xff, block[17] = 0xff;  // intensity 100 %
  block[20] = 0x00, block[21] = 0x80;  // red 50 %
  r.in(r.frame(0x2b, 0x0a, 0x47, 0, 0, 0, block));
  r.in(r.frame(0x2c, 0x01, 0x35, 0, 0, 0, u32(0)));  // EDIT open
  // no edited playback (2c 3f): LOAD gets no answer, like the LPU
  r.in(r.frame(0x2c, 0x01, 0x3f, 0, 0, 0, u32(64)));
  r.out.clear();
  r.in(r.frame(0x2c, 0x1d, 0x36, 0, 0, 0));
  TEST_ASSERT_EQUAL(0, (int)r.out.size());
  r.in(r.frame(0x2c, 0x01, 0x3f, 0, 0, 0, u32(0)));
  r.out.clear();
  r.in(r.frame(0x2c, 0x1d, 0x36, 0, 0, 0));
  TEST_ASSERT_EQUAL(17, r.notifications(0x2c, 0x32));
  TEST_ASSERT_EQUAL(1, r.notifications(0x2c, 0x45));
  uint8_t dmx[kUniverse];
  r.engine.render(2000, dmx);
  TEST_ASSERT_EQUAL(255, dmx[0]);  // the programmer's intensity
  TEST_ASSERT_EQUAL(128, dmx[1]);  // red
}

// RECORD: the cue becomes the programmer, per fixture (the LPU, 2026-11-02:
// m400 pb5 cue 1, red and yellow fixtures).
void recordKeepsEachFixture() {
  Rig r;
  for (int f = 0; f < 3; f++) r.in(r.frame(0x1f, 0x00, 0x08, f, 0, 0, str("\"a\",\"b\",\"c\",\"01040506\"")));
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(2)));
  std::vector<uint8_t> red(800, 0), other(800, 0);
  for (int f = 0; f < 2; f++) {
    red[50 * f + 16] = red[50 * f + 17] = 0xff;  // intensity
    red[50 * f + 20] = red[50 * f + 21] = 0xff;  // red
  }
  red[50 * 1 + 22] = red[50 * 1 + 23] = 0xff;  // fixture 2 also green: yellow
  red[50 * 1 + 3] = 64;                        // and its own FX phase
  other[50 * 2 + 16] = 0xff;                   // cue 2: fixture 3 only
  r.in(r.frame(0x2b, 0x0a, 0x47, 0, 0, 0, red));
  r.in(r.frame(0x2b, 0x0a, 0x47, 0, 1, 0, other));
  r.in(r.frame(0x2c, 0x01, 0x35, 0, 0, 0, u32(0)));  // EDIT open
  r.in(r.frame(0x2c, 0x01, 0x3f, 0, 0, 0, u32(0)));
  r.in(r.frame(0x2c, 0x1d, 0x36, 0, 0, 0));  // LOAD cue 1
  r.in(r.frame(0x2c, 0x1d, 0x37, 0, 1, 0));  // RECORD into cue 2: an exact copy
  const auto &c = r.engine.show().playbacks[0].cues;
  TEST_ASSERT_EQUAL(2, (int)c[1].records.size());  // fixture 3 is gone
  TEST_ASSERT_EQUAL_MEMORY(red.data(), c[1].records[0].bytes, 50);
  TEST_ASSERT_EQUAL_MEMORY(red.data() + 50, c[1].records[1].bytes, 50);
  // intensity 50 % on both: each keeps its colour; 0.5 is cut off to 32767
  float half = 0.5f;
  std::vector<uint8_t> h(4);
  memcpy(h.data(), &half, 4);
  r.in(r.frame(0x2d, 0x03, 0x33, 0, 0, 0, h));
  r.in(r.frame(0x2c, 0x1d, 0x37, 0, 0, 0));
  TEST_ASSERT_EQUAL(0x7fff, c[0].records[0].bytes[16] | c[0].records[0].bytes[17] << 8);
  TEST_ASSERT_EQUAL(0x7fff, c[0].records[1].bytes[16] | c[0].records[1].bytes[17] << 8);
  TEST_ASSERT_EQUAL(0, c[0].records[0].bytes[22]);     // fixture 1 still red
  TEST_ASSERT_EQUAL(0xff, c[0].records[1].bytes[22]);  // fixture 2 still yellow
  TEST_ASSERT_EQUAL(64, c[0].records[1].bytes[3]);
  // only a selection, no values: an empty cue
  r.in(r.frame(0x2c, 0x1d, 0x38, 0, 0, 0));  // CLEAR
  r.in(r.frame(0x2c, 0x05, 0x3c, 0, 0, 0, {3, 0, 0, 0, 0, 0, 0, 0}));
  r.in(r.frame(0x2c, 0x1d, 0x37, 0, 0, 0));
  TEST_ASSERT_EQUAL(0, (int)c[0].records.size());
}

// Several selected cues at once: i3 = how many (the reference app, 2026-10-28)
void cueWritesToARange() {
  Rig r;
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(4)));
  r.in(r.frame(0x2b, 0x01, 0x2c, 0, 0, 2, u32(4000)));  // delay, cues 1-2
  r.in(r.frame(0x2b, 0x01, 0x28, 0, 2, 2, u32(1)));     // follow, cues 3-4
  r.in(r.frame(0x2b, 0x01, 0x2a, 0, 3, 0, u32(500)));   // fade, cue 4 only
  const auto &c = r.engine.show().playbacks[0].cues;
  TEST_ASSERT_EQUAL(4000, (int)c[0].delayMs);
  TEST_ASSERT_EQUAL(4000, (int)c[1].delayMs);
  TEST_ASSERT_EQUAL(0, (int)c[2].delayMs);
  TEST_ASSERT_FALSE(c[1].follow);
  TEST_ASSERT_TRUE(c[2].follow);
  TEST_ASSERT_TRUE(c[3].follow);
  TEST_ASSERT_EQUAL(0, (int)c[2].fadeMs);
  TEST_ASSERT_EQUAL(500, (int)c[3].fadeMs);
}

void showFileRoundTrip() {
  Rig a;
  a.in(a.frame(0x1f, 0x00, 0x08, 3, 0, 0, str("\"Showtec\",\"Par\",\"6-Ch\",\"010405060C80\"")));
  a.in(a.frame(0x1f, 0x00, 0x06, 3, 0, 0, str("front left")));
  a.in(a.frame(0x1f, 0x02, 0x14, 3, 0, 0, u32(1)));  // virtual dimmer
  a.in(a.frame(0x29, 0x01, 0x48, 7, 0, 0, u32(2)));
  a.in(a.frame(0x29, 0x00, 0x06, 7, 0, 0, str("chase")));
  a.in(a.frame(0x29, 0x01, 0x21, 7, 0, 0, u32(3)));  // Solo
  a.in(a.frame(0x2b, 0x01, 0x2a, 7, 1, 0, u32(2500)));
  std::vector<uint8_t> block(800, 0);
  for (int i = 0; i < 50; i++) block[50 * 3 + i] = 200 - i;
  a.in(a.frame(0x2b, 0x0a, 0x47, 7, 1, 0, block));
  std::vector<uint8_t> alias = {0, 0x12, 0, 0, 0, 0, 0, 0, 5, 'S', 'T', 'A', 'G', 0};
  a.vn.handle(alias.data(), alias.size(), kApp, 1000);
  std::vector<uint8_t> file = a.vn.saveShow();

  Rig b;
  TEST_ASSERT_TRUE(b.vn.loadShow(file.data(), file.size()));
  TEST_ASSERT_TRUE(b.vn.saveShow() == file);  // the same file again
  const Show &s = b.engine.show();
  TEST_ASSERT_TRUE(s.fixtures[3].patched && s.fixtures[3].virtualDimmer);
  TEST_ASSERT_EQUAL(6, s.fixtures[3].count);
  TEST_ASSERT_EQUAL_STRING("front left", b.vn.fixtureInfo(3).name.c_str());
  TEST_ASSERT_EQUAL_STRING("chase", s.playbacks[7].label.c_str());
  TEST_ASSERT_EQUAL(kSolo, s.playbacks[7].goMode);
  TEST_ASSERT_EQUAL(2500, (int)s.playbacks[7].cues[1].fadeMs);
  TEST_ASSERT_EQUAL(1, (int)s.playbacks[7].cues[1].records.size());
  TEST_ASSERT_EQUAL(200, s.playbacks[7].cues[1].records[0].bytes[0]);
  TEST_ASSERT_EQUAL_STRING("STAG", b.vn.device().alias.c_str());
  // a cut-off file changes nothing
  Rig c;
  TEST_ASSERT_FALSE(c.vn.loadShow(file.data(), file.size() - 7));
  TEST_ASSERT_FALSE(c.engine.show().fixtures[3].patched);
  TEST_ASSERT_EQUAL_STRING("LPD-1", c.vn.device().alias.c_str());
}

void ipAddressSettings() {
  Rig r;
  // static 192.168.1.13 / 255.255.0.0 as the reference app writes them (FINDINGS 20.18)
  std::vector<uint8_t> ip = {0, 0x02, 0, 0, 0, 0, 0, 0, 6, 0xc0, 0xa8, 0x01, 0x0d, 0, 0};
  std::vector<uint8_t> mask = {0, 0x04, 0, 0, 0, 0, 0, 0, 6, 0xff, 0xff, 0x00, 0x00, 0, 0};
  r.vn.handle(ip.data(), ip.size(), kApp, 1000);
  TEST_ASSERT_TRUE(r.out.back().d == ip);  // echoed
  r.vn.handle(mask.data(), mask.size(), kApp, 1000);
  TEST_ASSERT_EQUAL_HEX32(0xc0a8010d, r.vn.device().staticIp);
  TEST_ASSERT_EQUAL_HEX32(0xffff0000, r.vn.device().staticMask);
  TEST_ASSERT_EQUAL(2, (int)r.vn.networkVersion());
  std::vector<uint8_t> file = r.vn.saveShow();
  Rig b;
  TEST_ASSERT_TRUE(b.vn.loadShow(file.data(), file.size()));
  TEST_ASSERT_EQUAL_HEX32(0xc0a8010d, b.vn.device().staticIp);
  // DHCP: both all zeros
  std::vector<uint8_t> dhcp = {0, 0x02, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0};
  r.vn.handle(dhcp.data(), dhcp.size(), kApp, 1000);
  TEST_ASSERT_EQUAL_HEX32(0, r.vn.device().staticIp);
}

void limits() {
  Rig r;
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(49)));  // the LPU does not answer 49
  TEST_ASSERT_EQUAL(0, (int)r.out.size());
  TEST_ASSERT_EQUAL(0, (int)r.engine.show().playbacks[0].cues.size());
  r.in(r.frame(0x29, 0x01, 0x48, 0, 0, 0, u32(48)));
  TEST_ASSERT_EQUAL(48, (int)r.engine.show().playbacks[0].cues.size());
  r.out.clear();
  r.in(r.frame(0x29, 0x01, 0x03, 0, 0, 0, u32(0xffffffff)));  // INSERT on a full playback: echoed, nothing added
  TEST_ASSERT_EQUAL(48, (int)r.engine.show().playbacks[0].cues.size());
  // the box's record budget: full blocks until it is used up
  std::vector<uint8_t> block(800, 0);
  for (int i = 0; i < 16; i++) block[50 * i + 16] = 1;
  int taken = 0;
  for (int pb = 0; pb < 8; pb++) {
    r.in(r.frame(0x29, 0x01, 0x48, pb, 0, 0, u32(48)));
    for (int cue = 0; cue < 48; cue++) {
      r.out.clear();
      r.in(r.frame(0x2b, 0x0a, 0x47, pb, cue, 0, block));
      taken += !r.out.empty();
    }
  }
  TEST_ASSERT_EQUAL((int)(kMaxRecords / 16), taken);
}

}  // namespace

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(writesAreEchoed);
  RUN_TEST(fixtureDefinitionPatches);
  RUN_TEST(blocksRoundTrip);
  RUN_TEST(goNotifiesTheActiveCue);
  RUN_TEST(shortPropertiesAndAlias);
  RUN_TEST(loadSendsTheProgrammer);
  RUN_TEST(recordKeepsEachFixture);
  RUN_TEST(cueWritesToARange);
  RUN_TEST(showFileRoundTrip);
  RUN_TEST(ipAddressSettings);
  RUN_TEST(limits);
  return UNITY_END();
}
