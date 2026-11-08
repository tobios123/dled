#!/usr/bin/env python3
"""Upload a .show file to an LPU-1, replacing the show on the device.

  python lpu_upload.py SHOW [--ip IP]                 # dry run: check + plan only
  python lpu_upload.py SHOW [--ip IP] --yes           # backup, upload, verify

With --yes it:
  1. downloads the LPU's current show to a backup .show (lpu_backups/ in the
     project, or --backup PATH; --no-backup skips it),
  2. writes the whole show (reset, 64 fixture slots, 64 playback slots, every
     cue's 4 blocks and settings), waiting for the LPU's echo of every frame,
  3. downloads it again and compares with the file (--no-verify skips it).
Exit code 0 = uploaded and verified, 1 = differences found, 2 = dry run.
"""
import argparse
import datetime
import os
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "analysis"))

from lpu import lpu_io, protocol, showfile                 # noqa: E402
from lpu.personalities import split_profile                 # noqa: E402


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


def validate(show):
    """-> (errors, warnings)"""
    errors, warnings = [], []
    for f in show.fixtures:
        n = len(split_profile(f.profile))
        if not 0 <= f.index < 64:
            errors.append(f"fixture index {f.index} outside 0-63")
        if n == 0 or len(f.profile) % 2:
            errors.append(f"fixture {f.index + 1}: bad profile '{f.profile}'")
        if not 1 <= f.address <= 512 or f.address + n - 1 > 512:
            errors.append(f"fixture {f.index + 1}: DMX {f.address}-{f.address + n - 1} outside 1-512")
        if len(f.model) > 29:
            warnings.append(f"fixture {f.index + 1}: model name will be cut to 29 characters by the LPU")
    for p in show.playbacks:
        if not 0 <= p.index < 64:
            errors.append(f"playback index {p.index} outside 0-63")
        if len(p.cues) > 48:
            errors.append(f"playback {p.index + 1}: {len(p.cues)} cues, the app allows 48")
        for q, c in enumerate(p.cues):
            for b, data in enumerate(c.blocks):
                if data and len(data) != showfile.BLOCK_SIZE:
                    errors.append(f"playback {p.index + 1} cue {q + 1} block {b}: {len(data)} bytes")
    return errors, warnings


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("show", help=".show file to upload")
    ap.add_argument("--ip", help="LPU IP address (default: discover)")
    ap.add_argument("--port", type=int, default=protocol.VN_PORT, help="UDP port (emulator tests)")
    ap.add_argument("--yes", action="store_true", help="really upload (otherwise dry run)")
    ap.add_argument("--backup", help="backup path for the LPU's current show")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    show = showfile.load_show(a.show)
    errors, warnings = validate(show)
    n_cues = sum(len(p.cues) for p in show.playbacks)
    print(f"{os.path.basename(a.show)}: {len(show.fixtures)} fixtures, {len(show.playbacks)} playbacks, "
          f"{n_cues} cues")
    for w in warnings:
        print("  warning:", w)
    if errors:
        for e in errors:
            print("  ERROR:", e)
        sys.exit("not uploading: fix the errors above")

    frames = 2 + 64 + 6 * len(show.fixtures) + 64 + 8 * len(show.playbacks) + 8 * n_cues
    if not a.yes:
        print("fixtures:")
        for f in show.fixtures:
            flags = [n for n in ("invert_pan", "invert_tilt", "swap_pan_tilt", "virtual_dimmer")
                     if getattr(f, n)]
            extra = (f'  name "{f.name}"' if f.name else "") + (f"  flags {', '.join(flags)}" if flags else "")
            mode = f" / {f.mode}" if f.mode else ""
            print(f"  {f.index + 1:2d}  DMX {f.address}  {f.manufacturer} / {f.model}{mode}{extra}")
        print("playbacks:")
        for p in show.playbacks:
            print(f"  {p.index + 1:2d}  {p.label or '(no label)'}  {len(p.cues)} cue(s)")
        print(f"cleared on the LPU: {64 - len(show.fixtures)} fixture slots and "
              f"{64 - len(show.playbacks)} playback slots not in this file"
              + (" - THE FILE HAS NO PLAYBACKS, all playbacks will be gone" if not show.playbacks else ""))
        print(f"dry run: would replace the LPU's whole show with this file "
              f"(~{frames} frames, about {frames * 0.03:.0f}s).")
        print("re-run with --yes to back up the current show, upload and verify.")
        sys.exit(2)

    ip = a.ip or find_ip()
    try:
        if not a.no_backup:
            path = a.backup or os.path.join(
                ROOT, "lpu_backups",
                f"lpu_{ip.replace('.', '-')}_{datetime.datetime.now():%Y%m%d_%H%M%S}.show")
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            print("1/3 backing up the LPU's current show ...")
            backup = lpu_io.download(ip, port=a.port, verbose=a.verbose, log=lambda *x: None)
            showfile.save_show(backup, path)
            print(f"    backup: {path} ({len(backup.playbacks)} playbacks, "
                  f"{sum(len(p.cues) for p in backup.playbacks)} cues)")
        t0 = time.time()
        print("2/3 uploading ...")
        lpu_io.upload(ip, show, port=a.port, verbose=a.verbose, log=lambda m: print("   ", m))
        print(f"    done in {time.time() - t0:.1f}s")
        if a.no_verify:
            return
        print("3/3 verifying (reading the show back) ...")
        back = lpu_io.download(ip, port=a.port, verbose=a.verbose, log=lambda *x: None)
    except protocol.LpuError as e:
        sys.exit(f"upload stopped: {e}\nThe LPU may hold a partial show; restore the backup if needed.")
    diffs = lpu_io.compare(show, back)
    if diffs:
        print(f"    {len(diffs)} difference(s):")
        for d in diffs[:40]:
            print("     -", d)
        sys.exit(1)
    print("    verified: the LPU now holds exactly this show")


if __name__ == "__main__":
    main()
