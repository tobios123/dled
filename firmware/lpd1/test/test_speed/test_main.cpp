// The engine's worst case: 64 playbacks running at once, each with a cue for
// all 64 fixtures with intensity, position and colour FX. Prints the time per
// frame on this PC (the ESP32 is roughly 20-50x slower; a frame is 25 ms).

#include <unity.h>

#include <chrono>
#include <cstdio>

#include "engine.h"

using namespace lpd;

void setUp() {}
void tearDown() {}

void testWorstCase() {
  Engine e;
  for (int i = 0; i < kSlots; i++) {
    Fixture &f = e.show().fixtures[i];
    f.patched = true;
    f.address = 1 + 8 * i;
    f.count = 8;
    for (int c = 0; c < 8; c++) f.codes[c] = c + 1;
  }
  for (int pb = 0; pb < kPlaybacks; pb++) {
    Cue cue;
    cue.fadeMs = 3000;
    for (int i = 0; i < kSlots; i++) {
      Record r{(uint8_t)i, {}};
      uint8_t fx[12] = {1, 255, 64, (uint8_t)(i * 4), 6, 128, 64, (uint8_t)(i * 4), 10, 200, 64, (uint8_t)(i * 4)};
      for (int k = 0; k < 12; k++) r.bytes[k] = fx[k];
      for (int k = 12; k < kRecordSize; k++) r.bytes[k] = (uint8_t)(pb * 7 + k * 13 + i);
      cue.records.push_back(r);
    }
    e.show().playbacks[pb].cues.push_back(cue);
    e.go(pb, 0);
  }
  uint8_t dmx[kUniverse];
  const int frames = 400;
  auto t0 = std::chrono::steady_clock::now();
  for (int k = 0; k < frames; k++) e.render(25 * k, dmx);
  double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() / frames;
  printf("worst case: %.0f us per frame on this PC (64 playbacks x 64 fixtures, 3 FX each)\n", us);
  TEST_ASSERT_TRUE(us < 2500);  // ~1/10 of a frame here leaves room on the ESP32
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(testWorstCase);
  return UNITY_END();
}
