"""Programmer cases (LOAD / changes / RECORD) on an LPU or the LPD-1 (DMX_ENGINE.md 12).

  python lpd/prog_cases.py IP[:PORT] OUT.json [A B ...]

Uploads dled_flutter/test/core_data/shows/m400.show before each case (back
up the show first), runs the case and writes the target cue's records.
"""
import json, os, struct, subprocess, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "analysis"))
from lpu.protocol import LpuClient
IP, OUT = sys.argv[1], sys.argv[2]
PORT = 16945
if ":" in IP: IP, PORT = IP.split(":")[0], int(IP.split(":")[1])
G, CUE, PRG = 0x2c, 0x2b, 0x2d
PB = 4  # playback 5: cue 1 red / yellow fixtures
def upload():
    subprocess.run([sys.executable, ROOT + r"\.claude\skills\lpu-show-upload\scripts\lpu_upload.py",
                    ROOT + r"\dled_flutter\test\core_data\shows\m400.show", "--ip", IP, "--port", str(PORT), "--yes", "--no-backup"],
                   check=True, capture_output=True)
def recs(c, q):
    b = b"".join(bytes(x[1]) for x in c.read_many([(CUE, 0x46, PB, q, k) for k in range(4)]))
    return {i + 1: b[i*50:i*50+50].hex() for i in range(len(b)//50) if any(b[i*50:i*50+50])}
def sel(c, slots): c.write(G, 0x05, 0x3c, body=struct.pack("<Q", sum(1 << (s - 1) for s in slots))); time.sleep(0.3)
def load(c, q): c.write(G, 0x01, 0x3f, body=struct.pack("<I", PB)); c.write(G, 0x1d, 0x36, PB, q); time.sleep(0.5)
def record(c, q): c.write(G, 0x1d, 0x37, PB, q); time.sleep(0.5)
ALL = [1, 2, 3, 4, 5, 9, 10, 11, 12]
cases = {
  "A LOAD c1, RECORD c1": (0, lambda c: (load(c, 0), record(c, 0))),
  "B LOAD c1, RECORD c2 (copy)": (1, lambda c: (load(c, 0), record(c, 1))),
  "C LOAD c1, In 50 %, RECORD c2": (1, lambda c: (load(c, 0), sel(c, ALL), c.write(PRG, 0x03, 0x33, 0, body=struct.pack("<f", 0.5)), time.sleep(0.3), record(c, 1))),
  "D LOAD c1, select 1+2, blue, RECORD c3": (2, lambda c: (load(c, 0), sel(c, [1, 2]),
      c.write(PRG, 0x08, 0x33, 4, body=struct.pack("<5H", 0, 0, 65535, 0, 0)), time.sleep(0.3), record(c, 2))),
  "E LOAD c1, intensity FX sinus, RECORD c1": (0, lambda c: (load(c, 0), sel(c, ALL),
      c.write(PRG, 0x07, 0x33, 1, body=bytes([1, 128, 13, 0])), time.sleep(0.3), record(c, 0))),
  "F LOAD c1, pan 0.5, RECORD c1": (0, lambda c: (load(c, 0), sel(c, ALL),
      c.write(PRG, 0x06, 0x33, 2, body=struct.pack("<2f", 0.5, -0.25)), time.sleep(0.3), record(c, 0))),
  "G CLEAR, select 1+2, RECORD c1": (0, lambda c: (c.write(G, 0x1d, 0x38), time.sleep(0.3), sel(c, [1, 2]), record(c, 0))),
  "H CLEAR, 1+2 In 50 %, then select 3, RECORD c1": (0, lambda c: (c.write(G, 0x1d, 0x38), time.sleep(0.3), sel(c, [1, 2]),
      c.write(PRG, 0x03, 0x33, 0, body=struct.pack("<f", 0.5)), time.sleep(0.3), sel(c, [3]), record(c, 0))),
  "I CLEAR, 1: all others 0.5, pan 0.3 tilt -0.3, RECORD c1": (0, lambda c: (c.write(G, 0x1d, 0x38), time.sleep(0.3), sel(c, [1]),
      [c.write(PRG, 0x03, 0x33, a, body=struct.pack("<f", 0.5)) for a in range(6, 17)],
      c.write(PRG, 0x06, 0x33, 2, body=struct.pack("<2f", 0.3, -0.3)), time.sleep(0.3), record(c, 0))),
  # POSITIONS recall (LpuSession.programmerPositions): select / position per
  # fixture back to back, no pauses, then the selection
  "J CLEAR, 9 pan 0.5 tilt -0.25, 10 pan -0.3 tilt 0.3, select 9+10, RECORD c1": (0, lambda c: (
      c.write(G, 0x01, 0x3f, body=struct.pack("<I", PB)),  # the edited playback: else the LPU drops RECORD
      c.write(G, 0x1d, 0x38), time.sleep(0.3),
      c.write(G, 0x05, 0x3c, body=struct.pack("<Q", 1 << 8)),
      c.write(PRG, 0x06, 0x33, 2, body=struct.pack("<2f", 0.5, -0.25)),
      c.write(G, 0x05, 0x3c, body=struct.pack("<Q", 1 << 9)),
      c.write(PRG, 0x06, 0x33, 2, body=struct.pack("<2f", -0.3, 0.3)),
      c.write(G, 0x05, 0x3c, body=struct.pack("<Q", 1 << 8 | 1 << 9)), time.sleep(0.3), record(c, 0))),
}
ONLY = sys.argv[3:]
if ONLY: cases = {k: v for k, v in cases.items() if k[0] in ONLY}
out = {}
for name, (q, run) in cases.items():
    upload()
    with LpuClient(IP, port=PORT) as c:
        c.write(G, 0x02, 0x35, body=struct.pack("<I", 0))   # EDIT open
        out["orig c%d" % (q + 1)] = recs(c, q)
        run(c)
        out[name] = recs(c, q)
        c.write(G, 0x1d, 0x38)
        c.write(G, 0x02, 0x35, body=struct.pack("<I", 1))
    print("done", name, flush=True)
json.dump(out, open(OUT, "w"), indent=1)
