#!/usr/bin/env python3
"""
live_vn_monitor.py -- live decoder for app <-> LPU VN traffic (UDP 16945)

Runs tshark (Wireshark's command-line capture) and prints every frame between
this PC and the LPU decoded by name, so you can click buttons in the reference app
and see exactly which property and value each click sends.

Protocol reference: dled_flutter/VN_PROTOCOL.md (sections 12, typed frames).
Playback/cue numbers are printed 1-based, like the reference app.

Usage:
  python live_vn_monitor.py                         # live, Wi-Fi, LPU 192.168.1.12
  python live_vn_monitor.py --iface Ethernet
  python live_vn_monitor.py --list                  # list capture interfaces
  python live_vn_monitor.py --all                   # also repeated replies + reads
  python live_vn_monitor.py --pcap file.pcapng      # decode a saved capture
  python live_vn_monitor.py --log toggles.txt       # also write output to a file

Needs Wireshark (with Npcap) installed; the reference app must run on this PC (or
the traffic must otherwise reach this PC's adapter).
"""

import argparse
import datetime
import os
import shutil
import struct
import subprocess
import sys

VN_PORT = 16945
DEFAULT_LPU_IP = "192.168.1.12"
TSHARK_CANDIDATES = [
    r"C:\Program Files\Wireshark\tshark.exe",
    r"C:\Program Files (x86)\Wireshark\tshark.exe",
]

# --------------------------------------------------------------------------
# Name tables.  Key = (object op byte, property id).  Read and write ids of a
# property are usually adjacent (write = read + 1); both are listed.
# --------------------------------------------------------------------------

OBJECTS = {0x02: "device", 0x0a: "artnet", 0x0b: "sacn",
           0x1f: "fixture", 0x28: "action", 0x29: "playback", 0x2b: "cue",
           0x2c: "global", 0x2d: "prog"}

# No-body (type 0x1d) frames that are commands, not reads: always shown.
# 28 1d 49 = playback "Swap" button (2026-10-22, swapped pb7 <-> pb15);
# its raw indexes are printed so the second playback's position can be found.
# 28 1d 42 = RELEASE ALL button; 29 1d 42 = release one playback (2026-10-22).
# 2c 1d 36 = load cue into the programmer, 2c 1d 37 = record cue (edit window,
# 2026-10-22).
# 29 1d 04 = delete cue (2026-10-22; which index holds the cue is not proven).
ACTIONS = {(0x28, 0x49), (0x28, 0x42), (0x29, 0x42), (0x2c, 0x36), (0x2c, 0x37),
           (0x29, 0x04)}

GO_MODES     = {0: "Go", 1: "Toggle", 2: "Flash", 3: "Solo"}
REPEAT_MODES = {0: "Loop", 1: "Bounce", 2: "Random", 3: "Off"}
CONDITIONS   = {0: "Halt", 1: "Follow"}

# Programmer attributes (2c ..32 / 2d ..33, index 1): each value is followed by
# its FX generator. FX = 4 bytes [waveform, size, speed, phase], confirmed live
# 2026-10-22 (pb4 'Twinkle' attr 5 = 0c ff 2a 84 = Full Twinkle, etc.).
ATTR_NAMES = {0: "intensity", 1: "intensity FX", 2: "position",
              3: "position FX", 4: "colour", 5: "colour FX"}
# Attr 6-16 are 11 plain floats. Their index order is NOT the edit window's
# fader order (shutter col go rota prism iris focus zoom frost custom1 custom2):
# checked fader by fader live on 2026-10-23, shutter/colour wheel, iris/focus
# and zoom/frost are swapped. Colour (attr 4) holds r g b a w as 5 x u16.
ATTR_NAMES.update({6 + i: n for i, n in enumerate(
    ["colour wheel", "shutter", "gobo", "gobo rot", "prism", "focus",
     "iris", "frost", "zoom", "custom1", "custom2"])})


