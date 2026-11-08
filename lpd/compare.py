"""Compare the LPD-1's DMX with the LPU's for the same test.

  python lpd/compare.py [NAME ...]       every test with both recordings

Takes the newest lpd/recordings/NAME_*.jsonl (the LPU) and the newest
lpd/box_recordings/NAME_*.jsonl (the box, `lpd_run.dart NAME --rec-dir
lpd/box_recordings ...`). The steps are matched by their marks; each side's
step time is its first DMX change after the command (as make_replay.py),
so the two reaction delays do not count. Every 25 ms of the box's recording
and every channel: the box's value must lie within the LPU's values (+-1) of
the +-37.5 ms around the same moment. Not compared: fine channels, and what
lpd/replay/NAME.txt masks (random FX, the LPU's lost frames, GOs it ignored;
run make_replay.py first), and the intensity during the first fade of a
playback the LPU remembered a level for (M lines: the LPU's history from
earlier tests, DMX_ENGINE.md 8; the box starts from 0). Prints the score and
the worst steps per test.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_replay import load_recording  # noqa: E402

SKIP = ("wait", "snap", "failed")


def newest(folder, name):
    recs = sorted(p for p in glob.glob(os.path.join(HERE, folder, f"{name}_*.jsonl"))
                  if re.fullmatch(re.escape(name) + r"_\d{4}-\d\d-\d\d_[\d-]+\.jsonl", os.path.basename(p)))
    return recs[-1] if recs else None


def timeline(path):
    """-> (frames [(t, state 512)], steps [(t, op, mark)], failed step indexes)"""
    first, changes, marks, _ = load_recording(path)
    state = list(first["full"]) + [0] * (512 - len(first["full"]))
    frames = [(first["t"], list(state))]
    for t, d in changes:
        for ch, v in d.items():
            state[ch - 1] = v
        frames.append((t, list(state)))
    failed = {i - 1 for i, m in enumerate(marks) if m["mark"] == "failed"}
    steps = []
    for i, m in enumerate(marks):
        if m["mark"] in SKIP:
            continue
        fc = next((tc for tc, _ in changes if m["t"] < tc <= m["t"] + 150), None)
        steps.append((fc - 12.5 if fc is not None else None, m["mark"], m, i in failed))
    return frames, steps


def at(frames, t):
    lo, hi = 0, len(frames) - 1
    if t < frames[0][0]:
        return frames[0][1]
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if frames[mid][0] <= t:
            lo = mid
        else:
            hi = mid - 1
    return frames[lo][1]


def replay_info(name):
    path = os.path.join(HERE, "replay", f"{name}.txt")
    masks, fine = [], set()
    if not os.path.exists(path):
        return masks, fine, False
    intensity, fade, memory, first_go = {}, {}, [], {}
    for line in open(path, encoding="utf-8"):
        p = line.split()
        if not p:
            continue
        if p[0] == "K":
            masks.append((float(p[1]), float(p[2]), int(p[3]), int(p[4])))
        elif p[0] == "F" and p[3] != "-":
            addr, codes = int(p[2]), p[3]
            for i in range(0, len(codes), 2):
                c = int(codes[i:i + 2], 16)
                if 0x20 < c <= 0x33:
                    fine.add(addr + i // 2)
                if c == 0x01:
                    intensity[int(p[1])] = addr + i // 2
        elif p[0] == "C":
            fade.setdefault(int(p[1]), 0)
            fade[int(p[1])] = max(fade[int(p[1])], int(p[3]))
        elif p[0] == "M" and int(p[3]) > 0:
            memory.append((int(p[1]), int(p[2])))
        elif p[0] == "S" and p[2] in ("go", "goDown", "flashDown"):
            first_go.setdefault(int(p[3]), float(p[1]))
    for pb, slot in memory:
        if pb in first_go and slot in intensity:
            t = first_go[pb]
            masks.append((t - 50, t + fade.get(pb, 0) + 500, intensity[slot], intensity[slot]))
    return masks, fine, True


def compare(name):
    lpu_path, box_path = newest("recordings", name), newest("box_recordings", name)
    if not lpu_path or not box_path:
        return None
    lf, ls = timeline(lpu_path)
    bf, bs = timeline(box_path)
    masks, fine, have_replay = replay_info(name)
    if len(ls) != len(bs) or any(a[1] != b[1] for a, b in zip(ls, bs)):
        return f"{name:14s} steps differ ({len(ls)} / {len(bs)}): not compared"
    # step times: the reaction; a step without a reaction on one side takes
    # the mark time + that side's median delay
    def fill(steps):
        lat = sorted(t - m["t"] for t, _, m, _ in steps if t is not None)
        med = lat[len(lat) // 2] if lat else 25
        return [t if t is not None else m["t"] + med for t, _, m, _ in steps]
    lt, bt = fill(ls), fill(bs)
    bad_steps = {}
    compared = matched = 0
    t0, t1 = bf[0][0] + 100, bf[-1][0]
    w = 37.5
    t = t0
    k = -1
    while t <= t1:
        while k + 1 < len(bt) and bt[k + 1] <= t:
            k += 1
        tl = (lt[k] + (t - bt[k])) if k >= 0 else (lf[0][0] + (t - bf[0][0]))
        box = at(bf, t)
        window = [at(lf, tl + d) for d in (-w, -25, -12.5, 0, 12.5, 25, w)]
        failed = k >= 0 and ls[k][3]
        for ch in range(512):
            if ch + 1 in fine or failed:
                continue
            if any(a <= tl <= b and c0 <= ch + 1 <= c1 for a, b, c0, c1 in masks):
                continue
            compared += 1
            vals = [s[ch] for s in window]
            if min(vals) - 1 <= box[ch] <= max(vals) + 1:
                matched += 1
            else:
                e = bad_steps.setdefault(k, [0, None, {}])
                e[0] += 1
                e[2][ch + 1] = e[2].get(ch + 1, 0) + 1
                if e[1] is None:
                    e[1] = f"t {t - bf[0][0]:.0f} ms ch {ch + 1}: box {box[ch]}, LPU {min(vals)}..{max(vals)}"
        t += 25
    score = matched / compared if compared else 1.0
    out = [f"{name:14s} {score:.4f}  ({matched} of {compared}){'' if have_replay else '  (no replay file: no masks)'}"]
    for k, (n, ex, chans) in sorted(bad_steps.items(), key=lambda kv: -kv[1][0])[:4]:
        what = "before the first step" if k < 0 else f"{ls[k][1]} " + " ".join(
            f"{kk}={vv}" for kk, vv in ls[k][2].items() if kk not in ("t", "mark"))
        top = sorted(chans.items(), key=lambda kv: -kv[1])[:6]
        out.append(f"    {n:6d} bad after step {k} {what}; e.g. {ex}; channels " +
                   " ".join(f"{c}({v})" for c, v in top))
    return "\n".join(out)


def main(names):
    if not names:
        names = sorted({re.sub(r"_\d{4}-\d\d-\d\d_.*", "", os.path.basename(p))
                        for p in glob.glob(os.path.join(HERE, "box_recordings", "*.jsonl"))})
    for n in names:
        r = compare(n)
        if r:
            print(r)


if __name__ == "__main__":
    main(sys.argv[1:])
