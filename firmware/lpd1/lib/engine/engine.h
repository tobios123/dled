// engine.h -- the LPD-1's DMX engine: what the LPU-1 puts on DMX for a show,
// as measured from its Art-Net output (lpd/DMX_ENGINE.md, section numbers in
// the comments of engine.cpp). Portable C++17: no Arduino calls, time is
// passed in (ms), so the same code runs on the ESP32 and in the PC tests
// (pio test -e native, replaying the LPU's recordings).
//
// Use: fill show(), then call the actions with the time they happen and
// render() for every DMX frame (40 / s), all in time order.

#pragma once

#include <stdint.h>

#include <string>
#include <vector>

namespace lpd {

constexpr int kSlots = 64;       // fixtures
constexpr int kPlaybacks = 64;
constexpr int kRecordSize = 50;  // one fixture in a cue
constexpr int kUniverse = 512;

// Attributes in record order: the value of attribute a is the u16 LE at
// record byte 12 + 2a (pan / tilt signed around the centre).
enum Attr : uint8_t {
  kPan, kTilt, kIn, kCol, kR, kG, kB, kA, kW, kGobo, kRota, kSh, kIris, kFrost,
  kFocus, kPrism, kZoom, kC1, kC2, kAttrs
};
enum GoMode : uint8_t { kGo, kToggle, kFlash, kSolo };
enum Repeat : uint8_t { kLoop, kBounce, kRandom, kOff };
enum FxGen : uint8_t { kFxIntensity, kFxPosition, kFxColour, kFxGens };

struct Fixture {
  bool patched = false;
  uint16_t address = 0;  // DMX 1-512
  uint8_t count = 0;     // channels
  uint8_t codes[64] = {};
  bool invertPan = false, invertTilt = false, swapPanTilt = false, virtualDimmer = false;
  bool has(uint8_t code) const;
};

struct Record {
  uint8_t slot;
  uint8_t bytes[kRecordSize];
};

struct Cue {
  std::vector<Record> records;  // fixtures with data only
  std::string label;
  uint32_t fadeMs = 0, delayMs = 0;
  bool follow = false;
  const Record *record(int slot) const;
};

struct Playback {
  std::vector<Cue> cues;
  std::string label;
  GoMode goMode = kGo;
  Repeat repeat = kLoop;
  bool background = false, exclusive = false;
  float intensity = 1.0f;  // the fader, 0..1
  float speed = 0.0f;      // the speed knob, -1..1
};

struct Show {
  Fixture fixtures[kSlots];
  Playback playbacks[kPlaybacks];
};

// One FX generator of one fixture: the 4 record bytes.
struct Fx {
  uint8_t wave = 0, size = 0, speed = 0, phase = 0;
  Fx() = default;
  Fx(uint8_t w, uint8_t sz, uint8_t sp, uint8_t ph) : wave(w), size(sz), speed(sp), phase(ph) {}
  bool on() const { return wave != 0; }
};

// What the VN protocol announces of a playback (the LPU's active cue 2f and
// phase 24; tests cuelist, gomodes, live_edit): a cue started by GO / FLASH
// (2f if another cue, phase 2), by a follow (2f only), GO at the end of a
// list with repeat Off (phase 4 then 2: the LPU restarts the cue), the cue's
// fade + delay over (phase 3), a release begun (4) and over (2f ff, phase 1).
struct PbEvent {
  enum Kind : uint8_t { kStart, kFollow, kRestart, kDone, kReleasing, kReleased };
  uint8_t pb;
  Kind kind;
  int16_t cue;
  PbEvent(uint8_t p, Kind k, int16_t c) : pb(p), kind(k), cue(c) {}
};

class Engine {
 public:
  explicit Engine(uint32_t seed = 1);

  Show &show() { return show_; }

  // --- the playbacks (pb 0-63) ---
  void go(int pb, uint32_t now);  // the GO button pressed and let go
  void goButton(int pb, bool down, uint32_t now);
  void flashButton(int pb, bool down, uint32_t now);
  void release(int pb, uint32_t now);
  void releaseAll(uint32_t now);
  void setIntensity(int pb, float fader, uint32_t now);
  void setSpeed(int pb, float knob, uint32_t now);
  // The intensity a playback remembers for a fixture (section 8): fades on
  // GO start there. Set from outside only to replay a recording.
  void setMemory(int pb, int slot, uint16_t level);

  // --- EDIT and the programmer ---
  void setEditing(bool editing, uint32_t now);
  void select(uint64_t slots);
  void programmerAttr(Attr a, uint16_t dmx16);
  void programmerColour(const uint16_t rgbaw[5]);
  void programmerPosition(uint16_t pan16, uint16_t tilt16);
  void programmerFx(FxGen g, const Fx &fx, uint32_t now);
  void programmerClear();
  void load(int pb, int cue, uint32_t now);
  // RECORD (section 12): fixture [slot] of the programmer as a cue record
  // in [rec] (kRecordSize bytes): its own values and FX. False when it has
  // none: it is not part of the recorded cue.
  bool programmerRecord(int slot, uint8_t *rec) const;

