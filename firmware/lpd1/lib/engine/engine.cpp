// engine.cpp -- see engine.h. "Section n" = lpd/DMX_ENGINE.md section n.

#include "engine.h"

#include <math.h>
#include <string.h>

#include <utility>

namespace lpd {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr uint16_t kCentre = 32767;  // pan / tilt idle (section 2)

// Function code -> attribute (section 2; 13 = custom 2), -1: no fader.
int codeAttr(uint8_t code) {
  static const int8_t map[0x14] = {-1,    kIn,   kPan,  kTilt, kR,     kG,     kB,
                                   kA,    kW,    kCol,  kGobo, kRota,  kSh,    kIris,
                                   kFrost, kFocus, kPrism, kZoom, kC1, kC2};
  return code < 0x14 ? map[code] : -1;
}

bool isPos(int a) { return a == kPan || a == kTilt; }

uint16_t idle(int a) { return isPos(a) ? kCentre : 0; }

// A record's value for an attribute as 16-bit DMX (section 2).
uint16_t recordValue(const uint8_t *rec, int a) {
  uint16_t raw = rec[12 + 2 * a] | rec[13 + 2 * a] << 8;
  if (!isPos(a)) return raw;
  int v = (int16_t)raw + kCentre;
  return v < 0 ? 0 : (v > 65535 ? 65535 : v);
}

bool recordHas(const uint8_t *rec, int a) { return rec[12 + 2 * a] | rec[13 + 2 * a]; }

uint16_t lerp(uint16_t a, uint16_t b, double p) { return (uint16_t)lround(a + (b - (double)a) * p); }

uint16_t clamp16(long v) { return v < 0 ? 0 : (v > 65535 ? 65535 : (uint16_t)v); }

// FX speed byte -> a signed rate. The reference app writes +100 % as 128, which
// the LPU takes as -128: +100 % runs the FX backwards at full speed (section
// 7). Our apps write 127.
int speedValue(uint8_t b) { return (int8_t)b; }

// Periods: intensity 50 / b s, colour 100 / b s, position ~143 / b s
// (section 7). Measured against the PC's clock the LPU runs 0.4 % fast
// (0.778 s instead of 0.781 s at b 64), so the divisors are a little smaller.
constexpr double kIntensityDiv = 49.8, kColourDiv = 99.6, kPositionDiv = 142.5;

double frac(double x) { return x - floor(x); }

// The playback speed knob as a factor on FX (section 7). Turned right as
// the LPU: about 1 + 2 k, x2 from k 0.5 up, measured in steps of 0.1 (test
// "fx_knob", the Ramp's slope; between the steps linear). Turned left NOT
// as the LPU: it slows down to standing at -0.5 and then runs the FX
// backwards, faster towards -1 (-0.98 at -1), which looks like "faster
// again" on a rainbow - the user wants it logical (2026-10-29): 1 + k,
// slower over the whole left half, standing at -1, never backwards.
double knobFactor(float k) {
  static const double right[11] = {1.0, 1.195, 1.392, 1.595, 1.783, 1.986, 1.986, 1.986, 1.986, 1.986, 1.986};
  if (k <= 0) return k < -1 ? 0.0 : 1.0 + k;
  double x = (k > 1 ? 1 : k) * 10;
  int i = x >= 10 ? 9 : (int)x;
  return right[i] + (right[i + 1] - right[i]) * (x - i);
}

// The speed knob on a playback's cue times (section 10a): a follow cue's
// fade and delay run this many times as fast. Measured on the LPU in
// steps of 0.1 (2026-10-29, a 2 s delay and a 2 s fade); between the steps
// linear. Positive: 1 + 9 k. From -0.9 down the playback stands still.
// (Right around 0 the LPU is irregular: -0.05 gave x1.0, -0.02 x0.48.)
double timeFactor(float k) {
  static const double neg[11] = {0.0, 0.0, 0.08, 0.12, 0.16, 0.24, 0.28, 0.321, 0.40, 0.441, 1.0};  // -1 .. 0
  if (k >= 0) return 1 + 9 * (k > 1 ? 1 : k);
  double x = (k < -1 ? -1 : k) * 10 + 10;
  int i = x >= 10 ? 9 : (int)x;
  return neg[i] + (neg[i + 1] - neg[i]) * (x - i);
}

constexpr uint32_t bit(int a) { return 1u << a; }
constexpr uint32_t kGoHoldMs = 1000;  // Go mode: GO held this long releases
constexpr uint32_t kPosBits = bit(kPan) | bit(kTilt);
constexpr uint32_t kRgbBits = bit(kR) | bit(kG) | bit(kB);

}  // namespace

