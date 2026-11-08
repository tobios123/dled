"""Does the LPU keep a completely full show? Writes 64 playbacks x 48 cues x
4 blocks (every fixture in every cue, a value unique per cue / fixture),
then reads a sample back. Replaces the LPU's show: back it up first and put
it back afterwards (lpu-show-download / -upload skills).

  python lpd/probe_full_show.py [--ip 192.168.1.12]

Never more than 48 cues: a cue count above 48 hangs the LPU
(DMX_ENGINE.md 12a).
"""
import argparse
import os
import struct
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "analysis"))
from lpu.protocol import LpuClient, LpuError  # noqa: E402


def block(pb, cue, b):
    out = bytearray(800)
    for r in range(16):
        o = r * 50
        out[o + 16:o + 18] = struct.pack("<H", 0x8000 + pb * 64 + cue)  # intensity: unique per cue
        out[o + 20:o + 22] = struct.pack("<H", 0x100 * (b * 16 + r) + 1)  # red: unique per fixture
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ip", default="192.168.1.12")
    a = ap.parse_args()
    with LpuClient(a.ip) as c:
        t0, failed = time.time(), 0
        for pb in range(64):
            c.write(0x29, 0x01, 0x48, pb, body=struct.pack("<I", 48))
            for cue in range(48):
                for b in range(4):
                    try:
                        c.write(0x2b, 0x0a, 0x47, pb, cue, b, block(pb, cue, b))
                    except LpuError as e:
                        failed += 1
                        if failed <= 5:
                            print(f"  pb{pb + 1} cue{cue + 1} block{b}: {e}")
            print(f"pb{pb + 1} written ({time.time() - t0:.0f} s, {failed} not answered)", flush=True)
        bad = 0
        for pb in (0, 31, 62, 63):
            for cue in (0, 23, 47):
                for b in (0, 3):
                    try:
                        ok = c.read(0x2b, 0x46, pb, cue, b)[1][:800] == block(pb, cue, b)
                    except LpuError:
                        ok = False
                    bad += not ok
                    if not ok:
                        print(f"  pb{pb + 1} cue{cue + 1} block{b}: DIFFERENT or no answer")
        print(f"read back: {24 - bad} of 24 blocks the same; {failed} writes not answered")


if __name__ == "__main__":
    main()
