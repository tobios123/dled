#!/usr/bin/env python3
"""Read a .show file and write a human-readable report.

  python show_report.py SHOW [--out report.txt] [--summary] [--personalities FILE]

Fixtures are matched against personalities.xml (default:
dled_flutter/assets/personalities.xml) to name every DMX channel.
"""
import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "analysis"))

from lpu import report, showfile                     # noqa: E402
from lpu.personalities import DEFAULT_PATH, Personalities   # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("show", help=".show file")
    ap.add_argument("--out", help="write the report to this file (default: print)")
    ap.add_argument("--summary", action="store_true", help="omit per-fixture channel values")
    ap.add_argument("--personalities", default=DEFAULT_PATH, help="personalities.xml path")
    a = ap.parse_args()

    show = showfile.load_show(a.show)
    pers = Personalities(a.personalities)
    if not pers.loaded:
        print(f"warning: personalities.xml not found at {a.personalities}", file=sys.stderr)
    text = report.render(show, pers, source=os.path.basename(a.show), details=not a.summary)
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"report written to {a.out} ({len(show.fixtures)} fixtures, "
              f"{len(show.playbacks)} playbacks, {sum(len(p.cues) for p in show.playbacks)} cues)")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