def fx_speed_pct(b: int) -> int:
    """FX speed byte -> UI % (-100..100). Signed int8, ~1.27 per %, 0 = stopped.
    The app sends +100 as 128 (wraps); -100 = 129, -1 = 255 (user-verified)."""
    if b == 128:
        return 100
    s = b - 256 if b > 128 else b
    return round(s / 1.27)
FX_WAVES = {
    1: {0: "None", 1: "Sine", 2: "Ramp", 3: "Inversed Ramp", 4: "Square", 5: "Random"},
    3: {0: "None", 4: "Square", 5: "Random", 6: "Circle", 7: "Eight", 8: "Pan", 9: "Tilt"},
    5: {0: "None", 5: "Random", 10: "Rainbow", 11: "Full Sines", 12: "Full Twinkle"},
}
# 29 81 24: 2 while a fade or follow-delay timer runs, 3 when the cue holds
# (Halt, nothing pending), 4 during the release fade, then 1. Confirmed live on
# 2026-10-22: phase 2 lasted exactly the cue time (20.0 s / 6.0 s / 1.0 s), and
# phase 4 lasted the 1.0 s release fade.
CUE_PHASES   = {0: "no cues", 1: "idle", 2: "running (fade/delay timer)",
                3: "holding", 4: "releasing"}

PROPS = {
    # fixture
    (0x1f, 0x05): "name",
    (0x1f, 0x06): "name",
    # patch screen flags (bool), confirmed by the user 2026-10-22
    (0x1f, 0x0d): "invert pan",
    (0x1f, 0x0e): "invert pan",
    (0x1f, 0x0f): "invert tilt",
    (0x1f, 0x10): "invert tilt",
    (0x1f, 0x11): "swap pan/tilt",
    (0x1f, 0x12): "swap pan/tilt",
    (0x1f, 0x13): "virtual dimmer",
    (0x1f, 0x14): "virtual dimmer",
    (0x1f, 0x07): "definition",
    (0x1f, 0x08): "definition",
    (0x1f, 0x0b): "DMX address",
    (0x1f, 0x0c): "DMX address",
    (0x1f, 0x38): "DELETE",
    # u32: high u16 = DMX address; low bits 0 invert pan, 1 invert tilt,
    # 2 swap pan/tilt (only on fixtures with pan/tilt). Confirmed 2026-10-22.
    (0x1f, 0x30): "fixture state",
    (0x28, 0x4f): "prop 0x4f (startup)",
    # playback
    (0x29, 0x03): "INSERT cue at",
    (0x29, 0x04): "DELETE cue",
    (0x29, 0x05): "label",
    (0x29, 0x06): "label",
    (0x29, 0x15): "speed",
    (0x29, 0x16): "speed",
    (0x29, 0x17): "intensity",
    (0x29, 0x18): "intensity",
    (0x29, 0x1d): "background",
    (0x29, 0x1e): "background",
    (0x29, 0x20): "go mode",
    (0x29, 0x21): "go mode",
    (0x29, 0x22): "GO button",
    (0x29, 0x23): "FLASH button",
    (0x29, 0x24): "cue phase",
    (0x29, 0x2d): "repeat",
    (0x29, 0x2e): "repeat",
    (0x29, 0x2f): "active cue",
    (0x29, 0x30): "state",
    (0x29, 0x38): "DELETE",
    (0x29, 0x39): "exclusive",
    (0x29, 0x3a): "exclusive",
    (0x29, 0x3d): "cue count",
    (0x29, 0x42): "RELEASE",
    (0x29, 0x48): "cue count",
    (0x29, 0x50): "active",
    # cue
    (0x2b, 0x05): "label",
    (0x2b, 0x06): "label",
    (0x2b, 0x27): "condition",
    (0x2b, 0x28): "condition",
    (0x2b, 0x29): "fade ms",
    (0x2b, 0x2a): "fade ms",
    (0x2b, 0x2b): "delay ms",
    (0x2b, 0x2c): "delay ms",
    (0x2b, 0x46): "page",
    (0x2b, 0x47): "page",
    # global (edit window / programmer)
    (0x2c, 0x32): "programmer value",
    (0x2c, 0x36): "LOAD cue",
    (0x2c, 0x37): "RECORD cue",
    (0x2c, 0x34): "choose-pb mode",
    (0x2c, 0x35): "choose-pb mode",
    (0x2c, 0x3e): "edit playback",
    (0x2c, 0x3f): "edit playback",
    (0x2c, 0x3b): "fixture selection",
    (0x2c, 0x3c): "fixture selection",
    (0x2c, 0x45): "programmer has data",
    (0x2c, 0x38): "RESET",
    # programmer attribute slider in the edit window; index 1 = attribute
    # number, same numbering as 2c ..32 (0 intensity float, 4 colour 5 x u16)
    (0x2d, 0x32): "attr value",
    (0x2d, 0x33): "attr value",
    # options page (2026-10-22): Art-Net = object 0x0a, sACN = object 0x0b
    (0x0a, 0x25): "enabled",
    (0x0a, 0x26): "enabled",
    (0x0a, 0x32): "universe",
    (0x0a, 0x33): "universe",
    (0x0b, 0x25): "enabled",
    (0x0b, 0x26): "enabled",
    (0x0b, 0x32): "universe",
    (0x0b, 0x33): "universe",
    # actions
    (0x28, 0x49): "SWAP playbacks",
    (0x28, 0x42): "RELEASE ALL",
}

