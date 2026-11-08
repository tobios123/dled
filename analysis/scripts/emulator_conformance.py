#!/usr/bin/env python3
"""Replay the reference app's frames from captures into the LPU emulator and
check that it answers every request the way the real LPU did.

  python emulator_conformance.py CAPTURE.pcapng [...] [--app-ip 192.168.1.171]

For every app -> LPU frame in the capture:
  * writes / actions:  the emulator must echo the frame byte for byte
  * reads (type 1d):   the emulator must answer with a non-echo reply of the
                       same object/property/indexes, like the real LPU did
                       (reads the real LPU only echoed are accepted as echo)
  * short 9-byte reads: the emulator must answer [00, prop, .., len, value]
Value differences are expected (the emulator holds its own show) and are only
counted, not failed, except for the reply's value type.
Exit code 1 if any frame got no answer or a wrong kind of answer.

  --target HOST:PORT   test another server there instead of the Python
                       emulator (the LPD-1's PC build: firmware/lpd1, env pc)
"""
import argparse
import os
import socket
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from lpu import simulator                       # noqa: E402
from lpu.protocol import parse_frame            # noqa: E402

try:
    from pcap import udp_packets                # analysis/scripts/pcap.py if present
except ImportError:
    udp_packets = None


def read_pcapng(path):
    """Minimal pcapng reader -> (ts, src, sport, dst, dport, payload)."""
    import struct
    data = open(path, "rb").read()
    off, endian, ifaces = 0, "<", []
    while off + 12 <= len(data):
        btype = struct.unpack_from(endian + "I", data, off)[0]
        if btype == 0x0A0D0D0A:
            endian = "<" if data[off + 8:off + 12] == b"\x4d\x3c\x2b\x1a" else ">"
            ifaces = []
        blen = struct.unpack_from(endian + "I", data, off + 4)[0]
        if blen < 12:
            break
        body = data[off + 8:off + blen - 4]
        if btype == 1:
            ifaces.append(struct.unpack_from(endian + "H", body, 0)[0])
        elif btype == 6:
            ifid, th, tl, cap, _ = struct.unpack_from(endian + "IIIII", body, 0)
            pkt = body[20:20 + cap]
            link = ifaces[ifid] if ifid < len(ifaces) else 1
            if link == 1 and len(pkt) > 14 and pkt[12:14] == b"\x08\x00":
                ip = pkt[14:]
                if len(ip) >= 20 and ip[9] == 17 and not struct.unpack_from(">H", ip, 6)[0] & 0x1FFF:
                    ihl = (ip[0] & 15) * 4
                    tot = struct.unpack_from(">H", ip, 2)[0]
                    udp = ip[ihl:tot]
                    sp, dp, ul = struct.unpack_from(">HHH", udp, 0)
                    yield (((th << 32) | tl) / 1e6, ".".join(map(str, ip[12:16])), sp,
                           ".".join(map(str, ip[16:20])), dp, bytes(udp[8:ul]))
        off += blen


def lpu_answers(cap, app_ip):
    """What the real LPU answered: request frame -> 'echo' | 'reply' | None."""
    pending = {}
    seen = {}
    for ts, src, sp, dst, dp, pl in read_pcapng(cap):
        if 16945 not in (sp, dp) or len(pl) < 20:
            continue
        p = parse_frame(pl)
        if p is None:
            continue
        key = (p[0], p[2], p[3], p[4], p[5])
        if src == app_ip and p[1] == 0x1d:
            pending[key] = pl
            seen.setdefault(key, None)
        elif src != app_ip and key in pending and not p[1] & 0x80:
            seen[key] = "echo" if pl == pending[key] else ("reply", p[1])
    return seen


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("captures", nargs="+")
    ap.add_argument("--app-ip", default="192.168.1.171")
    ap.add_argument("--port", type=int, default=26999)
    ap.add_argument("--show", help="load this .show into the emulator first")
    ap.add_argument("--target", help="HOST:PORT of another server to test (no emulator is started)")
    a = ap.parse_args()

    show = None
    if a.show:
        from lpu import showfile
        show = showfile.load_show(a.show)
    bad_total = 0
    for cap in a.captures:
        if a.target:
            host, port = a.target.rsplit(":", 1)
            dest, emu = (host, int(port)), None
        else:
            dest = ("127.0.0.1", a.port)
            emu = simulator.run(show=show, bind_ip="127.0.0.1", port=a.port, log=lambda *x: None)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        real = lpu_answers(cap, a.app_ip)
        stats = Counter()
        problems = defaultdict(int)
        examples = {}

        def recv_until(pred, timeout=0.25):
            end = time.time() + timeout
            while time.time() < end:
                s.settimeout(max(0.01, end - time.time()))
                try:
                    d, _ = s.recvfrom(4096)
                except socket.timeout:
                    return None
                if pred(d):
                    return d
            return None

        for ts, src, sp, dst, dp, pl in read_pcapng(cap):
            if src != a.app_ip or dp != 16945 or pl == b"\xff" or pl.startswith(b"visual"):
                continue
            s.sendto(pl, dest)
            if len(pl) < 20:                                     # short device property
                if len(pl) == 9:
                    d = recv_until(lambda d: len(d) > 9 and d[:2] == pl[:2])
                    stats["short read ok" if d else "short read MISSING"] += 1
                    if not d:
                        problems[f"short 0x{pl[1]:02x}"] += 1
                continue
            p = parse_frame(pl)
            if p is None:
                continue
            op, typ, prop, i1, i2, i3 = p[0], p[1], p[2], p[3], p[4], p[5]
            key = (op, prop, i1, i2, i3)
            if typ != 0x1d or real.get(key) == "echo" or prop == 0x38:
                d = recv_until(lambda d: d == pl)
                stats["echo ok" if d else "echo MISSING"] += 1
                if not d:
                    problems[f"no echo {op:02x} {typ:02x} {prop:02x}"] += 1
                continue
            d = recv_until(lambda d: (parse_frame(d) or (None,))[0] == op and d != pl and len(d) >= 20
                           and parse_frame(d)[2] == prop and parse_frame(d)[3:6] == (i1, i2, i3)
                           and not parse_frame(d)[1] & 0x80)
            if d is None and key in real and real[key] is None:
                stats["no answer, like the real LPU"] += 1    # e.g. 3d 1d 4a
            elif d is None:
                stats["read UNANSWERED"] += 1
                problems[f"read {op:02x} 1d {prop:02x} (real LPU: {real.get(key)})"] += 1
                examples.setdefault(f"read {op:02x} 1d {prop:02x}", pl[:20].hex(" "))
            else:
                want = real.get(key)
                got = parse_frame(d)[1]
                if isinstance(want, tuple) and want[1] != got:
                    stats["read WRONG TYPE"] += 1
                    problems[f"read {op:02x} 1d {prop:02x}: type {got:02x}, real LPU {want[1]:02x}"] += 1
                else:
                    stats["read answered"] += 1
        if emu:
            emu.stop()
        s.close()
        time.sleep(0.2)
        bad = sum(v for k, v in stats.items() if "MISSING" in k or "UNANSWERED" in k or "WRONG" in k)
        bad_total += bad
        print(f"{os.path.basename(cap)}: " + ", ".join(f"{k} {v}" for k, v in sorted(stats.items())))
        for k, v in sorted(problems.items()):
            print(f"    {v:4d} x {k}" + (f"   e.g. {examples[k]}" if k in examples else ""))
    sys.exit(1 if bad_total else 0)


if __name__ == "__main__":
    main()
