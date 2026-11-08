// Replay the LPU's recordings into the engine and compare the DMX
// (lpd/replay/*.txt, made by lpd/make_replay.py; format there).
//
// For every 25 ms of a recording and every channel (fine channels left
// out): the LPU's value must lie within the engine's values (+-1) of the
// +-37.5 ms around it (the LPU and the recording PC each add up to a frame
// of delay).
// Masked stretches (random FX, lost frames) are not compared. A test passes
// at its expected score (kExpected); the output lists the worst steps.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unity.h>

#include <algorithm>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "engine.h"

using namespace lpd;

namespace {

struct Step {
  double t;
  std::string op;
  std::vector<double> args;
};
struct Mask {
  double from, to;
  int ch0, ch1;
};
struct Change {
  double t;
  std::vector<std::pair<int, int>> d;
};

struct Replay {
  std::string name;
  Engine engine;
  std::vector<Step> steps;
  std::vector<Mask> masks;
  std::vector<Change> frames;  // the first one is the full frame
  bool fine[kUniverse] = {};   // fine channels: not compared
};

int hexByte(const char *s) {
  auto v = [](char c) { return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10; };
  return v(s[0]) << 4 | v(s[1]);
}

bool load(const std::string &path, Replay &r) {
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) return false;
  Show &show = r.engine.show();
  static char line[1 << 16];
  while (fgets(line, sizeof line, f)) {
    std::istringstream in(line);
    std::string kind;
    in >> kind;
    if (kind == "F") {
      int slot, addr, ip, it, sw, vd;
      std::string codes;
      in >> slot >> addr >> codes >> ip >> it >> sw >> vd;
      Fixture &fx = show.fixtures[slot];
      fx.patched = true;
      fx.address = addr;
      fx.count = codes == "-" ? 0 : codes.size() / 2;
      for (int i = 0; i < fx.count; i++) {
        fx.codes[i] = hexByte(codes.c_str() + 2 * i);
        int code = fx.codes[i];
        if (code > 0x20 && code <= 0x33 && addr - 1 + i < kUniverse) r.fine[addr - 1 + i] = true;
      }
      fx.invertPan = ip, fx.invertTilt = it, fx.swapPanTilt = sw, fx.virtualDimmer = vd;
    } else if (kind == "P") {
      int pb, gm, rp, bg, ex;
      float in_, sp;
      in >> pb >> gm >> rp >> bg >> ex >> in_ >> sp;
      Playback &p = show.playbacks[pb];
      p.goMode = (GoMode)gm, p.repeat = (Repeat)rp, p.background = bg, p.exclusive = ex;
      p.intensity = in_, p.speed = sp;
    } else if (kind == "C") {
      int pb, cue, fade, delay, follow;
      in >> pb >> cue >> fade >> delay >> follow;
      Playback &p = show.playbacks[pb];
      if ((int)p.cues.size() <= cue) p.cues.resize(cue + 1);
      p.cues[cue].fadeMs = fade, p.cues[cue].delayMs = delay, p.cues[cue].follow = follow;
    } else if (kind == "R") {
      int pb, cue, slot;
      std::string hex;
      in >> pb >> cue >> slot >> hex;
      Record rec{(uint8_t)slot, {}};
      for (int i = 0; i < kRecordSize; i++) rec.bytes[i] = hexByte(hex.c_str() + 2 * i);
      show.playbacks[pb].cues[cue].records.push_back(rec);
    } else if (kind == "M") {
      int pb, slot, level;
      in >> pb >> slot >> level;
      r.engine.setMemory(pb, slot, level);
    } else if (kind == "S") {
      Step s;
      in >> s.t >> s.op;
      double a;
      while (in >> a) s.args.push_back(a);
      r.steps.push_back(s);
    } else if (kind == "K") {
      Mask m;
      in >> m.from >> m.to >> m.ch0 >> m.ch1;
      r.masks.push_back(m);
    } else if (kind == "X") {
      Change c;
      in >> c.t;
      std::string kv;
      while (in >> kv) {
        size_t colon = kv.find(':');
        c.d.push_back({atoi(kv.c_str()), atoi(kv.c_str() + colon + 1)});
      }
      r.frames.push_back(c);
    }
  }
  fclose(f);
  return !r.frames.empty();
}

