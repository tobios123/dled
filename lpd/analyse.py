"""Analyse an LPD recording: what every fixture attribute did after each step.

  python lpd/analyse.py NAME            (the newest lpd/recordings/NAME_*.jsonl)
  python lpd/analyse.py RECORDING.jsonl [--show lpd/tests/NAME.show]

Per step (GO, release, a fader ...), until the next one, per attribute over
the fixtures of the test show (pan / tilt with their fine channel as 16 bit,
all values on a 0-255 scale):
  - constant:   "= v" when it differs from the step before, else left out
  - a fade:     start -> end, when it started / ended after the step, the
                curve at 0, 10 ... 100 % of the fade time
  - a wave:     min..max, period (autocorrelation), one period as 16 points
                starting at the minimum, and per fixture the phase lag
                behind fixture 1 (fraction of the period)
Values are sample-and-hold at 40 frames/s from the change-only recording.
"""
import glob
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DT = 0.025  # seconds per frame
NAMES = {0x01: "In", 0x02: "Pan", 0x03: "Tilt", 0x04: "R", 0x05: "G", 0x06: "B", 0x07: "A", 0x08: "W",
         0x09: "Col", 0x0A: "Gobo", 0x0B: "Rota", 0x0C: "Sh", 0x0D: "Iris", 0x0E: "Frost", 0x0F: "Focus",
         0x10: "Prism", 0x11: "Zoom", 0x12: "C1", 0x13: "C2", 0x14: "PTspeed", 0x80: "none"}
QUIET = {"wait", "snap"}


def load(path):
    marks, changes, first = [], [], None
    for line in open(path, encoding="utf-8"):
        o = json.loads(line)
        if "full" in o:
            first = o
        elif "d" in o:
            changes.append((o["t"] / 1000, {int(k): v for k, v in o["d"].items()}))
        elif "mark" in o:
            marks.append(o)
    return first, changes, marks


def fixtures(show_path):
    out = []
    for m in re.finditer(r"<fixture\b([^>]*)/?>", open(show_path, encoding="utf-8").read()):
        a = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        codes = [int(a["profile"][i:i + 2], 16) for i in range(0, len(a.get("profile", "")), 2)]
        out.append((int(a["index"]), int(a.get("address", 0)), codes))
    return sorted(out)


def channels(fx):
    """(fixture, attr, coarse channel, fine channel or None) per attribute."""
    out = []
    for idx, addr, codes in fx:
        for i, c in enumerate(codes):
            if c not in NAMES or c == 0x80:
                continue
            fine = codes.index(c + 0x20) if c + 0x20 in codes else None
            out.append((idx, NAMES[c], addr + i, None if fine is None else addr + fine))
    return out


def sampler(first, changes):
    """value(ch, t) for times in order (sample-and-hold)."""
    state = list(first["full"]) + [0] * (512 - len(first["full"]))
    t0 = first["t"] / 1000
    series_t = [t0] + [t for t, _ in changes]
    return state, changes


def series(first, changes, chans, t_from, t_to):
    """{(fixture, attr): [values 0..255 float]} sampled every DT in [t_from, t_to)."""
    state = list(first["full"]) + [0] * 512
    i = 0
    out = {(f, a): [] for f, a, _, _ in chans}
    t = t_from
    while i < len(changes) and changes[i][0] <= t_from:
        for ch, v in changes[i][1].items():
            state[ch - 1] = v
        i += 1
    while t < t_to:
        while i < len(changes) and changes[i][0] <= t:
            for ch, v in changes[i][1].items():
                state[ch - 1] = v
            i += 1
        for f, a, c, fine in chans:
            v = state[c - 1] + (state[fine - 1] / 256 if fine else 0)
            out[(f, a)].append(v)
        t += DT
    return out


