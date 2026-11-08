"""Compare the notifications the LPD-1 sends with the LPU's, per test step
(the app shows playback state, active cue and programmer values from them).

  python lpd/compare_notes.py NAME [--all]

Takes the newest recording of NAME from lpd/recordings (the LPU) and
lpd/box_recordings (the box); both need "note" lines (lpd_run.dart records
them since 2026-10-28). Per step: the notifications in the order they came,
as "op type prop i1 i2 body", with the time after the step; differences in
content or order are listed, and a time difference over 100 ms. --all
prints every step.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP = ("wait", "snap", "failed")


def newest(folder, name):
    recs = sorted(p for p in glob.glob(os.path.join(HERE, folder, f"{name}_*.jsonl"))
                  if re.fullmatch(re.escape(name) + r"_\d{4}-\d\d-\d\d_[\d-]+\.jsonl", os.path.basename(p)))
    return recs[-1] if recs else None


def steps(path):
    """-> [(step text, [(dt ms, note)])]"""
    out = []
    for line in open(path, encoding="utf-8"):
        o = json.loads(line)
        if "mark" in o and o["mark"] not in SKIP:
            what = o["mark"] + " " + " ".join(f"{k}={v}" for k, v in o.items() if k not in ("t", "mark"))
            out.append((what.strip(), o["t"], []))
        elif "note" in o and out:
            out[-1][2].append((o["t"] - out[-1][1], o["note"]))
    return [(w, n) for w, _, n in out]


def main(args):
    if not args:
        print(__doc__)
        return
    name, show_all = args[0], "--all" in args
    lpu, box = newest("recordings", name), newest("box_recordings", name)
    if not lpu or not box:
        print(f"{name}: needs a recording in lpd/recordings and in lpd/box_recordings")
        return
    ls, bs = steps(lpu), steps(box)
    if not any(n for _, n in ls):
        print(f"{name}: the LPU's recording has no notifications (made before 2026-10-28): run the test on the LPU again")
        return
    same = 0
    for i, ((lw, ln), (bw, bn)) in enumerate(zip(ls, bs)):
        lk, bk = [n for _, n in ln], [n for _, n in bn]
        late = [(n, lt, bt) for (lt, n), (bt, m) in zip(ln, bn) if n == m and abs(lt - bt) > 100]
        if lk == bk and not late:
            same += 1
            if not show_all:
                continue
        print(f"step {i} {lw}")
        if lk != bk:
            print("   LPU: " + ("; ".join(f"+{t:.0f} {n}" for t, n in ln) or "-"))
            print("   box: " + ("; ".join(f"+{t:.0f} {n}" for t, n in bn) or "-"))
        for n, lt, bt in late:
            print(f"   {n}: LPU +{lt:.0f} ms, box +{bt:.0f} ms")
    print(f"{name}: {same} of {min(len(ls), len(bs))} steps the same")


if __name__ == "__main__":
    main(sys.argv[1:])