void apply(Engine &e, const Step &s) {
  uint32_t t = (uint32_t)(s.t + 0.5);
  auto pb = [&](int i = 0) { return (int)s.args[i]; };
  if (s.op == "releaseAll") e.releaseAll(t);
  else if (s.op == "go") e.go(pb(), t);
  else if (s.op == "release") e.release(pb(), t);
  else if (s.op == "intensity") e.setIntensity(pb(), s.args[1], t);
  else if (s.op == "speed") e.setSpeed(pb(), s.args[1], t);
  else if (s.op == "goDown" || s.op == "goUp") e.goButton(pb(), s.op == "goDown", t);
  else if (s.op == "flashDown" || s.op == "flashUp") e.flashButton(pb(), s.op == "flashDown", t);
  else if (s.op == "edit") e.setEditing(s.args[0] != 0, t);
  else if (s.op == "select") {
    uint64_t m = 0;
    for (double a : s.args) m |= 1ull << (int)a;
    e.select(m);
  } else if (s.op == "progAttr") e.programmerAttr((Attr)pb(), (uint16_t)s.args[1]);
  else if (s.op == "progColour") {
    uint16_t c[5];
    for (int i = 0; i < 5; i++) c[i] = (uint16_t)s.args[i];
    e.programmerColour(c);
  } else if (s.op == "progPos") e.programmerPosition((uint16_t)s.args[0], (uint16_t)s.args[1]);
  else if (s.op == "progFx") {
    Fx fx{(uint8_t)s.args[1], (uint8_t)s.args[2], (uint8_t)s.args[3], (uint8_t)s.args[4]};
    e.programmerFx((FxGen)pb(), fx, t);
  } else if (s.op == "progClear") e.programmerClear();
  else if (s.op == "load") e.load(pb(), pb(1), t);
}

// Score: matching channel-samples / compared ones.
struct Result {
  long compared = 0, matched = 0;
  std::map<int, long> badPerStep;   // step index -> mismatches
  std::map<int, std::string> example;  // step index -> one mismatch
  std::map<int, std::map<int, long>> badCh;  // step index -> channel -> mismatches
};

Result run(Replay &r) {
  const double dt = 12.5, window = 37.5, t0 = r.frames.front().t, t1 = r.frames.back().t + 1000;
  int n = (int)((t1 - t0) / dt) + 1;
  std::vector<uint8_t> eng((size_t)n * kUniverse);
  size_t si = 0;
  std::vector<double> stepT;
  for (const Step &s : r.steps) stepT.push_back(s.t);
  for (int i = 0; i < n; i++) {
    double t = t0 + i * dt;
    while (si < r.steps.size() && r.steps[si].t <= t) apply(r.engine, r.steps[si++]);
    r.engine.render((uint32_t)(t + 0.5), &eng[(size_t)i * kUniverse]);
  }
  Result res;
  // LPD_TRACE=ch,fromMs,toMs: print the LPU and the engine side by side
  int trCh = 0;
  double trFrom = 0, trTo = 0;
  if (const char *tr = getenv("LPD_TRACE")) sscanf(tr, "%d,%lf,%lf", &trCh, &trFrom, &trTo);
  uint8_t rec[kUniverse] = {};
  size_t fi = 0;
  int w = (int)(window / dt);
  for (int i = w; i < n - w; i += 2) {  // every 25 ms
    double t = t0 + i * dt;
    while (fi < r.frames.size() && r.frames[fi].t <= t) {
      for (auto &kv : r.frames[fi].d) rec[kv.first - 1] = kv.second;
      fi++;
    }
    int step = (int)(std::upper_bound(stepT.begin(), stepT.end(), t) - stepT.begin()) - 1;
    if (trCh && t >= trFrom && t <= trTo) {
      printf("  %8.1f  LPU %3d  engine %3d\n", t, rec[trCh - 1], eng[(size_t)i * kUniverse + trCh - 1]);
    }
    for (int ch = 0; ch < kUniverse; ch++) {
      if (r.fine[ch]) continue;
      bool masked = false;
      for (const Mask &m : r.masks) {
        if (t >= m.from && t <= m.to && ch + 1 >= m.ch0 && ch + 1 <= m.ch1) masked = true;
      }
      if (masked) continue;
      res.compared++;
      int lo = 255, hi = 0;
      for (int k = i - w; k <= i + w; k++) {
        int v = eng[(size_t)k * kUniverse + ch];
        lo = std::min(lo, v), hi = std::max(hi, v);
      }
      bool ok = rec[ch] >= lo - 1 && rec[ch] <= hi + 1;
      if (ok) {
        res.matched++;
      } else {
        res.badCh[step][ch + 1]++;
        if (res.badPerStep[step]++ == 0) {
          char buf[160];
          snprintf(buf, sizeof buf, "t %.0f ms ch %d: LPU %d, engine %d..%d", t, ch + 1, rec[ch], lo, hi);
          res.example[step] = buf;
        }
      }
    }
  }
  return res;
}

