#!/usr/bin/env python3
"""Download the complete show from an LPU-1 into a .show file and/or a text report.

  python lpu_download.py [--ip IP] [--show out.show] [--txt out.txt] [--port 16945]

Without --ip the LPU is found by broadcast discovery. At least one of --show /
--txt is required. The download only reads (it never changes the LPU) and only
asks for slots, cues and blocks the LPU itself reports, so it is safe while a
show is running.

The .show file can be opened by the reference app. Fixture names and patch
flags (invert pan/tilt, swap, virtual dimmer) and the device settings (alias,
Art-Net, sACN) are not part of the .show format; they appear in the report.
"""
import argparse
import os
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "analysis"))

from lpu import lpu_io, protocol, report, showfile          # noqa: E402
from lpu.personalities import DEFAULT_PATH, Personalities   # noqa: E402


def find_ip():
    found = protocol.discover()
    if not found:
        sys.exit("no LPU found by discovery - pass --ip")
    if len(found) > 1:
        for ip, label, ver in found:
            print(f"  {ip}  {label}  firmware {ver}")
        sys.exit("several LPUs found - pass --ip")
    ip, label, ver = found[0]
    print(f"found {label} at {ip} (firmware {ver})")
    return ip


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--ip", help="LPU IP address (default: discover)")
    ap.add_argument("--port", type=int, default=protocol.VN_PORT, help="UDP port (emulator tests)")
    ap.add_argument("--show", help="write a .show file")
    ap.add_argument("--txt", help="write a readable text report")
    ap.add_argument("--summary", action="store_true", help="report without per-fixture values")
    ap.add_argument("--personalities", default=DEFAULT_PATH)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    if not (a.show or a.txt):
        ap.error("give --show and/or --txt")

    ip = a.ip or find_ip()
    t0 = time.time()
    try:
        show = lpu_io.download(ip, port=a.port, verbose=a.verbose)
    except protocol.LpuError as e:
        sys.exit(f"download failed: {e}\n(is the LPU on, reachable, and is the port right?)")
    show.host = {"os": "Windows", "ips": []}
    n_cues = sum(len(p.cues) for p in show.playbacks)
    print(f"downloaded in {time.time() - t0:.1f}s: {len(show.fixtures)} fixtures, "
          f"{len(show.playbacks)} playbacks, {n_cues} cues")
    for path in (a.show, a.txt):
        if path:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    if a.show:
        showfile.save_show(show, a.show)
        print(f"show written to {a.show}")
    if a.txt:
        text = report.render(show, Personalities(a.personalities),
                             source=f"downloaded from LPU {ip}", details=not a.summary)
        with open(a.txt, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"report written to {a.txt}")


if __name__ == "__main__":
    main()
