"""Print the snaps of an LPD report as one line per snap:
  python lpd/snaps.py NAME [CH,CH,...]     (the newest lpd/recordings/NAME_*.txt)
Channels default to all fixture channels in the report."""
import glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
name = sys.argv[1]
f = name if name.endswith(".txt") else sorted(glob.glob(os.path.join(HERE, "recordings", f"{name}_*.txt")))[-1]
want = [int(c) for c in sys.argv[2].split(",")] if len(sys.argv) > 2 else None
lines = open(f, encoding="utf-8").read().splitlines()
hdr = next(l for l in lines if l.strip().startswith("ch  code"))
start = hdr.index("cue") + 5
# the snap names from the test's steps (the report pads them to 10 columns)
import json
test = re.sub(r"_\d{4}-\d\d-\d\d_.*", "", os.path.basename(f))
names = [s["name"] for s in json.load(open(os.path.join(HERE, "tests", f"{test}.steps.json")))["steps"]
         if s["op"] == "snap"]
rows = {}
for l in lines:
    m = re.match(r"\s*(\d+)\s+([0-9a-f]{2})\s+(.{16})", l)
    if m and l.strip() != hdr.strip():
        rows[int(m.group(1))] = (m.group(3).strip(), l[start + 2:].split())
chs = want or sorted(rows)
print("snap".ljust(18) + " ".join(f"{c}:{rows[c][0][:6]}".rjust(10) for c in chs))
for k, n in enumerate(names):
    print(n.ljust(18) + " ".join(rows[c][1][k].rjust(10) for c in chs))