bool Fixture::has(uint8_t code) const {
  for (int i = 0; i < count; i++) {
    if (codes[i] == code) return true;
  }
  return false;
}

const Record *Cue::record(int slot) const {
  for (const Record &r : records) {
    if (r.slot == slot) return &r;
  }
  return nullptr;
}

Engine::Engine(uint32_t seed) : seed_(seed) {
  for (auto &slot : out_) {
    for (int a = 0; a < kAttrs; a++) slot[a] = idle(a);
  }
}

uint32_t Engine::rand(uint32_t a, uint32_t b, uint32_t c, uint32_t d) const {
  uint64_t x = seed_ ^ (uint64_t)a * 0x9E3779B97F4A7C15ull ^ (uint64_t)b << 17 ^ (uint64_t)c << 33 ^
               (uint64_t)d * 0xD1B54A32D192ED03ull;
  x ^= x >> 30;
  x *= 0xBF58476D1CE4E5B9ull;
  x ^= x >> 27;
  x *= 0x94D049BB133111EBull;
  x ^= x >> 31;
  return (uint32_t)x;
}

// --- time ---------------------------------------------------------------------

// A follow cue's fade runs on the cue clock (the knob speeds it up: test
// knob_follow, x10 at +1); any other fade and a release in real time (test
// "fades": a 3 s fade at knob +0.5 / -0.5 took 3 s).
double Engine::progress(const State &s, uint32_t now) const {
  if (!s.releasing && s.follow) {
    double t = cueClock(s, now);
    return s.fadeMs == 0 || t >= s.fadeMs ? 1.0 : (t <= 0 ? 0.0 : t / s.fadeMs);
  }
  if (s.fadeMs == 0 || now >= s.start + s.fadeMs) return 1.0;
  if (now <= s.start) return 0.0;
  return (now - s.start) / (double)s.fadeMs;
}

// The cue clock in ms since the cue started, for a follow cue's fade and
// the time to the next cue (fade + delay), and phase 3: the speed knob
// scales it (section 10a), a knob change does not make it jump.
double Engine::cueClock(const State &s, uint32_t now) const {
  int pb = (int)(&s - st_);
  return s.cueMs + ((int64_t)now - (int64_t)s.cueT0) * timeFactor(show_.playbacks[pb].speed);
}

// When the cue clock reaches [ms] (it has: the time it did), on the LPU's
// 25 ms frames from the cue's start: it moves on at a frame (knob +0.5 and a
// 2 s delay: 375 ms, not 364).
uint32_t Engine::whenClock(const State &s, double ms) const {
  int pb = (int)(&s - st_);
  double f = timeFactor(show_.playbacks[pb].speed);
  uint32_t t = f > 0 ? s.cueT0 + (uint32_t)ceil((ms - s.cueMs) / f) : s.cueT0;
  return s.start + (t - s.start + 24) / 25 * 25;
}

// The FX clock starts at GO; the speed knob scales it, a knob change does
// not make the wave jump (section 7).
double Engine::fxTime(const State &s, uint32_t now) const {
  int pb = (int)(&s - st_);
  return s.fxTime + ((int64_t)now - (int64_t)s.fxT0) / 1000.0 * knobFactor(show_.playbacks[pb].speed);
}

// A playback's intensity for a fixture (section 8): GO fades from the
// remembered level to the cue's, RELEASE from where it is to 0.
uint16_t Engine::level(const State &s, const Hold &h, uint32_t now) const {
  double p = progress(s, now);
  return s.releasing ? lerp(h.inFrom, 0, p) : lerp(h.inFrom, h.inTo, p);
}

// --- FX (sections 4-7) ----------------------------------------------------------

int Engine::fxAdd(FxGen g, const Fx &fx, double t, int slot, int pb) const {
  (void)g;
  double u = t * speedValue(fx.speed) / kIntensityDiv + fx.phase / 255.0;
  double x = frac(u), w = 0;
  switch (fx.wave) {
    case 1: w = sin(2 * kPi * x); break;          // Sinus
    case 2: w = 2 * x - 1; break;                 // Ramp
    case 3: w = 1 - 2 * x; break;                 // Inversed Ramp
    case 4: w = x < 0.5 ? 1 : -1; break;          // Square
    case 5: {  // Random: on ~10 % of the half-period ticks a random dip that
               // recovers at "dip per period" (test "random_long")
      double k = floor(2 * u), age = (2 * u - k) / 2;
      uint32_t r = rand(pb, slot, 5, (uint32_t)(int64_t)k);
      double d = (r % 100) < 11 ? ((r >> 8) % 1000) / 1000.0 : 0;
      w = -d * (1 - age);
      break;
    }
  }
  return (int)lround(fx.size / 255.0 * 65535 * w);
}