# Short-form device properties (9-byte frames), matched against the .show
# <device> block and the options page on 2026-10-22.
SHORT_PROPS = {
    0x00: "MAC address",
    0x03: "subnet mask",
    0x09: "firmware",
    0x0a: "PCB version",
    0x11: "alias",
    0x12: "alias",
    0x34: "Art-Net universe (UIx16)",
    0xce: "Art-Net enabled",
    0xef: "sACN enabled",
    0xf0: "sACN universe",
}

ENUMS = {
    "go mode": GO_MODES,
    "repeat": REPEAT_MODES,
    "condition": CONDITIONS,
    "cue phase": CUE_PHASES,
}

# Value type = byte[1]. The LPU's change notifications use the same codes with
# bit 7 set (0x80 str, 0x81 u32, 0x82 bool, 0x83 float).
TYPE_NAMES = {0x00: "str", 0x01: "u32", 0x02: "bool", 0x03: "float",
              0x05: "blob", 0x0a: "page", 0x1d: "no body"}
NOTIFY_BIT = 0x80

# Reads the app repeats in its idle loop; hidden unless --all.
IDLE_READS = {(0x29, 0x05), (0x29, 0x15), (0x29, 0x17), (0x29, 0x30)}


def decode_state(body: bytes) -> str:
    """Playback property 0x30: [go<<4|excl<<1|bg, repeat<<4|state, cues, active]."""
    if len(body) < 4:
        return body.hex(" ")
    b0, b1, cues, active = body[:4]
    if not b1 & 0x0f:
        act = "empty"
    else:
        act = "released" if active == 0xff else f"RUNNING cue {active + 1}"
    return (f"go={GO_MODES.get(b0 >> 4, b0 >> 4)} repeat={REPEAT_MODES.get(b1 >> 4, b1 >> 4)} "
            f"background={b0 & 1} exclusive={(b0 >> 1) & 1} state={b1 & 0x0f} "
            f"cues={cues} {act}")