def period(xs):
    n = len(xs)
    if n < 40:
        return None, 0
    m = sum(xs) / n
    d = [x - m for x in xs]
    var = sum(x * x for x in d)
    if var < 1e-9:
        return None, 0
    best, best_r, crossed = None, 0, False
    for lag in range(4, n // 2):
        r = sum(d[k] * d[k + lag] for k in range(n - lag)) / var * n / (n - lag)
        if r < 0:
            crossed = True
        if crossed and r > best_r:
            best, best_r = lag, r
    return best, best_r


def lag(a, b, p):
    """Lag of b behind a, in samples (0..p-1), by cross-correlation."""
    n = min(len(a), len(b))
    ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
    best, best_r = 0, -1e18
    for L in range(p):
        r = sum((a[k] - ma) * (b[k + L] - mb) for k in range(n - L))
        if r > best_r:
            best, best_r = L, r
    return best


def describe(xs, t_step, t_seg):
    lo, hi = min(xs), max(xs)
    if hi - lo < 0.01:
        return "const", f"= {fmt(xs[0])}"
    turns = sum(1 for k in range(1, len(xs) - 1)
                if (xs[k] - xs[k - 1]) * (xs[k + 1] - xs[k]) < 0 and abs(xs[k + 1] - xs[k - 1]) > 0.02)
    moving = [k for k in range(1, len(xs)) if abs(xs[k] - xs[k - 1]) > 0.004]
    if len(moving) > 12 and wave(xs):
        turns = 99  # a (clipped) wave: flat stretches hide its turns
    if turns < 3 and moving:
        a, b = moving[0] - 1, moving[-1]
        dur = (b - a) * DT
        pts = [xs[a + round((b - a) * q / 10)] for q in range(11)] if b > a else [xs[a], xs[b]]
        if dur < 0.06:
            return "step", f"{fmt(xs[0])} -> {fmt(xs[-1])} at +{a * DT + t_seg - t_step:.2f} s"
        return "fade", (f"{fmt(xs[0])} -> {fmt(xs[-1])} from +{a * DT + t_seg - t_step:.2f} s for {dur:.2f} s;"
                        f" curve {' '.join(fmt(v) for v in pts)}")
    w = wave(xs)
    if w is None:
        return "wave", f"{fmt(lo)}..{fmt(hi)} irregular (mean {fmt(sum(xs) / len(xs))}, {turns} turns)"
    per, ups, shape, n = w
    return "wave", (f"{fmt(lo)}..{fmt(hi)} period {per:.3f} s ({n} cycles); one period from the upward "
                    f"mid crossing: {' '.join(fmt(v) for v in shape)}")


def wave(xs, skip=0.3):
    """(period s, upward mid-level crossing times, 16-point average shape, cycles)
    or None: the period from the crossings of (min+max)/2, the shape by folding
    every sample into 16 phase bins."""
    k0 = int(skip / DT)
    ys = xs[k0:]
    if len(ys) < 20:
        return None
    lo, hi = min(ys), max(ys)
    mid = (lo + hi) / 2
    ups = []
    for k in range(1, len(ys)):
        if ys[k - 1] < mid <= ys[k]:
            # interpolate within the frame
            f = (mid - ys[k - 1]) / (ys[k] - ys[k - 1])
            ups.append((k0 + k - 1 + f) * DT)
    if len(ups) < 3:
        return None
    gaps = [b - a for a, b in zip(ups, ups[1:])]
    gaps.sort()
    med = gaps[len(gaps) // 2]
    if med <= 0 or gaps[-1] > 2.5 * med or gaps[0] < 0.4 * med:
        return None  # irregular
    per = (ups[-1] - ups[0]) / round((ups[-1] - ups[0]) / med)
    bins = [[] for _ in range(16)]
    for k, y in enumerate(ys):
        t = (k0 + k) * DT
        ph = ((t - ups[0]) / per) % 1.0
        bins[int(ph * 16) % 16].append(y)
    shape = [sum(b) / len(b) if b else float("nan") for b in bins]
    return per, ups, shape, len(ups) - 1


def fmt(v):
    return f"{v:.0f}" if abs(v - round(v)) < 0.05 else f"{v:.1f}"


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    show = None
    if "--show" in argv:
        show = argv[argv.index("--show") + 1]
        args.remove(show)
    rec = args[0]
    if not rec.endswith(".jsonl"):
        recs = sorted(glob.glob(os.path.join(HERE, "recordings", f"{rec}_*.jsonl")))
        if not recs:
            sys.exit(f"no recording for {rec}")
        rec = recs[-1]
    name = re.sub(r"_\d{4}-\d\d-\d\d_.*", "", os.path.basename(rec))
    show = show or os.path.join(HERE, "tests", f"{name}.show")
    first, changes, marks = load(rec)
    chans = channels(fixtures(show))
    print(f"{os.path.basename(rec)}  ({len(chans)} attributes)")
    steps = [m for m in marks if m["mark"] not in QUIET]
    end = max([m["t"] for m in marks] + [c[0] * 1000 for c in changes]) / 1000 + 0.5
    prev = {}
    for i, m in enumerate(steps):
        t_step = m["t"] / 1000
        t_next = steps[i + 1]["t"] / 1000 if i + 1 < len(steps) else end
        extra = {k: v for k, v in m.items() if k not in ("t", "mark")}
        print(f"\n[{t_step:7.2f}] {m['mark']} {' '.join(f'{k}={v}' for k, v in extra.items())}"
              f"  ({t_next - t_step:.1f} s)")
        data = series(first, changes, chans, t_step, t_next)
        by_attr = {}
        for (f, a), xs in data.items():
            if not xs:
                continue
            kind, text = describe(xs, t_step, t_step)
            if kind == "const" and prev.get((f, a)) is not None and abs(prev[(f, a)] - xs[0]) < 0.01:
                prev[(f, a)] = xs[-1]
                continue
            prev[(f, a)] = xs[-1]
            by_attr.setdefault(a, []).append((f, kind, text, xs))
        for a, rows in by_attr.items():
            texts = {}
            for f, kind, text, _ in rows:
                texts.setdefault(text, []).append(f + 1)
            for text, fs in texts.items():
                who = "all" if len(fs) == len(rows) and len(rows) > 1 else "F" + ",".join(map(str, fs))
                if len(fs) > 6:
                    who = f"F{fs[0]}..F{fs[-1]} ({len(fs)})"
                print(f"  {a:6} {who:14} {text}")
            waves = [(f, wave(xs)) for f, kind, _, xs in rows if kind == "wave"]
            waves = [(f, w) for f, w in waves if w]
            if len(waves) > 1:
                per0, ups0 = waves[0][1][0], waves[0][1][1]
                lags = [(((w[1][0] - ups0[0]) / per0) % 1.0) for _, w in waves[1:]]
                print(f"  {a:6} {'phase lag':14} vs F{waves[0][0] + 1} (fraction of a period): "
                      + " ".join(f"F{f + 1} {x:.3f}" for (f, _), x in zip(waves[1:], lags)))

if __name__ == "__main__":
    main(sys.argv[1:])