void Engine::colourFx(const Fx &fx, double t, int slot, int pb, int add[3]) const {
  double u = t * speedValue(fx.speed) / kColourDiv + fx.phase / 255.0;
  double x = frac(u), rgb[3] = {0, 0, 0};
  auto hue = [&rgb](double h) {  // the HSV hue wheel, red at 0
    auto c = [](double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); };
    rgb[0] = c(fabs(6 * h - 3) - 1);
    rgb[1] = c(2 - fabs(6 * h - 2));
    rgb[2] = c(2 - fabs(6 * h - 4));
  };
  switch (fx.wave) {
    case 10: hue(x); break;  // Rainbow
    case 11: rgb[0] = rgb[1] = rgb[2] = (1 + sin(2 * kPi * x)) / 2; break;  // Full Sinus
    case 12: {  // Full Twinkle: a white flash on ~60 % of the half-period ticks,
                // gone in half a period (~1.2 per period, test "random_long")
      double k = floor(2 * u), x2 = 2 * u - k;
      if (rand(pb, slot, 12, (uint32_t)(int64_t)k) % 100 < 60) rgb[0] = rgb[1] = rgb[2] = 1 - x2;
      break;
    }
    case 5: {  // Random: the colour moves along the hue wheel now and then
      double k = floor(u);
      hue((rand(pb, slot, 6, (uint32_t)(int64_t)k) % 6) / 6.0);
      break;
    }
  }
  for (int i = 0; i < 3; i++) add[i] = (int)lround(fx.size / 255.0 * 65535 * rgb[i]);
}

void Engine::positionFx(const Fx &fx, double t, int slot, int pb, int add[2]) const {
  double u = t * speedValue(fx.speed) / kPositionDiv + fx.phase / 255.0;
  double x = frac(u), p = 0, q = 0;  // pan, tilt -1..1
  switch (fx.wave) {
    case 6: p = sin(2 * kPi * x); q = cos(2 * kPi * x); break;  // Circle
    case 7: p = sin(4 * kPi * x); q = cos(2 * kPi * x); break;  // Eight
    case 4: {  // Square: from the corner pan -1 / tilt +1, one side per quarter
      int side = (int)(4 * x);
      double r = 4 * x - side;
      switch (side) {
        case 0: p = -1 + 2 * r; q = 1; break;
        case 1: p = 1; q = 1 - 2 * r; break;
        case 2: p = 1 - 2 * r; q = -1; break;
        default: p = -1; q = -1 + 2 * r; break;
      }
      break;
    }
    case 8: p = sin(2 * kPi * x); break;  // Pan
    case 9: q = sin(2 * kPi * x); break;  // Tilt
    case 5: {  // Random: a new place every period
      double k = floor(u);
      p = rand(pb, slot, 7, (uint32_t)(int64_t)k) % 2001 / 1000.0 - 1;
      q = rand(pb, slot, 8, (uint32_t)(int64_t)k) % 2001 / 1000.0 - 1;
      break;
    }
  }
  add[0] = (int)lround(fx.size / 255.0 * 32767 * p);
  add[1] = (int)lround(fx.size / 255.0 * 32767 * q);
}

// --- the output -------------------------------------------------------------------