def decode_value(op: int, typ: int, prop: int, body: bytes, name: str,
                 attr: int = -1) -> str:
    if typ == 0x1d:
        if prop == 0x38 or (op, prop) in ACTIONS:
            return ""
        return "(request, no body)"
    typ &= ~NOTIFY_BIT & 0xff          # notifications: same value types
    if prop == 0x30 and op == 0x29 and len(body) >= 4:
        return decode_state(body)
    if typ == 0x00:
        s = body.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        return repr(s)
    if typ == 0x0a or len(body) == 800:
        nz = sum(1 for b in body if b)
        return f"800 bytes, {nz} non-zero"
    if typ == 0x05:
        if name == "fixture selection" and len(body) >= 8:
            mask = int.from_bytes(body[:8], "little")
            sel = [str(i + 1) for i in range(64) if mask >> i & 1]
            return f"fixtures {','.join(sel) or 'none'}   ({body.hex(' ')})"
        return body.hex(" ")
    if typ == 0x08 and len(body) >= 10:
        # programmer attr 4 = colour, five u16. The edit window's four single-
        # colour sliders drive #1, #2, #3 and #5 in slider order; #1-#3 follow
        # R,G,B of the loaded cue; #4 stayed 0 (2026-10-22).
        vals = struct.unpack_from("<5H", body)
        return " ".join(f"{n}={v:04x}" for n, v in zip("RGBAW", vals))
    if typ == 0x07 and len(body) >= 4 and attr in FX_WAVES:
        wave, size, speed, phase = body[:4]
        return (f"{FX_WAVES[attr].get(wave, f'wave {wave}')}  "
                f"size={size / 2.55:.0f}% speed={fx_speed_pct(speed)}% "
                f"phase={phase / 2.55:.0f}%   ({body[:4].hex(' ')})")
    if typ == 0x06 and len(body) >= 8 and attr == 2:
        pan, tilt = struct.unpack_from("<2f", body)     # each -1.0 .. +1.0
        return f"pan={pan:+.3f} tilt={tilt:+.3f}   ({body[:8].hex(' ')})"
    if typ not in (0x00, 0x01, 0x02, 0x03):
        return f"raw {body.hex(' ')}"      # value type not decoded yet
    if len(body) < 4:
        return body.hex(" ") if body else ""
    u = struct.unpack_from("<I", body)[0]
    if typ == 0x03:
        f = struct.unpack_from("<f", body)[0]
        if name == "intensity":
            return f"{f:.4g} ({f * 100:.0f}%)"
        if f != 0 and abs(f) < 1e-30:
            return f"raw {body[:4].hex(' ')} (u32 {u})"   # not really a float
        return f"{f:.4g}"
    if name == "INSERT cue at":
        return "end (-1)" if u == 0xffffffff else f"cue {u + 1}"
    if name in ENUMS:
        return f"{ENUMS[name].get(u, '?')} ({u})"
    if name == "changed":
        return f"code 0x{u:x}"
    if name == "enabled":
        return "enabled" if u else "disabled"
    if name == "DMX address" and u == 0xffff:
        return "unpatched (65535)"
    if name == "fixture state":
        addr, low = u >> 16, u & 0xffff
        if addr == 0xffff:
            return f"unpatched (0x{u:08x})"
        flags = [n for b, n in ((0, "invert pan"), (1, "invert tilt"),
                                (2, "swap pan/tilt")) if low >> b & 1]
        extra = low & ~0x7
        txt = ", ".join(flags) or "no flags"
        if extra:
            txt += f", unknown bits 0x{extra:04x}"
        return f"address {addr}, {txt}   (0x{u:08x})"
    if name == "edit playback":
        return f"pb{u + 1}"
    if name == "active cue" and u == 0xff:
        return "none (released)"
    if name == "active cue":
        return f"cue {u + 1}"
    return str(u)


