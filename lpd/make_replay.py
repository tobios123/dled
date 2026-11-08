"""Turn LPD tests and their recordings into replay files for the C++ engine's
tests (firmware/lpd1/test): plain text, one item per line, no XML / JSON /
base64, so the C++ side needs only a line reader.

  python lpd/make_replay.py            every test with a recording
  python lpd/make_replay.py NAME ...   only these

Writes lpd/replay/NAME.txt (the newest recording of each test):

  F slot address codes(hex) invertPan invertTilt swap virtualDimmer
  P pb goMode(0 Go 1 Toggle 2 Flash 3 Solo) repeat(0 Loop 1 Bounce 2 Random 3 Off)
    background exclusive intensity speed
  C pb cue fadeMs delayMs follow
  R pb cue slot hex(50 record bytes)                  (records with data only)
  M pb slot level16                 intensity the playback remembers at its first GO
  S tMs op [args]                   a step, at the time the LPU acted on it
  K fromMs toMs fromCh toCh         do not compare there (random FX, lost frames)
  X tMs ch:v ch:v ...               the LPU's DMX: first the full frame, then changes

Step ops: releaseAll | go pb | release pb | intensity pb v | speed pb v |
goDown/goUp/flashDown/flashUp pb | edit 0/1 | select slot... |
progAttr attr level16 | progColour r g b a w | progPos pan16 tilt16 |
progFx gen b0 b1 b2 b3 | progClear | load pb cue
(attr: index in the record order Pan Tilt In Col R G B A W Gobo Rota Sh Iris
Frost Focus Prism Zoom C1 C2.)

The step time: the first DMX change within 150 ms after the command was sent,
minus half a frame; without a change, the command + the median latency.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "analysis"))
from lpu import showfile  # noqa: E402

GO_MODES = ["Go", "Toggle", "Flash", "Solo"]
REPEATS = ["Loop", "Bounce", "Random", "Off"]
ATTRS = ["Pan", "Tilt", "In", "Col", "R", "G", "B", "A", "W", "Go", "Rota", "Sh", "Iris", "Frost",
         "Focus", "Prism", "Zoom", "Custom", "Custom2"]
SLIDER_OTHER = {"Col", "Sh", "Go", "Rota", "Prism", "Focus", "Iris", "Frost", "Zoom", "Custom", "Custom2"}
FX_WAVES = {
    "intensity": {"None": 0, "Sinus": 1, "Ramp": 2, "Inversed Ramp": 3, "Square": 4, "Random": 5},
    "position": {"None": 0, "Circle": 6, "Eight": 7, "Square": 4, "Pan": 8, "Tilt": 9, "Random": 5},
    "colour": {"None": 0, "Rainbow": 10, "Random": 5, "Full Sinus": 11, "Full Twinkle": 12},
}
RANDOM_WAVES = {5, 12}


def fx_bytes(gen, wave, size, speed, phase):
    """As cue_codec.dart fxBytes (+100 % = 127; no recording before 2026-10-28,
    when that was 128, has a programmer FX at +100 %)."""
    wid = FX_WAVES[gen].get(wave, 0)
    p = max(-100, min(100, round(speed)))
    sb = round(p * 1.27) & 0xFF
    return [wid, max(0, min(255, round(size * 2.55))), sb, max(0, min(255, round(phase * 2.55)))]


def load_recording(path):
    first, changes, marks, beats = None, [], [], []
    for line in open(path, encoding="utf-8"):
        o = json.loads(line)
        if "full" in o:
            first = o
        elif "d" in o:
            changes.append((o["t"], {int(k): v for k, v in o["d"].items()}))
        elif "mark" in o:
            marks.append(o)
        elif "beat" in o:
            beats.append((o["t"], o["beat"]))
    return first, changes, marks, beats


def convert(name):
    # NAME_<date>, not NAME_other_<date> (load_* would also match load_when_*)
    recs = sorted(p for p in glob.glob(os.path.join(HERE, "recordings", f"{name}_*.jsonl"))
                  if re.fullmatch(re.escape(name) + r"_\d{4}-\d\d-\d\d_[\d-]+\.jsonl", os.path.basename(p)))
    if not recs:
        return None
    rec = recs[-1]
    show = showfile.load_show(os.path.join(HERE, "tests", f"{name}.show"))
    first, changes, marks, beats = load_recording(rec)
    out = [f"# lpd replay: {name} from {os.path.basename(rec)}"]
    fixtures = {}
    for f in show.fixtures:
        codes = f.profile.upper()
        # the LPU ends a profile at code 00 (DMX_ENGINE.md 14)
        for i in range(0, len(codes), 2):
            if codes[i:i + 2] == "00":
                codes = codes[:i]
                break
        fixtures[f.index] = (f.address, codes)
        out.append(f"F {f.index} {f.address} {codes or '-'} {int(f.invert_pan)} {int(f.invert_tilt)} "
                   f"{int(f.swap_pan_tilt)} {int(f.virtual_dimmer)}")
    pbs = {p.index: p for p in show.playbacks}
    for p in show.playbacks:
        out.append(f"P {p.index} {GO_MODES.index(p.gomode)} {REPEATS.index(p.repeat)} {int(p.background)} "
                   f"{int(p.exclusive)} {p.intensity:g} {p.speed:g}")
        for c, cue in enumerate(p.cues):
            out.append(f"C {p.index} {c} {cue.fade_ms} {cue.delay_ms} {int(cue.follow)}")
            for slot in range(64):
                raw = cue.record(slot).raw
                if any(raw):
                    out.append(f"R {p.index} {c} {slot} {raw.hex()}")

    # step times: the LPU's reaction
    def first_change(t, within=150):
        for tc, _ in changes:
            if t < tc <= t + within:
                return tc
            if tc > t + within:
                return None
        return None

    lat = sorted(fc - m["t"] for m in marks if m["mark"] not in ("wait", "snap", "failed")
                 for fc in [first_change(m["t"])] if fc is not None)
    median = lat[len(lat) // 2] if lat else 40
    steps = []
    failed = {i - 1 for i, m in enumerate(marks) if m["mark"] == "failed"}  # the LPU did not answer
    for i, m in enumerate(marks):
        op = m["mark"]
        if op in ("wait", "snap", "failed") or i in failed:
            continue
        fc = first_change(m["t"])
        t = fc - 12.5 if fc is not None else m["t"] + median
        steps.append((t, op, m))

    # state of the DMX at time t (for the intensity memory)
    def dmx_at(t):
        state = list(first["full"]) + [0] * 512
        for tc, d in changes:
            if tc > t:
                break
            for ch, v in d.items():
                state[ch - 1] = v
        return state

    seen = set()
    for t, op, m in steps:
        if op not in ("go", "goDown", "flashDown") or m["pb"] in seen:
            continue
        seen.add(m["pb"])
        p = pbs.get(m["pb"])
        if not p or not p.cues or p.cues[0].fade_ms == 0:
            continue
        state = dmx_at(t + 25)
        for slot in range(64):
            if not any(p.cues[0].record(slot).raw) or slot not in fixtures:
                continue
            addr, codes = fixtures[slot]
            cl = [codes[i:i + 2] for i in range(0, len(codes), 2)]
            if "01" not in cl:
                continue
            v = state[addr - 1 + cl.index("01")] << 8
            if "21" in cl:
                v |= state[addr - 1 + cl.index("21")]
            else:
                v |= v >> 8
            out.append(f"M {m['pb']} {slot} {v}")

    for t, op, m in steps:
        pb = m.get("pb")
        if op in ("releaseAll", "progClear"):
            out.append(f"S {t:.1f} {op}")
        elif op in ("go", "release", "goDown", "goUp", "flashDown", "flashUp"):
            out.append(f"S {t:.1f} {op} {pb}")
        elif op in ("intensity", "speed"):
            out.append(f"S {t:.1f} {op} {pb} {m['value']}")
        elif op == "edit":
            out.append(f"S {t:.1f} edit {int(m['value'])}")
        elif op == "select":
            out.append(f"S {t:.1f} select {' '.join(str(s) for s in m['slots'])}")
        elif op == "load":
            out.append(f"S {t:.1f} load {pb} {m['cue']}")
        elif op == "prog":
            v = m["values"]
            if "In" in v:
                out.append(f"S {t:.1f} progAttr {ATTRS.index('In')} {round(v['In'] / 255 * 65535)}")
            if "Pan" in v or "Tilt" in v:
                pos = [max(-1, min(1, (v.get(k, 127.5) - 127.5) / 127.5)) for k in ("Pan", "Tilt")]
                out.append(f"S {t:.1f} progPos " + " ".join(str(round(32767 + x * 32767)) for x in pos))
            if any(k in v for k in "RGBAW"):
                out.append(f"S {t:.1f} progColour " + " ".join(str(round(v.get(k, 0) / 255 * 65535)) for k in "RGBAW"))
            for k in v:
                if k in SLIDER_OTHER:
                    out.append(f"S {t:.1f} progAttr {ATTRS.index(k)} {round(v[k] / 255 * 65535)}")
        elif op == "progFx":
            gen, wave, size, speed, phase = m["fx"]
            g = ["intensity", "position", "colour"].index(gen)
            out.append(f"S {t:.1f} progFx {g} " + " ".join(map(str, fx_bytes(gen, wave, size, speed, phase))))
        else:
            out.append(f"# unknown step {op}")

    # masks: lost frames (a second with < 36 frames) and random FX / Random repeat
    for tb, n in beats:
        if n < 36:
            out.append(f"K {tb - 1050:.0f} {tb + 50:.0f} 1 512")
    end = changes[-1][0] + 1000 if changes else 0
    active = {}
    for t, op, m in steps + [(end, "end", {})]:
        pb = m.get("pb")
        if op == "go" and pb in pbs and pb not in active:
            active[pb] = t
        if (op in ("release", "releaseAll", "end") and (pb in active or op != "release")):
            for p_ in ([pb] if op == "release" else list(active)):
                t0 = active.pop(p_, None)
                if t0 is None:
                    continue
                p = pbs[p_]
                rnd_slots = set()
                for cue in p.cues:
                    for slot in range(64):
                        raw = cue.record(slot).raw
                        if p.repeat == "Random" and any(raw):
                            rnd_slots.add(slot)
                        if raw[0] in RANDOM_WAVES or raw[4] in RANDOM_WAVES or raw[8] in RANDOM_WAVES:
                            rnd_slots.add(slot)
                fade = max(c.fade_ms for c in p.cues) if p.cues else 0
                for slot in sorted(rnd_slots):
                    if slot in fixtures:
                        addr, codes = fixtures[slot]
                        out.append(f"K {t0 - 50:.0f} {t + fade + 500:.0f} {addr} {addr + len(codes) // 2 - 1}")

    # a GO the LPU ignored (no change at all within a second; seen right after
    # an upload, playbacks "releasing"): not comparable until that playback's
    # release
    for i, (t, op, m) in enumerate(steps):
        if op not in ("go", "goDown", "flashDown"):
            continue
        if any(t < tc <= t + 1000 for tc, _ in changes):
            continue
        end_t = next((t2 for t2, op2, m2 in steps[i + 1:]
                      if op2 == "releaseAll" or (op2 == "release" and m2.get("pb") == m["pb"])), t + 1000)
        fade = max((c.fade_ms for c in pbs[m["pb"]].cues), default=0) if m["pb"] in pbs else 0
        out.append(f"K {t - 50:.0f} {end_t + fade + 500:.0f} 1 512")

    full = first["full"]
    out.append(f"X {first['t']:.1f} " + " ".join(f"{i + 1}:{v}" for i, v in enumerate(full)))
    for t, d in changes:
        out.append(f"X {t:.1f} " + " ".join(f"{ch}:{v}" for ch, v in sorted(d.items())))
    return "\n".join(out) + "\n"


def main(names):
    if not names:
        names = sorted({re.sub(r"_\d{4}-\d\d-\d\d_.*", "", os.path.basename(p))
                        for p in glob.glob(os.path.join(HERE, "recordings", "*.jsonl"))})
    os.makedirs(os.path.join(HERE, "replay"), exist_ok=True)
    for n in names:
        if not os.path.exists(os.path.join(HERE, "tests", f"{n}.show")):
            continue
        text = convert(n)
        if text is None:
            continue
        with open(os.path.join(HERE, "replay", f"{n}.txt"), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"{n}: {text.count(chr(10))} lines")


if __name__ == "__main__":
    main(sys.argv[1:])