void Engine::computeAll(uint32_t now, uint16_t out[kSlots][kAttrs]) {
  for (int slot = 0; slot < kSlots; slot++) {
    for (int a = 0; a < kAttrs; a++) out[slot][a] = idle(a);
  }
  if (editing_) {  // only the programmer (section 12)
    double t = ((int64_t)now - (int64_t)progFxT0_) / 1000.0;
    for (int slot = 0; slot < kSlots; slot++) {
      const Prog &g = prog_[slot];
      for (int a = 0; a < kAttrs; a++) {
        if (g.sets & bit(a)) out[slot][a] = g.v[a];
      }
      if (g.fx[kFxIntensity].on()) {
        out[slot][kIn] = clamp16(out[slot][kIn] + fxAdd(kFxIntensity, g.fx[kFxIntensity], t, slot, 64));
      }
      if (g.fx[kFxPosition].on()) {
        int add[2];
        positionFx(g.fx[kFxPosition], t, slot, 64, add);
        out[slot][kPan] = clamp16(out[slot][kPan] + add[0]);
        out[slot][kTilt] = clamp16(out[slot][kTilt] + add[1]);
      }
      if (g.fx[kFxColour].on()) {
        int add[3];
        colourFx(g.fx[kFxColour], t, slot, 64, add);
        for (int i = 0; i < 3; i++) out[slot][kR + i] = clamp16(out[slot][kR + i] + add[i]);
      }
    }
    return;
  }

  // the active playbacks, the one started first first (LTP: the last wins)
  int order[kPlaybacks], n = 0;
  for (int pb = 0; pb < kPlaybacks; pb++) {
    if (st_[pb].active) order[n++] = pb;
  }
  for (int i = 1; i < n; i++) {
    for (int j = i; j > 0 && st_[order[j]].order < st_[order[j - 1]].order; j--) {
      int t = order[j];
      order[j] = order[j - 1];
      order[j - 1] = t;
    }
  }
  bool solo = false;
  for (int i = 0; i < n; i++) solo |= st_[order[i]].soloHeld;

  // Every attribute is HTP: the highest value of the playbacks that set it
  // (section 11); fading back = towards idle. The FX for position / colour:
  // of the playback started last that has the fixture's position / colour.
  const Hold *posFx[kSlots] = {}, *colFx[kSlots] = {};
  int posPb[kSlots], colPb[kSlots];
  uint32_t have[kSlots] = {};
  for (int i = 0; i < n; i++) {
    int pb = order[i];
    const State &s = st_[pb];
    double p = progress(s, now);
    for (const Hold &h : s.holds) {
      uint16_t *o = out[h.slot];
      for (int a = 0; a < kAttrs; a++) {
        if (a == kIn) continue;
        uint32_t b = bit(a);
        uint16_t v;
        if (h.sets & b) {
          v = s.releasing ? lerp(h.from[a], idle(a), p) : lerp(h.from[a], h.to[a], p);
        } else if (h.toBelow & b) {
          v = lerp(h.from[a], idle(a), p);
        } else {
          continue;
        }
        o[a] = (have[h.slot] & b) && o[a] > v ? o[a] : v;
        have[h.slot] |= b;
      }
      if ((h.sets & kPosBits) || h.fx[kFxPosition].on()) {
        posFx[h.slot] = &h;
        posPb[h.slot] = pb;
      }
      if ((h.sets & kRgbBits) || h.fx[kFxColour].on()) {
        colFx[h.slot] = &h;
        colPb[h.slot] = pb;
      }
    }
  }

  // intensity: HTP on the playbacks' levels after their faders; the winner's
  // FX on top (sections 3, 4, 11). One pass over the holds.
  double best[kSlots];
  long value[kSlots] = {};
  for (int slot = 0; slot < kSlots; slot++) best[slot] = -1;
  for (int i = 0; i < n; i++) {
    int pb = order[i];
    const State &s = st_[pb];
    int mode = show_.playbacks[pb].goMode;  // Flash, Solo: fader ignored (test "flash_solo")
    double fader = s.flashHeld || mode == kFlash || mode == kSolo ? 1.0 : show_.playbacks[pb].intensity;
    if (solo && !s.soloHeld) fader = 0;
    for (const Hold &h : s.holds) {
      uint16_t lv = level(s, h, now);
      // a releasing playback competes with its level from the moment of
      // the release: its FX stay on top until it is gone (test "open")
      double eff = (s.releasing ? h.inFrom : lv) * fader;
      if (eff >= best[h.slot]) {
        best[h.slot] = eff;
        long v = lv;
        if (h.fx[kFxIntensity].on()) v = clamp16(v + fxAdd(kFxIntensity, h.fx[kFxIntensity], fxTime(s, now), h.slot, pb));
        value[h.slot] = (long)(v * fader);
      }
    }
  }
  for (int slot = 0; slot < kSlots; slot++) {
    out[slot][kIn] = clamp16(value[slot]);
    if (posFx[slot] && posFx[slot]->fx[kFxPosition].on()) {
      int add[2];
      positionFx(posFx[slot]->fx[kFxPosition], fxTime(st_[posPb[slot]], now), slot, posPb[slot], add);
      out[slot][kPan] = clamp16(out[slot][kPan] + add[0]);
      out[slot][kTilt] = clamp16(out[slot][kTilt] + add[1]);
    }
    if (colFx[slot] && colFx[slot]->fx[kFxColour].on()) {
      int add[3];
      colourFx(colFx[slot]->fx[kFxColour], fxTime(st_[colPb[slot]], now), slot, colPb[slot], add);
      for (int i = 0; i < 3; i++) out[slot][kR + i] = clamp16(out[slot][kR + i] + add[i]);
    }
  }
}