def describe(payload: bytes):
    """
    Return (key, text) for one VN payload, or (None, text) for non-typed
    frames. key identifies the property instance for change detection.
    """
    n = len(payload)
    if n == 1:
        return ("keepalive",), "keepalive"
    if payload.startswith(b"visual_identify") or payload.startswith(b"<?xml"):
        return ("identify",), "identify " + ("request" if payload[0] == 0x76 else "reply")
    if n < 20:
        # Device properties, short form: [00, prop, 0 x6, length, value...].
        # A 9-byte frame with length 0 is a read; write id = read id + 1.
        body = payload[9:9 + payload[8]] if n > 9 else b""
        name = SHORT_PROPS.get(payload[1], f"cmd 0x{payload[1]:02x}")
        txt = body.split(b"\0", 1)[0]
        if payload[1] in (0x11, 0x12):
            shown = repr(txt.decode("latin1"))
        elif payload[1] == 0x00 and len(body) == 6:
            shown = ":".join(f"{b:02X}" for b in body)
        elif payload[1] == 0x03 and len(body) >= 4:
            shown = ".".join(str(b) for b in body[:4])
        elif payload[1] in (0x09, 0x0a) and len(body) == 2:
            shown = f"{body[0]}.{body[1]:02d}"
        elif payload[1] in (0xce, 0xef) and len(body) == 4:
            shown = "enabled" if struct.unpack("<I", body)[0] else "disabled"
        elif len(body) == 4:
            shown = str(struct.unpack("<I", body)[0])
        else:
            shown = body.hex(" ")
        kind = "query" if n == 9 and not any(payload[2:]) else ("write" if payload[1] == 0x12 else "")
        return ("short", payload[:2], n == 9), (
            f"device   {name:<22} {kind:<6} {shown}   [{payload[:min(n, 12)].hex(' ')}]")

    op, typ, prop = payload[0], payload[1], payload[2]
    i1, i2, i3 = struct.unpack_from("<HHH", payload, 4)
    body = payload[20:]
    obj = OBJECTS.get(op, f"op{op:02x}")
    name = PROPS.get((op, prop), f"prop 0x{prop:02x}")
    if typ == 0x81 and prop == 0x00:
        name = "changed"          # LPU change notification, body = change code

    if op == 0x2b:
        where = f"pb{i1 + 1} cue{i2 + 1}" + (f" block{i3}" if prop in (0x46, 0x47) else "")
    elif op == 0x1f:
        where = f"fixture{i1 + 1}"
    elif op == 0x28 and prop == 0x49:
        where = f"pb{i1 + 1} <-> pb{i2 + 1}"   # SWAP (confirmed idx 2,18 = pb3/pb19)
    elif op == 0x29 and prop == 0x04:
        # DELETE cue: idx 2 = first cue (0-based), idx 3 = number of cues
        # (confirmed 2026-10-22: cue 3 -> 2,1; all 3 -> 0,3; 2 of 3 -> 0,2)
        where = f"pb{i1 + 1} cue{i2 + 1} x{i3}"
    elif op == 0x29:
        where = f"pb{i1 + 1}"
    elif op == 0x2d or (op == 0x2c and prop == 0x32):
        where = f"attr {i1}"
        name = ATTR_NAMES.get(i1, f"attr {i1}")
    elif op == 0x2c and prop in (0x36, 0x37):
        where = f"pb{i1 + 1} cue{i2 + 1}"      # LOAD / RECORD target
    else:
        # unknown object: show all three raw 0-based indexes
        where = f"idx {i1},{i2},{i3}"

    is_attr = op == 0x2d or (op == 0x2c and prop == 0x32)
    value = decode_value(op, typ, prop, body, name, attr=i1 if is_attr else -1)
    base = typ & 0x7f if typ & NOTIFY_BIT else typ
    kind = TYPE_NAMES.get(base, f"t{base:02x}")
    if typ & NOTIFY_BIT:
        kind = "notify " + kind
    raw = payload[:3].hex(" ")
    text = f"{obj:<8} {where:<14} {name:<16} {value}   [{raw} {kind}]"
    key = (op, prop, i1, i2, i3, bool(typ & NOTIFY_BIT))
    return key, text


def find_tshark():
    for c in TSHARK_CANDIDATES:
        if os.path.exists(c):
            return c
    return shutil.which("tshark")