  // The DMX frame at [now].
  void render(uint32_t now, uint8_t dmx[kUniverse]);

  // The cue a playback is on, -1 when it is off or releasing (for the VN
  // protocol's notifications). Cues may be added / deleted in show() while a
  // playback runs; one that runs on a deleted cue stops at its next step.
  int currentCue(int pb, uint32_t now);
  // The LPU's phase: 1 idle, 2 fade / delay running, 3 holding, 4 releasing;
  // and the cue, also while releasing (-1: off).
  int phase(int pb, uint32_t now);
  int cueIndex(int pb) const;
  // After show().playbacks[pb].cues lost [first, first + count): a playback
  // on a deleted cue goes to the cue now at that place at once, like the LPU
  // (test live_edit); one on a later cue keeps it.
  void cuesDeleted(int pb, int first, int count, uint32_t now);
  // The LPU's swap button: two playbacks change places; both stop at once
  // (test live_edit: the LPU's output drops to 0, no fade).
  void swapPlaybacks(int a, int b, uint32_t now);
  // Ends fades, follows and releases that are due (events); call it every
  // frame. A finished fade (kDone) is only announced from here.
  void update(uint32_t now) {
    ticking_ = true;
    advance(now);
    ticking_ = false;
  }
  // The events since the last call, in order (at most 256 are kept).
  std::vector<PbEvent> takeEvents();

 private:
  struct Hold {  // a playback's hold on one fixture
    uint8_t slot;
    uint32_t sets = 0;      // attributes with a target (bit per Attr, not kIn)
    uint32_t toBelow = 0;   // attributes fading back to what is underneath
    uint16_t from[kAttrs] = {}, to[kAttrs] = {};
    uint16_t inFrom = 0, inTo = 0;
    Fx fx[kFxGens];
  };
  struct State {
    bool active = false, releasing = false;
    int cue = -1, dir = 1;
    uint32_t start = 0, fadeMs = 0;  // the running fade (GO or release)
    double cueMs = 0;                 // the cue clock (knob-scaled ms) at cueT0
    bool follow = false;              // the running cue follows (its fade on the cue clock)
    uint32_t cueT0 = 0;
    double doneMs = 0;                // the cue clock when fade + delay are over (kDone)
    bool doneSent = true;
    uint32_t order = 0;               // LTP: later start wins
    double fxTime = 0;                // FX clock in seconds at normal speed
    uint32_t fxT0 = 0;
    bool flashHeld = false, flashStarted = false, soloHeld = false;
    bool goHeld = false;  // Go mode: GO down, not yet held 1 s
    uint32_t goDownAt = 0;
    std::vector<Hold> holds;
    uint16_t memory[kSlots] = {};
  };
  struct Prog {
    uint32_t sets = 0;
    uint16_t v[kAttrs] = {};
    Fx fx[kFxGens];
  };

  void start(int pb, int cue, uint32_t now);
  bool next(int pb, uint32_t now);
  void doRelease(int pb, uint32_t now);
  void advance(uint32_t now);
  void event(int pb, PbEvent::Kind k, int cue);
  double progress(const State &s, uint32_t now) const;
  double cueClock(const State &s, uint32_t now) const;
  uint32_t whenClock(const State &s, double ms) const;
  double fxTime(const State &s, uint32_t now) const;
  uint16_t level(const State &s, const Hold &h, uint32_t now) const;  // intensity
  int fxAdd(FxGen g, const Fx &fx, double t, int slot, int pb) const;
  void colourFx(const Fx &fx, double t, int slot, int pb, int add[3]) const;
  void positionFx(const Fx &fx, double t, int slot, int pb, int add[2]) const;
  void computeAll(uint32_t now, uint16_t out[kSlots][kAttrs]);
  uint32_t rand(uint32_t a, uint32_t b, uint32_t c, uint32_t d) const;

  Show show_;
  State st_[kPlaybacks];
  uint32_t orderCount_ = 0;
  std::vector<PbEvent> events_;
  bool following_ = false, quiet_ = false, ticking_ = false;
  uint32_t seed_;
  bool editing_ = false;
  uint64_t selection_ = 0;
  Prog prog_[kSlots];
  uint32_t progFxT0_ = 0;
  uint16_t out_[kSlots][kAttrs];  // the last frame, for "from" snapshots
  uint16_t snap_[kSlots][kAttrs];  // start() / doRelease(): where everything is now
};

}  // namespace lpd