void Engine::render(uint32_t now, uint8_t dmx[kUniverse]) {
  advance(now);
  computeAll(now, out_);
  memset(dmx, 0, kUniverse);
  for (int slot = 0; slot < kSlots; slot++) {
    const Fixture &f = show_.fixtures[slot];
    if (!f.patched) continue;
    uint16_t v[kAttrs];
    memcpy(v, out_[slot], sizeof v);
    // virtual dimmer: a fixture without intensity channel dims its colour
    if (f.virtualDimmer && !f.has(0x01)) {
      for (int a = kR; a <= kW; a++) v[a] = (uint16_t)((uint32_t)v[a] * v[kIn] / 65535);
    }
    // the flags work on the output, after the FX (section 9)
    if (f.swapPanTilt) {
      uint16_t t = v[kPan];
      v[kPan] = v[kTilt];
      v[kTilt] = t;
    }
    if (f.invertPan) v[kPan] = 65535 - v[kPan];
    if (f.invertTilt) v[kTilt] = 65535 - v[kTilt];
    for (int i = 0; i < f.count; i++) {
      int ch = f.address - 1 + i;
      if (ch < 0 || ch >= kUniverse) continue;
      uint8_t code = f.codes[i];
      int a = codeAttr(code);
      if (code == 0x15 || code == 0x16) {
        dmx[ch] = code == 0x15 ? 127 : 255;  // fixed values (test "codes")
      } else if (a >= 0) {
        dmx[ch] = v[a] >> 8;
      } else if (code > 0x20 && (a = codeAttr(code - 0x20)) >= 0) {
        dmx[ch] = v[a] & 0xff;  // fine channel: code + 0x20 (section 2)
      }
    }
  }
}

// --- playbacks ----------------------------------------------------------------------

// Start cue [cue] of [pb]: from released, or the next cue of a running one.
void Engine::start(int pb, int cue, uint32_t now) {
  State &s = st_[pb];
  const Playback &p = show_.playbacks[pb];
  if (cue < 0 || cue >= (int)p.cues.size()) return;
  uint16_t (&snap)[kSlots][kAttrs] = snap_;  // a member: 2.4 kB, too big for the ESP32's network task stack
  computeAll(now, snap);
  bool was = s.active;
  std::vector<Hold> old;
  old.swap(s.holds);
  const Cue &c = p.cues[cue];
  for (const Record &r : c.records) {
    if (!show_.fixtures[r.slot].patched) continue;
    Hold h;
    h.slot = r.slot;
    const Hold *prev = nullptr;
    for (const Hold &o : old) {
      if (o.slot == r.slot) prev = &o;
    }
    for (int a = 0; a < kAttrs; a++) {
      if (a == kIn) continue;
      h.from[a] = snap[r.slot][a];
      if (recordHas(r.bytes, a)) {
        h.sets |= bit(a);
        h.to[a] = recordValue(r.bytes, a);
      } else if (was && prev && ((prev->sets | prev->toBelow) & bit(a))) {
        h.toBelow |= bit(a);
      }
    }
    h.inTo = recordHas(r.bytes, kIn) ? recordValue(r.bytes, kIn) : 0;
    h.inFrom = was && prev ? level(s, *prev, now) : (was ? 0 : s.memory[r.slot]);
    for (int g = 0; g < kFxGens; g++) {
      h.fx[g] = Fx{r.bytes[4 * g], r.bytes[4 * g + 1], r.bytes[4 * g + 2], r.bytes[4 * g + 3]};
    }
    s.holds.push_back(h);
  }
  if (was) {  // fixtures of the previous cue that this one does not have
    for (const Hold &o : old) {
      bool kept = false;
      for (const Hold &h : s.holds) kept |= h.slot == o.slot;
      if (kept) continue;
      Hold h;
      h.slot = o.slot;
      h.toBelow = o.sets | o.toBelow;
      for (int a = 0; a < kAttrs; a++) h.from[a] = snap[o.slot][a];
      h.inFrom = level(s, o, now);
      s.holds.push_back(h);
    }
  }
  for (int slot = 0; slot < kSlots; slot++) s.memory[slot] = 0;
  for (const Hold &h : s.holds) s.memory[h.slot] = h.inTo;
  if (!was) {
    s.order = ++orderCount_;
    if (p.exclusive) {  // section 11
      for (int o = 0; o < kPlaybacks; o++) {
        // within the bank, a row of 8 (test pb_props)
        if (o != pb && o / 8 == pb / 8 && st_[o].active && show_.playbacks[o].exclusive) doRelease(o, now);
      }
    }
  }
  s.active = true;
  s.releasing = false;
  s.cue = cue;
  s.start = now;
  s.cueMs = 0;
  s.cueT0 = now;
  s.follow = c.follow;
  s.fadeMs = c.fadeMs;
  s.doneMs = c.fadeMs + c.delayMs;
  s.doneSent = false;
  event(pb, following_ ? PbEvent::kFollow : PbEvent::kStart, cue);
  s.fxTime = 0;  // the FX clock starts with the cue
  s.fxT0 = now;
}

