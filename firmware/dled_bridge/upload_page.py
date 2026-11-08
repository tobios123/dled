"""Send the light page (dled_flutter/light/dist) to a DLED bridge over the network.

  python upload_page.py [IP or host]      (default: dled.local)

Build the page first: `dart run tool/build_light.dart` in dled_flutter.
Each file goes with PUT /api/page/NAME (the box's firmware needs that; see
src/main.cpp). The saved shows in /shows stay, unlike with `pio run -t
uploadfs`, which replaces the whole file system. Reload the page afterwards.
"""
import os, sys, urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "dled.local"
DIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "dled_flutter", "light", "dist")

files = sorted(f for f in os.listdir(DIST) if f.endswith((".gz", ".png")))
if not files:
    sys.exit(f"no page files in {DIST}: build the page first")
# index.html last: until then the old page still finds all its own files
files.sort(key=lambda f: f == "index.html.gz")
for name in files:
    data = open(os.path.join(DIST, name), "rb").read()
    req = urllib.request.Request(f"http://{HOST}/api/page/{name}", data=data, method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            ok = r.status == 200
    except Exception as e:  # noqa: BLE001 - report and stop
        sys.exit(f"{name}: {e}")
    if not ok:
        sys.exit(f"{name}: failed")
    print(f"{name:20} {len(data) / 1024:7.1f} KB")
print(f"{len(files)} files sent to {HOST}; reload the page")
