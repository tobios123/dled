#!/usr/bin/env python3
"""Run a fake LPU-1 on this PC that the reference app can discover and use.

  python lpu_emulator.py [--show start.show] [--save end.show] [--alias EMU] [--log]

The emulator answers discovery, keeps a show in memory (optionally loaded from
--show), echoes and stores every write, answers every read the app makes, and
sends the LPU's change notifications. Ctrl+C stops it; with --save the final
show (including what the app uploaded or recorded) is written to a .show file.

It needs UDP port 16945. The reference app also listens on 16945, so run the app on
another device (phone/tablet on the same network) or another PC, or give this
PC a second IP address and pass it as --bind (and --ip). For tool tests
on one PC use --port 26945 --bind 127.0.0.1 and pass the same --port to the tools.
No DMX is output and fade/follow timing is not simulated.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from lpu import showfile, simulator          # noqa: E402
from lpu.protocol import VN_PORT             # noqa: E402

try:
    from live_vn_monitor import describe     # decoded log lines, if available
except Exception:                            # pragma: no cover
    describe = None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--show", help="start with this .show loaded")
    ap.add_argument("--save", help="write the final show here on exit")
    ap.add_argument("--alias", default="EMU", help="device alias shown in the app (default EMU)")
    ap.add_argument("--port", type=int, default=VN_PORT)
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on (default all)")
    ap.add_argument("--ip", help="IP to announce (default: this PC's LAN address)")
    ap.add_argument("--log", action="store_true", help="print every frame the app sends")
    ap.add_argument("--logfile", help="also write the output to this file (the terminal "
                    "only keeps its last lines)")
    a = ap.parse_args()

    show = showfile.load_show(a.show) if a.show else None
    logfile = open(a.logfile, "a", encoding="utf-8") if a.logfile else None

    def log(msg):
        print(msg, flush=True)
        if logfile:
            logfile.write(msg + "\n")
            logfile.flush()

    try:
        emu = simulator.run(show=show, bind_ip=a.bind, ip=a.ip, port=a.port, alias=a.alias, log=log)
    except OSError as e:
        # No fallback to binding this PC's LAN address next to the reference app:
        # the emulator then receives every frame meant for the app (from the
        # real LPU and its own replies) and the app gets nothing (tried 2026-10-23).
        sys.exit(f"cannot listen on UDP {a.bind}:{a.port}: {e}\n"
                 "The reference app on this PC probably holds the port. Either:\n"
                 "  - close the PC app and use the reference app on a phone/tablet, or\n"
                 "  - give this PC a second IP address and run with --bind <that IP>.")
    if a.log:
        orig = emu._handle

        def logged(data, addr):
            if data != b"\xff" and describe:
                try:
                    log(f"{time.strftime('%H:%M:%S')} {addr[0]}  {describe(data)[1]}")
                except Exception:
                    pass
            orig(data, addr)
        emu._handle = logged
    s = emu.state
    log(f"LPU emulator '{a.alias}' at {s.ip}:{a.port} - "
        f"{len(s.fixtures)} fixtures, {len(s.playbacks)} playbacks loaded. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        emu.stop()
        if a.save:
            showfile.save_show(emu.state.to_show(), a.save)
            log(f"final show saved to {a.save}")
        if logfile:
            logfile.close()


if __name__ == "__main__":
    main()