std::string dir;
std::string current;

// Expected scores (fraction of channel-samples that match); anything below
// fails. Raise these when the engine gets better.
std::map<std::string, double> kExpected = {
    // INSERT / DELETE / SWAP / RECORD are the VN server's (lpd/compare.py on
    // the box checks those): the engine alone misses the recorded cue
    {"live_edit", 0.997},
};

void testOne() {
  Replay *r = new Replay();
  r->name = current;
  TEST_ASSERT_TRUE_MESSAGE(load(dir + "/" + current + ".txt", *r), current.c_str());
  Result res = run(*r);
  double score = res.compared ? (double)res.matched / res.compared : 1;
  printf("%-14s %8.4f  (%ld of %ld channel-samples)\n", current.c_str(), score, res.matched, res.compared);
  std::vector<std::pair<long, int>> worst;
  for (auto &kv : res.badPerStep) worst.push_back({kv.second, kv.first});
  std::sort(worst.rbegin(), worst.rend());
  for (size_t i = 0; i < worst.size() && i < 4; i++) {
    int st = worst[i].second;
    std::string what = st < 0 ? "(before the first step)" : r->steps[st].op;
    if (st >= 0) {
      for (double a : r->steps[st].args) {
        char b[24];
        snprintf(b, sizeof b, " %g", a);
        what += b;
      }
    }
    printf("    %6ld bad after step %d %s; e.g. %s\n", worst[i].first, st, what.c_str(), res.example[st].c_str());
    std::vector<std::pair<long, int>> chs;
    for (auto &kv : res.badCh[st]) chs.push_back({kv.second, kv.first});
    std::sort(chs.rbegin(), chs.rend());
    printf("           channels:");
    for (size_t k = 0; k < chs.size() && k < 8; k++) printf(" %d(%ld)", chs[k].second, chs[k].first);
    printf("\n");
  }
  double want = kExpected.count(current) ? kExpected[current] : 0.998;
  delete r;
  TEST_ASSERT_TRUE_MESSAGE(score >= want, (current + " below its expected score").c_str());
}

}  // namespace

void setUp() {}
void tearDown() {}

int main(int argc, char **argv) {
  for (const char *d : {"../../lpd/replay", "../../../lpd/replay", "lpd/replay"}) {
    if (DIR *h = opendir(d)) {
      closedir(h);
      dir = d;
      break;
    }
  }
  std::vector<std::string> names;
  if (DIR *h = opendir(dir.c_str())) {
    while (dirent *e = readdir(h)) {
      std::string n = e->d_name;
      if (n.size() > 4 && n.substr(n.size() - 4) == ".txt") names.push_back(n.substr(0, n.size() - 4));
    }
    closedir(h);
  }
  std::sort(names.begin(), names.end());
  if (const char *only = getenv("LPD_REPLAY")) names = {only};
  UNITY_BEGIN();
  if (names.empty()) {
    printf("no replay files found: run python lpd/make_replay.py in the repository first\n");
    return 1;
  }
  for (const std::string &n : names) {
    current = n;
    UnityDefaultTestRun(testOne, current.c_str(), __LINE__);
  }
  return UNITY_END();
}