// The next cue (repeat mode, section 10); false when there is none.
bool Engine::next(int pb, uint32_t now) {
  State &s = st_[pb];
  const Playback &p = show_.playbacks[pb];
  int n = (int)p.cues.size(), i = s.cue, j = i;
  if (n == 0) return false;
  switch (p.repeat) {
    case kLoop: j = (i + 1) % n; break;
    case kBounce:
      if (n == 1) {
        j = 0;
      } else {
        if (i + s.dir < 0 || i + s.dir >= n) s.dir = -s.dir;
        j = i + s.dir;
      }
      break;
    case kRandom: j = rand(pb, i, now, 99) % n; break;
    case kOff:
      if (i >= n - 1) return false;
      j = i + 1;
      break;
  }
  start(pb, j, now);
  return true;
}

void Engine::doRelease(int pb, uint32_t now) {
  State &s = st_[pb];
  if (!s.active || s.releasing) return;
  const Playback &p = show_.playbacks[pb];
  double prog = progress(s, now);
  uint16_t (&snap)[kSlots][kAttrs] = snap_;  // a member: 2.4 kB, too big for the ESP32's network task stack
  computeAll(now, snap);
  for (Hold &h : s.holds) {
    for (int a = 0; a < kAttrs; a++) {
      if (h.sets & bit(a)) h.from[a] = lerp(h.from[a], h.to[a], prog);
      if (h.toBelow & bit(a)) h.from[a] = snap[h.slot][a];  // on its way back: where it is
    }
    h.sets |= h.toBelow;
    h.toBelow = 0;
    h.inFrom = level(s, h, now);
  }
  s.releasing = true;
  s.start = now;
  s.fadeMs = s.cue >= 0 && s.cue < (int)p.cues.size() ? p.cues[s.cue].fadeMs : 0;
  event(pb, PbEvent::kReleasing, s.cue);
  s.flashStarted = false;
  s.soloHeld = false;
}

// Finished releases, follows (fade + delay, section 8), finished fades.
void Engine::advance(uint32_t now) {
  for (int pb = 0; pb < kPlaybacks; pb++) {
    State &s = st_[pb];
    if (s.goHeld && now >= s.goDownAt + kGoHoldMs) {  // GO held 1 s: release (test go_hold)
      s.goHeld = false;
      doRelease(pb, s.goDownAt + kGoHoldMs);
    }
    for (int guard = 0; s.active && guard < 64; guard++) {
      const Playback &p = show_.playbacks[pb];
      if (s.releasing) {
        if (now >= s.start + s.fadeMs) {
          s.active = s.releasing = false;
          s.holds.clear();
          s.cue = -1;
          s.dir = 1;
          event(pb, PbEvent::kReleased, -1);
        }
        break;
      }
      if (progress(s, now) >= 1.0) {  // the fade is done: let go of what faded back
        for (size_t i = 0; i < s.holds.size();) {
          Hold &h = s.holds[i];
          h.toBelow = 0;
          bool fx = h.fx[0].on() || h.fx[1].on() || h.fx[2].on();
          if (h.sets == 0 && h.inTo == 0 && !fx) {
            s.holds.erase(s.holds.begin() + i);
          } else {
            i++;
          }
        }
      }
      if (s.cue < 0 || s.cue >= (int)p.cues.size()) {  // deleted over the network
        doRelease(pb, now);
        break;
      }
      const Cue &c = p.cues[s.cue];
      double atMs = c.fadeMs + c.delayMs;
      if (c.follow && cueClock(s, now) >= atMs) {
        following_ = true;
        bool moved = next(pb, whenClock(s, atMs));
        following_ = false;
        if (moved) continue;
        doRelease(pb, whenClock(s, atMs));  // the end, repeat Off: released (test pb_props)
        break;
      }
      if (ticking_ && !s.doneSent && cueClock(s, now) >= s.doneMs) {  // a frame later, as the LPU
        s.doneSent = true;
        event(pb, PbEvent::kDone, s.cue);
      }
      break;
    }
  }
}

