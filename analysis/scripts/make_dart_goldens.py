#!/usr/bin/env python3
"""Write the reference data the Dart core tests compare against.

  python analysis/scripts/make_dart_goldens.py

Output goes to dled_flutter/test/core_data/:
  shows/<name>.show        sample shows (app-saved / downloaded)
  shows/<name>.saved.show  the same show written by analysis/lpu/showfile.py
  records.json             every cue record of every show, decoded by Python
  frames.json              real VN frames from the captures, parsed by Python

Run it again after changing the Python reference so both stay in step.
"""
import base64
import glob
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "analysis"))
sys.path.insert(0, HERE)

from lpu import protocol, showfile                 # noqa: E402
from emulator_conformance import read_pcapng       # noqa: E402

OUT = os.path.join(ROOT, "dled_flutter", "test", "core_data")
SAMPLES = os.path.join(ROOT, "samples")
SHOWS = {
    "m400": os.path.join(SAMPLES, "m400_12x12_rgb_dim_shut.show"),
    "fx_options": os.path.join(SAMPLES, "show_all_fx_options.show"),
    "playback_menu": os.path.join(SAMPLES, "64fixtures_playback_menu.show"),
    "cue_fx": os.path.join(SAMPLES, "cue_fx_show.show"),
    "app_flags": os.path.join(ROOT, "analysis", "tests", "data", "app_saved_flags.show"),
    "app_channels": os.path.join(ROOT, "analysis", "tests", "data", "app_saved_channels.show"),
    "lpu_download": os.path.join(ROOT, "dled_flutter", "test", "core_data", "shows", "lpu_download.show"),
}
MAX_FRAMES_PER_KEY = 3        # keep frames.json small: a few per (op, type, prop, length)


def record_dict(r):
    return {"fx_intensity": list(r.fx_intensity), "fx_position": list(r.fx_position),
            "fx_colour": list(r.fx_colour), "pan": r.pan, "tilt": r.tilt,
            "intensity": r.intensity, "rgbaw": list(r.rgbaw), "attrs": r.attrs,
            "other": {str(k): v for k, v in r.other.items()}}


def main():
    os.makedirs(os.path.join(OUT, "shows"), exist_ok=True)
    records = {}
    for name, src in SHOWS.items():
        if not os.path.exists(src):
            print("missing, skipped:", src)
            continue
        dst = os.path.join(OUT, "shows", name + ".show")
        if not (os.path.exists(dst) and os.path.samefile(src, dst)):
            shutil.copyfile(src, dst)
        show = showfile.load_show(dst)
        showfile.save_show(show, os.path.join(OUT, "shows", name + ".saved.show"))
        pbs = []
        for p in show.playbacks:
            cues = []
            for c in p.cues:
                recs = {}
                for g in range(64):
                    r = c.record(g)
                    if not r.empty:
                        recs[str(g)] = record_dict(r)
                cues.append({"label": c.label, "fade_ms": c.fade_ms, "delay_ms": c.delay_ms,
                             "follow": c.follow, "records": recs})
            pbs.append({"index": p.index, "label": p.label, "intensity": p.intensity,
                        "speed": p.speed, "gomode": p.gomode, "repeat": p.repeat,
                        "background": p.background, "exclusive": p.exclusive, "cues": cues})
        records[name] = {
            "fixtures": [{"index": f.index, "address": f.address, "manufacturer": f.manufacturer,
                          "model": f.model, "mode": f.mode, "profile": f.profile, "name": f.name,
                          "invert_pan": f.invert_pan, "invert_tilt": f.invert_tilt,
                          "swap_pan_tilt": f.swap_pan_tilt, "virtual_dimmer": f.virtual_dimmer}
                         for f in show.fixtures],
            "playbacks": pbs}
    with open(os.path.join(OUT, "records.json"), "w", encoding="utf-8") as fh:
        json.dump(records, fh, indent=1, sort_keys=True)

    frames, seen = [], {}
    for cap in sorted(glob.glob(os.path.join(SAMPLES, "**", "*.pcapng"), recursive=True)):
        for _, src, sp, dst, dp, pl in read_pcapng(cap):
            if 16945 not in (sp, dp) or len(pl) < 20:
                continue
            p = protocol.parse_frame(pl)
            if p is None:
                continue
            op, typ, prop, i1, i2, i3, mask, seq, body = p
            key = (op, typ, prop, len(body))
            if seen.get(key, 0) >= MAX_FRAMES_PER_KEY:
                continue
            seen[key] = seen.get(key, 0) + 1
            value = protocol.dec_value(typ, body)
            frames.append({"hex": pl.hex(), "op": op, "type": typ, "prop": prop,
                           "i1": i1, "i2": i2, "i3": i3, "mask": mask, "seq": seq,
                           "body": body.hex(),
                           "value": value if isinstance(value, (int, float, str)) else None})
    with open(os.path.join(OUT, "frames.json"), "w", encoding="utf-8") as fh:
        json.dump(frames, fh, indent=1)
    print(f"{len(records)} shows, {len(frames)} frames -> {OUT}")


if __name__ == "__main__":
    main()