def run(args):
    tshark = find_tshark()
    if not tshark:
        sys.exit("tshark not found -- install Wireshark (with Npcap).")
    if args.list:
        subprocess.run([tshark, "-D"])
        return

    fields = ["-T", "fields", "-E", "separator=\t",
              "-e", "frame.time_epoch", "-e", "ip.src", "-e", "ip.dst",
              "-e", "udp.payload"]
    if args.pcap:
        cmd = [tshark, "-r", args.pcap, "-n",
               "-Y", f"udp.port == {VN_PORT} && ip.addr == {args.lpu}"] + fields
    else:
        cmd = [tshark, "-i", args.iface, "-l", "-n", "-Q",
               "-f", f"udp port {VN_PORT} and host {args.lpu}"] + fields
        print(f"[monitor] capturing on '{args.iface}' for LPU {args.lpu} -- "
              f"Ctrl+C to stop", flush=True)

    log = open(args.log, "w", encoding="utf-8", buffering=1) if args.log else None
    last = {}
    recent_app = []
    recent_notify = {}          # payload -> time, for the duplicate-socket copies
    shown = 0
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)
    try:
        for line in proc.stdout:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4 or not parts[3]:
                continue
            ts, src, _dst, hexdata = parts[:4]
            try:
                payload = bytes.fromhex(hexdata.replace(":", ""))
            except ValueError:
                continue
            key, text = describe(payload)
            from_app = src != args.lpu

            if not args.all:
                if key[0] in ("keepalive", "identify"):
                    continue
                if key[0] == "short":
                    # hide plain 9-byte queries and unchanged replies; show writes
                    if key[2] and not any(payload[2:]):
                        continue
                    if payload == last.get(key):
                        continue
                    last[key] = payload
                    t = datetime.datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S.%f")[:-3]
                    out = f"{t}  {'APP->LPU' if from_app else 'LPU->APP'}  {text}"
                    print(out, flush=True)
                    if log:
                        log.write(out + "\n")
                    shown += 1
                    continue
                op, typ, prop = payload[0], payload[1], payload[2]
                # The LPU sends every notification to two app sockets (e.g.
                # ports 60442 and 16945): drop the second copy.
                if not from_app and typ & NOTIFY_BIT:
                    t = float(ts)
                    for p in [p for p, pt in recent_notify.items() if t - pt > 0.05]:
                        del recent_notify[p]
                    if payload in recent_notify:
                        continue
                    recent_notify[payload] = t
                if from_app:
                    recent_app.append(payload)
                    del recent_app[:-64]
                elif payload in recent_app:
                    continue                    # LPU echo of an app frame
                if typ == 0x1d and prop != 0x38 and (op, prop) not in ACTIONS:
                    if (op, prop) in PROPS:
                        continue                # ordinary property read
                    if payload[:14] == last.get(key, b"")[:14]:
                        continue                # unknown request, already shown
                    last[key] = payload
                elif not from_app and not typ & NOTIFY_BIT:
                    # notifications are events and always shown; only plain
                    # replies are de-duplicated
                    if payload == last.get(key):
                        continue                # unchanged reply
                    if (op, prop) in IDLE_READS and key not in last:
                        last[key] = payload     # first idle-poll answer: baseline
                        continue
                    last[key] = payload

            t = datetime.datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S.%f")[:-3]
            arrow = "APP->LPU" if from_app else "LPU->APP"
            out = f"{t}  {arrow}  {text}"
            print(out, flush=True)
            if log:
                log.write(out + "\n")
            shown += 1
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        err = proc.stderr.read() if proc.stderr else ""
        if err.strip() and shown == 0:
            print(f"[monitor] tshark: {err.strip()}", file=sys.stderr)
        if log:
            log.close()


def main():
    ap = argparse.ArgumentParser(description="Live decoder for app <-> LPU VN traffic")
    ap.add_argument("--lpu", default=DEFAULT_LPU_IP, help="LPU IP (default %(default)s)")
    ap.add_argument("--iface", default="Wi-Fi",
                    help="capture interface name or number from --list (default %(default)s)")
    ap.add_argument("--list", action="store_true", help="list capture interfaces and exit")
    ap.add_argument("--pcap", help="decode a saved .pcapng instead of capturing live")
    ap.add_argument("--all", action="store_true",
                    help="show everything: keepalives, idle reads, repeated replies")
    ap.add_argument("--log", help="also write the decoded lines to this file")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