int Engine::phase(int pb, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return 1;
  advance(now);
  const State &s = st_[pb];
  if (!s.active) return 1;
  if (s.releasing) return 4;
  return s.doneSent ? 3 : 2;
}

int Engine::cueIndex(int pb) const { return pb >= 0 && pb < kPlaybacks && st_[pb].active ? st_[pb].cue : -1; }

int Engine::currentCue(int pb, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return -1;
  advance(now);
  const State &s = st_[pb];
  return s.active && !s.releasing ? s.cue : -1;
}

void Engine::swapPlaybacks(int a, int b, uint32_t now) {
  if (a < 0 || a >= kPlaybacks || b < 0 || b >= kPlaybacks || a == b) return;
  advance(now);
  bool ran[2] = {st_[a].active, st_[b].active};  // what each slot showed
  std::swap(show_.playbacks[a], show_.playbacks[b]);
  std::swap(st_[a], st_[b]);
  for (int pb : {b, a}) {  // the LPU's order
    State &s = st_[pb];
    if (ran[pb == b]) event(pb, PbEvent::kReleased, -1);
    s.active = s.releasing = false;
    s.holds.clear();
    s.cue = -1;
    s.dir = 1;
    s.flashHeld = s.flashStarted = s.soloHeld = s.goHeld = false;
  }
}

void Engine::cuesDeleted(int pb, int first, int count, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks || count <= 0) return;
  State &s = st_[pb];
  if (!s.active || s.releasing || s.cue < first) return;
  if (s.cue >= first + count) {
    s.cue -= count;
  } else if (first < (int)show_.playbacks[pb].cues.size()) {
    quiet_ = true;  // the LPU announces nothing (test live_edit)
    start(pb, first, now);
    quiet_ = false;
    s.doneSent = true;
  } else {
    doRelease(pb, now);
  }
}

void Engine::event(int pb, PbEvent::Kind k, int cue) {
  if (quiet_ || events_.size() >= 256) return;
  events_.push_back(PbEvent((uint8_t)pb, k, (int16_t)cue));
}

std::vector<PbEvent> Engine::takeEvents() {
  std::vector<PbEvent> out;
  out.swap(events_);
  return out;
}

void Engine::go(int pb, uint32_t now) {
  goButton(pb, true, now);
  goButton(pb, false, now);
}

void Engine::goButton(int pb, bool down, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return;
  advance(now);
  State &s = st_[pb];
  switch (show_.playbacks[pb].goMode) {
    case kGo:  // on let go, under 1 s held (test go_hold; advance() for longer)
      if (down) {
        s.goHeld = true;
        s.goDownAt = now;
        return;
      }
      if (!s.goHeld) return;
      s.goHeld = false;
      if (!s.active) {
        start(pb, 0, now);
      } else if (s.releasing) {  // GO during the release: on with the next cue (test release_go)
        if (!next(pb, now)) start(pb, s.cue, now);
      } else if (!next(pb, now)) {  // the end, repeat Off: the cue again (no change on DMX)
        const Cue &c = show_.playbacks[pb].cues[s.cue];
        s.doneMs = cueClock(s, now) + c.fadeMs + c.delayMs;
        s.doneSent = false;
        event(pb, PbEvent::kRestart, s.cue);
      }
      break;
    case kToggle:
      if (!down) return;
      if (!s.active) {
        start(pb, 0, now);
      } else if (s.releasing) {  // as Go: on with the next cue (measured 2026-10-30)
        if (!next(pb, now)) start(pb, s.cue, now);
      } else {
        doRelease(pb, now);
      }
      break;
    case kFlash:
    case kSolo:  // on while held; Solo also blacks out the others (section 10)
      if (down) {
        if (!s.active || s.releasing) start(pb, 0, now);
        s.soloHeld = show_.playbacks[pb].goMode == kSolo;
      } else {
        doRelease(pb, now);
      }
      break;
  }
}

void Engine::flashButton(int pb, bool down, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return;
  advance(now);
  State &s = st_[pb];
  if (down) {
    if (s.releasing) return;  // FLASH during a release: nothing (measured 2026-10-30)
    if (!s.active) {
      start(pb, 0, now);
      s.flashStarted = true;
    }
    s.flashHeld = true;
    if (show_.playbacks[pb].goMode == kSolo) s.soloHeld = true;  // section 10
  } else {
    s.flashHeld = false;
    if (show_.playbacks[pb].goMode == kSolo) s.soloHeld = false;
    if (s.flashStarted) doRelease(pb, now);
  }
}

void Engine::release(int pb, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return;
  advance(now);
  doRelease(pb, now);
}

void Engine::releaseAll(uint32_t now) {
  advance(now);
  for (int pb = 0; pb < kPlaybacks; pb++) {
    if (!show_.playbacks[pb].background) doRelease(pb, now);  // section 11
  }
}

void Engine::setIntensity(int pb, float fader, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return;
  advance(now);
  show_.playbacks[pb].intensity = fader < 0 ? 0 : (fader > 1 ? 1 : fader);
}

void Engine::setSpeed(int pb, float knob, uint32_t now) {
  if (pb < 0 || pb >= kPlaybacks) return;
  advance(now);
  State &s = st_[pb];
  s.fxTime = fxTime(s, now);
  s.fxT0 = now;
  s.cueMs = cueClock(s, now);
  s.cueT0 = now;
  show_.playbacks[pb].speed = knob;
}

void Engine::setMemory(int pb, int slot, uint16_t level) {
  if (pb >= 0 && pb < kPlaybacks && slot >= 0 && slot < kSlots) st_[pb].memory[slot] = level;
}

// --- programmer (section 12) ------------------------------------------------------

void Engine::setEditing(bool editing, uint32_t now) {
  advance(now);
  editing_ = editing;
}

void Engine::select(uint64_t slots) { selection_ = slots; }

void Engine::programmerAttr(Attr a, uint16_t dmx16) {
  for (int slot = 0; slot < kSlots; slot++) {
    if (selection_ >> slot & 1) {
      prog_[slot].sets |= bit(a);
      prog_[slot].v[a] = dmx16;
    }
  }
}

void Engine::programmerColour(const uint16_t rgbaw[5]) {
  for (int i = 0; i < 5; i++) programmerAttr((Attr)(kR + i), rgbaw[i]);
}

void Engine::programmerPosition(uint16_t pan16, uint16_t tilt16) {
  programmerAttr(kPan, pan16);
  programmerAttr(kTilt, tilt16);
}

void Engine::programmerFx(FxGen g, const Fx &fx, uint32_t now) {
  for (int slot = 0; slot < kSlots; slot++) {
    if (selection_ >> slot & 1) prog_[slot].fx[g] = fx;
  }
  progFxT0_ = now;
}

// CLEAR in EDIT clears the whole programmer; with EDIT closed only the
// selected fixtures (section 12, test clear_closed).
void Engine::programmerClear() {
  for (int slot = 0; slot < kSlots; slot++) {
    if (editing_ || (selection_ >> slot & 1)) prog_[slot] = Prog();
  }
}

void Engine::load(int pb, int cue, uint32_t now) {
  (void)now;
  if (pb < 0 || pb >= kPlaybacks) return;
  const Playback &p = show_.playbacks[pb];
  if (cue < 0 || cue >= (int)p.cues.size()) return;
  for (Prog &g : prog_) g = Prog();
  selection_ = 0;
  for (const Record &r : p.cues[cue].records) {
    Prog &g = prog_[r.slot];
    for (int a = 0; a < kAttrs; a++) {
      if (recordHas(r.bytes, a)) {
        g.sets |= bit(a);
        g.v[a] = recordValue(r.bytes, a);
      }
    }
    for (int i = 0; i < kFxGens; i++) g.fx[i] = Fx{r.bytes[4 * i], r.bytes[4 * i + 1], r.bytes[4 * i + 2], r.bytes[4 * i + 3]};
    selection_ |= 1ull << r.slot;
  }
}

bool Engine::programmerRecord(int slot, uint8_t *rec) const {
  memset(rec, 0, kRecordSize);
  if (slot < 0 || slot >= kSlots) return false;
  const Prog &g = prog_[slot];
  bool any = false;
  for (int i = 0; i < kFxGens; i++) {
    const Fx &f = g.fx[i];
    rec[4 * i] = f.wave, rec[4 * i + 1] = f.size, rec[4 * i + 2] = f.speed, rec[4 * i + 3] = f.phase;
    any |= f.wave || f.size || f.speed || f.phase;
  }
  for (int a = 0; a < kAttrs; a++) {
    if (!(g.sets & bit(a))) continue;
    // pan / tilt signed around the centre (recordValue the other way)
    uint16_t raw = isPos(a) ? (uint16_t)(int16_t)(g.v[a] - kCentre) : g.v[a];
    rec[12 + 2 * a] = raw, rec[13 + 2 * a] = raw >> 8;
    any = true;
  }
  return any;
}

}  // namespace lpd
