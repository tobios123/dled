#!/usr/bin/env python3
"""
debug_lpu_discover_v2.py -- standalone LPU UDP discovery + session debug tool

Implements the full VN protocol flow observed in pcap captures.
Enhanced version with protocol documentation, better error messages, and type hints.

Protocol reference: dled_flutter/VN_PROTOCOL.md

Usage:
  python debug_lpu_discover_v2.py              # discover only
  python debug_lpu_discover_v2.py --connect    # discover + session init
  python debug_lpu_discover_v2.py --download   # discover, connect, download show
  python debug_lpu_discover_v2.py --ip 192.168.1.12 --download   # skip discovery
  python debug_lpu_discover_v2.py --ip 192.168.1.12 --download --dynamic   # whole show, any live state
"""

import argparse
import io
import socket
import struct
import sys
import threading
import time
import xml.etree.ElementTree as ET
from typing import Optional, Tuple, Dict

VN_PORT          = 16945
SESSION_PORT     = 16946
SESSION_TIMEOUT  = 0.1
DISCOVER_TIMEOUT = 60.0

SLOT_SENTINEL = bytes([0x55, 0xd8])
SLOT_COUNT    = 16
SLOT_RECORD   = 50
SLOT_SEN_OFF  = 24


# ---------------------------------------------------------------------------
# Logging / Output tee (write to both console and file)
# ---------------------------------------------------------------------------

class OutputTee:
    """
    Tee-like class that writes to both stdout (console) and an optional log file.
    When log_file_path is None, behaves like normal stdout.
    """
    def __init__(self, log_file_path: Optional[str] = None):
        self.console = sys.stdout
        self.log_file = None
        self.log_file_path = log_file_path
        if log_file_path:
            try:
                self.log_file = open(log_file_path, "w", buffering=1)
            except Exception as e:
                self.console.write(f"[WARNING] Could not open log file {log_file_path}: {e}\n")
                self.log_file = None

    def write(self, text: str) -> int:
        """Write to both console and log file."""
        self.console.write(text)
        self.console.flush()
        if self.log_file:
            self.log_file.write(text)
            self.log_file.flush()
        return len(text)

    def flush(self) -> None:
        """Flush both streams."""
        self.console.flush()
        if self.log_file:
            self.log_file.flush()

    def close(self) -> None:
        """Close the log file if open."""
        if self.log_file:
            self.log_file.close()
            self.log_file = None

    def isatty(self) -> bool:
        """Pretend to be a TTY (for line buffering behavior)."""
        return True


# ---------------------------------------------------------------------------
# XML broadcast parser
# ---------------------------------------------------------------------------

def parse_xml_broadcast(data: bytes, sender_ip: str) -> Optional[Dict[str, str]]:
    """
    Parse a visual_identify XML broadcast from an LPU.
    
    VN_PROTOCOL.md section 2 (Identify reply):
    Returns dict with keys: label, version, ip, port
    """
    try:
        text = data.rstrip(b"\x00").decode("utf-8", errors="replace").strip()
        if not text.startswith("<"):
            return None
        root = ET.fromstring(text)
        if root.tag != "visual_identify":
            return None
        label   = root.get("label", "unknown")
        version = (root.findtext("version") or "").strip()
        ip      = (root.findtext("ip")      or sender_ip).strip()
        port_str: str = ((root.findtext("port") or str(VN_PORT)).strip())
        return {"label": label, "version": version, "ip": ip, "port": port_str}
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def get_subnet_broadcasts() -> list[str]:
    """Get the broadcast address for each local IPv4 network."""
    broadcasts = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            local_ip = str(info[4][0])
            if local_ip.startswith("127."):
                continue
            parts = local_ip.rsplit(".", 1)
            if len(parts) == 2:
                broadcasts.append(parts[0] + ".255")
    except Exception:
        pass
    return broadcasts


IDENTIFY_PAYLOAD = b"visual_identify"


def discover_lpu(timeout: float = DISCOVER_TIMEOUT) -> Optional[Dict[str, str]]:
    """
    Broadcast visual_identify and listen for LPU XML reply.
    
    VN_PROTOCOL.md section 1-2 (Discovery):
    Sends ASCII "visual_identify" payload to port 16945 (broadcast).
    Listens for XML reply with device label, version, IP, port.
    """
    targets = list(dict.fromkeys(["255.255.255.255"] + get_subnet_broadcasts()))
    print(f"[DISCOVER] Broadcasting 'visual_identify' to: {', '.join(targets)}")
    print(f"[DISCOVER] Listening for LPU XML reply (up to {int(timeout)}s) ...")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 0))
    sock.settimeout(0.10)
    deadline = time.time() + timeout
    next_broadcast = 0.0

    try:
        while time.time() < deadline:
            if time.time() >= next_broadcast:
                for t in targets:
                    try:
                        sock.sendto(IDENTIFY_PAYLOAD, (t, VN_PORT))
                    except OSError:
                        pass
                next_broadcast = time.time() + 3.0
                remaining = deadline - time.time()
                print(f"\r[DISCOVER] Waiting ({remaining:.0f}s)...", end="", flush=True)
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            sender_ip = addr[0]
            if data == IDENTIFY_PAYLOAD:
                continue
            print(f"\r[DISCOVER] Received {len(data)} bytes from {sender_ip}:{addr[1]}")
            device = parse_xml_broadcast(data, sender_ip)
            if device is None:
                print(f"  (not XML: {data[:40].hex()})")
                continue
            print(f"[DISCOVER] Found LPU: label='{device['label']}' "
                  f"ip={device['ip']} port={device['port']} fw={device['version']}")
            return device
    finally:
        sock.close()

    print(f"\n[DISCOVER] Timeout -- no LPU reply in {timeout:.0f}s")
    return None


# ---------------------------------------------------------------------------
# Session open -- extracts session bytes from handshake
# ---------------------------------------------------------------------------

def open_session(lpu_ip: str, lpu_port: int = VN_PORT,
                 timeout: float = SESSION_TIMEOUT) -> Optional[Tuple[socket.socket, bytes]]:
    """
    Send cmd 0x0000 (9 zero bytes) on port VN_PORT and wait for handshake.
    
    VN_PROTOCOL.md section 10b (Status query on secondary channel):
    Sends 9-byte request. Waits for 18-byte response with type=0x06.
    Extracts session_bytes from response[4:6] for use in extended requests.
    
    Returns (sock, session_bytes) or None on failure.
    """
    print(f"[SESSION] Sending cmd 0x0000 (handshake) to {lpu_ip}:{lpu_port} ...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", SESSION_PORT))
    except OSError as e:
        print(f"[SESSION] WARNING: could not bind port {SESSION_PORT}: {e} -- using ephemeral")
        sock.bind(("", 0))
    sock.settimeout(timeout)

    sock.sendto(b"\x00" * 9, (lpu_ip, lpu_port))

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if addr[0] != lpu_ip:
            continue
        if len(data) < 9:
            continue

        resp_cmd  = struct.unpack(">H", data[:2])[0]
        resp_type = data[8] if len(data) > 8 else 0

        if resp_cmd == 0x0000 and resp_type == 0x06:
            # Extract session bytes from handshake response at offset 4-5.
            # These are used in all extended requests (0x1d type packets).
            session_bytes = data[4:6] if len(data) >= 6 else b"\x00\x00"
            print(f"[SESSION] Handshake OK: {data.hex()}")
            print(f"  session_bytes={session_bytes.hex()}  (used in extended requests at offset 4-5)")
            return (sock, session_bytes)

        print(f"  [SESSION] Unexpected reply: {data.hex()}")

    print("[SESSION] Timeout -- no handshake from LPU")
    sock.close()
    return None


# ---------------------------------------------------------------------------
# Keepalive
# ---------------------------------------------------------------------------

def keepalive_thread(sock: socket.socket, lpu_ip: str, lpu_port: int,
                     stop_event: threading.Event, interval: float = 0.025) -> None:
    """
    Send keepalive 0xFF bytes at 40 Hz.
    
    VN_PROTOCOL.md section 3 (Keepalive):
    Single 0xFF byte sent at 40 Hz (every 25 ms).
    LPU disconnects if keepalive is absent.
    """
    while not stop_event.is_set():
        try:
            sock.sendto(b"\xff", (lpu_ip, lpu_port))
        except OSError:
            break
        stop_event.wait(interval)


# ---------------------------------------------------------------------------
# Simple 9-byte request / 18-byte response (Phase 2 init commands)
# ---------------------------------------------------------------------------

# Short-form device properties (FINDINGS 20.5b): reply = [00, prop, 0 x6,
# length, value]. Names matched to the .show <device> block and the options page.
INIT_COMMANDS = [
    (0x0003, "subnet_mask"),
    (0x0009, "firmware_version"),
    (0x000a, "pcb_version"),
    (0x0011, "alias"),
    (0x0034, "artnet_universe"),
    (0x00ce, "artnet_enabled"),
    (0x00ea, "cmd_ea"),
    (0x00ef, "sacn_enabled"),
    (0x00f0, "sacn_universe"),
]


def make_request(cmd: int) -> bytes:
    """
    Build a 9-byte VN command request packet.
    
    VN_PROTOCOL.md section 10b:
    Offset 0-1: command (uint16 BE)
    Offset 2-8: reserved zeros
    """
    return struct.pack(">H", cmd) + b"\x00" * 7


def send_command(sock: socket.socket, lpu_ip: str, lpu_port: int,
                 cmd: int, timeout: float = SESSION_TIMEOUT,
                 max_resp_size: int = 4096) -> Optional[bytes]:
    """Send a 9-byte command and receive the response."""
    pkt = make_request(cmd)
    sock.sendto(pkt, (lpu_ip, lpu_port))
    old_timeout = sock.gettimeout()
    sock.settimeout(timeout)
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            try:
                data, addr = sock.recvfrom(max_resp_size)
            except socket.timeout:
                continue
            if addr[0] != lpu_ip:
                continue
            if len(data) >= 2 and struct.unpack(">H", data[:2])[0] == cmd:
                return data
    finally:
        sock.settimeout(old_timeout)
    return None


def decode_response(cmd: int, resp: Optional[bytes]) -> str:
    """Decode a 9-byte or 18-byte response payload."""
    if resp is None:
        return "(timeout)"
    if len(resp) < 9:
        return f"(short: {resp.hex()})"
    payload = resp[9:]
    if cmd == 0x0003:
        return f"subnet mask = {'.'.join(str(b) for b in payload[:4])}"
    if cmd == 0x0009:
        if len(payload) >= 2:
            return f"firmware = {payload[0]}.{payload[1]:02d}"
    if cmd == 0x000a:
        if len(payload) >= 2:
            return f"PCB version = {payload[0]}.{payload[1]}"
    if cmd == 0x0011:
        s = payload.rstrip(b"\x00").decode("ascii", errors="replace")
        return f"alias = '{s}'"
    if cmd in (0x0034, 0x00f0):
        if len(payload) >= 4:
            val = struct.unpack_from("<I", payload)[0]
            if cmd == 0x0034:
                return f"Art-Net universe = {val} (UI {val // 16}; stored as UI x 16)"
            return f"sACN universe = {val}"
    if cmd in (0x00ce, 0x00ef) and len(payload) >= 4:
        name = "Art-Net" if cmd == 0x00ce else "sACN"
        on = struct.unpack_from("<I", payload)[0]
        return f"{name} {'enabled' if on else 'disabled'}"
    rtype = resp[8]
    return f"type=0x{rtype:02x} data={payload.hex()}"


def run_session_init(sock: socket.socket, lpu_ip: str, lpu_port: int = VN_PORT) -> Dict[str, str]:
    """Run the standard initialization command sequence."""
    print(f"\n[SESSION] Running init commands on {lpu_ip}:{lpu_port} ...")
    results = {}
    for cmd, name in INIT_COMMANDS:
        resp = send_command(sock, lpu_ip, lpu_port, cmd)
        decoded = decode_response(cmd, resp)
        results[name] = decoded
        status = "OK" if resp else "TIMEOUT"
        print(f"  cmd 0x{cmd:04x} ({name:<18}) [{status}] {decoded}")
    return results


# ---------------------------------------------------------------------------
# Extended 20-byte request format (Phase 2b bulk fader dump, Phase 3 show)
# ---------------------------------------------------------------------------
#
# VN_PROTOCOL.md sections 11-12 (Show download/upload):
# Extended request = 20-byte packet with magic, type, command, and session context.
#
# Pcap-confirmed layout (PKT#4176 -- show download request):
#   2b 1d 46 00  08 00 02 00  00 00 ff ff  00 00 ec 04  00 00 00 00
#   ^  ^  ^  ^   ^--sess---^  ^---0x0002-^ ^--page---^  ^--seq----^  pad
#   b0 b1 b2 b3  b4 b5 b6 b7  b8 b9 ba bb  bc bd be bf  b10-b13
#
# Pcap-confirmed layout (PKT#2517 -- bulk fader dump request):
#   29 1d 30 00  00 00 00 00  00 00 ff ff  00 00 17 02  00 00 00 00
#   magic=0x29 (not 0x2b!), session=0x0000, extra=0x0000
#
# Extended request byte layout:
#   b0    = magic  (0x2b for show/fader, 0x29 for bulk fader dump)
#   b1    = 0x1d   (request type marker)
#   b2    = cmd
#   b3    = 0x00
#   b4-5  = session_bytes  (from handshake[4:6], e.g. 0x08 0x00)
#   b6-7  = 0x02 0x00      (fixed for show/fader; 0x00 0x00 for bulk dump)
#   b8-9  = index LE       (page for show, channel for fader, 0 for bulk dump)
#   b10-11= 0xff 0xff      (mask / broadcast)
#   b12-13= 0x00 0x00      (data length field -- 0 for requests)
#   b14-15= seq LE
#   b16-19= 0x00 * 4       (padding)

EXT_MAGIC_SHOW  = 0x2b   # used by show download (0x46) and per-slot fader (0x29/0x2b)
EXT_MAGIC_FADER = 0x29   # used by bulk fader dump (0x30)
EXT_REQ_TYPE    = 0x1d

CMD_SHOW        = 0x46
CMD_FADER_LEVEL = 0x29
CMD_FADER_QUERY = 0x2b   # single fader query (per-slot)
CMD_BULK_FADER  = 0x30   # bulk fader dump -- triggers burst of 24-byte fader pushes


def make_extended_request(magic: int, cmd: int,
                          session_bytes: bytes,
                          index: int, seq: int,
                          extra: bytes = b"\x02\x00") -> bytes:
    """
    Build a 20-byte extended VN request packet.

    VN_PROTOCOL.md sections 11-12 (Show download/upload, Bulk fader):
    
    Args:
        magic        -- 0x2b for show/fader, 0x29 for bulk fader dump
        cmd          -- command byte (e.g. 0x46=show, 0x30=bulk dump)
        session_bytes-- 2 bytes from handshake[4:6] (or b'\\x00\\x00' for bulk dump)
        index        -- page (show) or channel (fader) or 0 (bulk dump), uint16 LE
        seq          -- sequence counter, uint16 LE
        extra        -- bytes 6-7; use b'\\x02\\x00' for show/fader, b'\\x00\\x00' for bulk
    
    Returns:
        20-byte packet ready to send to LPU:16945
    """
    if len(session_bytes) < 2:
        session_bytes = session_bytes.ljust(2, b"\x00")
    if len(extra) < 2:
        extra = extra.ljust(2, b"\x00")
    
    # Bytes 0-3: magic, request type, command, reserved
    pkt = struct.pack(
        "<BBBB",
        magic,
        EXT_REQ_TYPE,
        cmd,
        0x00,
    )
    
    # Bytes 4-5: session bytes (dynamic per connection)
    pkt += session_bytes[:2]
    
    # Bytes 6-7: extra (0x02 0x00 for show/fader, 0x00 0x00 for bulk)
    pkt += extra[:2]
    
    # Bytes 8-9: index (page/channel/0, uint16 LE)
    pkt += struct.pack("<H", index)
    
    # Bytes 10-11: broadcast mask (0xFF 0xFF for requests)
    pkt += b"\xff\xff"
    
    # Bytes 12-13: data length (0x00 0x00 for requests, 0x20 0x03 for 800-byte payloads)
    pkt += b"\x00\x00"
    
    # Bytes 14-15: sequence counter (uint16 LE)
    pkt += struct.pack("<H", seq)
    
    # Bytes 16-19: padding (always zeros)
    pkt += b"\x00\x00\x00\x00"
    
    return pkt


# ---------------------------------------------------------------------------
# Phase 2b: Bulk fader dump (cmd 0x30) -- receives burst of 24-byte pushes
# ---------------------------------------------------------------------------

def decode_fader_push(data: bytes) -> Optional[Tuple[int, float]]:
    """
    Parse a 24-byte fader push/response packet.

    VN_PROTOCOL.md section 4 (Level packet):
    Layout:
      b0    = magic  (0x29 or 0x2b)
      b1    = type   (0x81 = unsolicited push, 0x01 = response)
      b2    = cmd    (0x00 or 0x29)
      b3    = 0x00
      b4-5  = channel index LE
      b6-7  = 0x00 0x00
      b8-11 = 0x00 * 4
      b12-13= 0x04 0x00
      b14-19= 0x00 * 6
      b20-23= float32 LE  (fader level 0.0..1.0)

    Returns (channel, level) or None if not parseable.
    """
    if len(data) < 24:
        return None
    if data[0] not in (0x29, 0x2b):
        return None
    if data[1] not in (0x81, 0x01):
        return None
    channel = struct.unpack_from("<H", data, 4)[0]
    level   = struct.unpack_from("<f", data, 20)[0]
    return (channel, level)


def query_bulk_fader_dump(sock: socket.socket, lpu_ip: str,
                          lpu_port: int = VN_PORT,
                          session_bytes: bytes = b"\x00\x00",
                          seq: int = 0x0217,
                          timeout: float = 0.10,
                          max_channels: int = 256) -> Dict[int, float]:
    """
    Send the bulk fader dump request (cmd 0x30) and collect the burst of
    24-byte fader push packets.

    VN_PROTOCOL.md section 4 (Level packet):
    Sends magic=0x29 extended request with cmd=0x30.
    Receives burst of 24-byte fader level packets (type 0x81).

    Returns dict of {channel_index: fader_level}.
    """
    print(f"\n[FADERS] Sending bulk fader dump request (cmd=0x30) ...")
    req = make_extended_request(
        magic=EXT_MAGIC_FADER,   # 0x29
        cmd=CMD_BULK_FADER,      # 0x30
        session_bytes=session_bytes,
        index=0,
        seq=seq,
        extra=b"\x00\x00",       # pcap shows 0x00 0x00 here for bulk dump
    )
    print(f"  Request ({len(req)}B): {req.hex()}")
    sock.sendto(req, (lpu_ip, lpu_port))

    old_timeout = sock.gettimeout()
    sock.settimeout(timeout)
    faders: Dict[int, float] = {}
    deadline = time.time() + timeout
    received = 0

    try:
        while time.time() < deadline:
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                break
            if addr[0] != lpu_ip:
                continue
            if len(data) != 24:
                continue
            result = decode_fader_push(data)
            if result is None:
                continue
            channel, level = result
            faders[channel] = level
            received += 1
            print(f"  fader push: channel={channel:3d}  level={level:.4f}  raw={data.hex()}")
            if received >= max_channels:
                break
    finally:
        sock.settimeout(old_timeout)

    print(f"  [FADERS] Received {received} fader values: {faders}")
    return faders


# ---------------------------------------------------------------------------
# Phase 2b: Per-slot cuelist queries (9-byte format)
# ---------------------------------------------------------------------------

SLOT_OPS = [0x1f, 0x2b, 0x2c, 0x29, 0x2d]
OP_NAMES = {
    0x1f: "name/fixture",
    0x2b: "cue_step_list",
    0x2c: "config_object",
    0x29: "fader_level",
    0x2d: "float_params",
}


def decode_slot_response(op: int, resp: Optional[bytes]) -> str:
    """Decode response payload from a per-slot query."""
    if resp is None:
        return "(timeout)"
    if len(resp) < 9:
        return f"(short {len(resp)}B: {resp.hex()})"
    payload = resp[9:]
    if op == 0x29:
        if len(resp) >= 24:
            try:
                level = struct.unpack_from("<f", resp, 20)[0]
                ch    = struct.unpack_from("<H", resp, 12)[0] if len(resp) >= 14 else 0
                return f"channel={ch} level={level:.4f}"
            except Exception:
                pass
        return f"raw={resp[9:].hex()}"
    if op == 0x2d:
        if len(resp) >= 24:
            try:
                param_idx = struct.unpack_from("<H", resp, 4)[0]
                value     = struct.unpack_from("<f", resp, 20)[0]
                return f"param_idx={param_idx} value={value:.4f}"
            except Exception:
                pass
        return f"raw={resp[9:].hex()}"
    if op in (0x1f, 0x2b):
        if len(resp) > 20:
            raw = resp[20:]
            s = raw.rstrip(b"\x00").decode("utf-8", errors="replace")
            return f"'{s[:120]}'" + (" ..." if len(s) > 120 else "")
        return f"raw={resp[9:].hex()}"
    if op == 0x2c:
        if len(resp) > 20:
            return f"config bytes={resp[20:].hex()}"
        return f"raw={resp[9:].hex()}"
    return f"raw={resp[9:].hex()}"


def query_slot_data(sock: socket.socket, lpu_ip: str,
                    populated_slots: list[int],
                    lpu_port: int = VN_PORT,
                    timeout: float = SESSION_TIMEOUT) -> Dict:
    """Query per-slot data (name, cue list, config, levels) for all populated slots."""
    if not populated_slots:
        print("\n[SLOTS] No populated slots -- skipping per-slot queries")
        return {}
    print(f"\n[SLOTS] Querying data for {len(populated_slots)} slot(s): {populated_slots}")
    all_data: Dict = {}
    for slot_idx in populated_slots:
        bank = slot_idx + 1
        slot_data: Dict = {}
        print(f"\n  -- Slot {slot_idx} (bank 0x{bank:02x}) --")
        for op in SLOT_OPS:
            cmd = (bank << 8) | op
            op_name = OP_NAMES.get(op, f"op_0x{op:02x}")
            resp = send_command(sock, lpu_ip, lpu_port, cmd, timeout=timeout, max_resp_size=4096)
            decoded = decode_slot_response(op, resp)
            status = "OK" if resp else "TIMEOUT"
            slot_data[op_name] = decoded
            print(f"    cmd 0x{cmd:04x} ({op_name:<16}) [{status}] {decoded}")
        all_data[slot_idx] = slot_data
    return all_data


# ---------------------------------------------------------------------------
# Phase 3: Show download (20-byte extended requests, 820-byte responses)
# ---------------------------------------------------------------------------
#
# VN_PROTOCOL.md sections 11-12 (Show download / upload) -- re-decoded
# 2026-10-22 from download_show__show_all_fx_options.pcapng and
# download_show_M400&12X12 - RGB_dim_shut.pcapng (request direction):
#
#   Request  (app->LPU, 20 bytes):
#     2b 1d 46 00 | <pb u16 LE> | <cue u16 LE> | <block u16 LE> | ff ff |
#     00 00 (data length) | <seq u16 LE> | 00 00 00 00
#   Response (LPU->app, 820 bytes):
#     2b 0a 46 00 | <pb u16> | <cue u16> | <block u16> | ff ff |
#     20 03 (data length 800) | <seq u16, echoed> | 00 00 00 00 | <800 bytes>
#
# The page is selected ONLY by (pb, cue, block) at bytes 4-9. There is no flash
# address: bytes 12-15 are the ordinary data-length + packet-counter fields,
# which -- read together as one LE u32 -- merely LOOK like an address
# (length 0, counter 0x044c -> "0x044c0000"; reply length 0x320 -> "+0x320").
# The old code left pb at 0, so every page it fetched was a cue of playback 0
# (see analysis/output/playback_states_output.txt: "header pb0 p0 vs plan pb1
# p0" on every page after pb0).
#
# Before each cue's 4 blocks the reference app reads 4 cue properties with the same
# (pb, cue) addressing: 0x05 = cue label, 0x27 = condition, 0x29 = fade ms,
# 0x2b = delay ms. The LPU answers them; they are harmless and kept to mirror
# the app.
#
# Safety: only (pb, cue) pairs whose cue count the LPU itself reported are ever
# requested, block 0..3 only, so the walk can never run out of range (the old
# open-ended walk with ever-growing indexes is what wedged the LPU).

SHOW_PAGE_SIZE       = 800        # payload bytes per 820-byte response
SHOW_RESP_TYPE       = 0x0a       # response type byte (b1) for show pages
SHOW_BLOCKS_PER_PAGE = 4          # 4 blocks per cue page (fixtures 0-15/16-31/32-47/48-63)
SHOW_META_SUBS       = (0x05, 0x27, 0x29, 0x2b)  # per-cue property reads before the blocks

# Manual (non --dynamic) fallback plan == the "download current show" capture:
# pb0=5, pb1=7, pb2=6, pb8=3. Use --dynamic to read the real plan from the LPU.
DEFAULT_SHOW_PAGES        = 21
DEFAULT_SHOW_PAGES_PER_PB = "0:5,1:7,2:6,8:3"

# Absolute safety cap for the manual path (the dynamic path is bounded by the
# cue counts the LPU reports).
SHOW_MAX_PAGES_HARD_CAP = 128

# ---------------------------------------------------------------------------
# Playback cue counts -- playback property 0x30 (state) and 0x3d (cue count)
# ---------------------------------------------------------------------------
#
# The reference app reads playback property 0x30 for every slot 0..63:
#
#   29 1d 30 00 | <pb u16 LE> | 00 00 | 00 00 | ff ff | 00 00 | <seq u16> | 00*4
#
# and the 24-byte reply 29 01 30 .. carries 4 bytes at [20:24]:
#   [go_mode << 4 | exclusive << 1 | background,
#    repeat << 4 | state, cue_count, active_cue]
# state: 0 = empty, 1 = loaded/released, 3 = running (hardware run 2026-10-22).
# go_mode / repeat / checkboxes are proven by the self-describing playbacks in
# selecting_and_deselcting_lpu_in_device_list.pcapng (64fixtures_playback_menu
# show): 'backg solo off' = 31 31 05 ff, 'exclu flash ran' = 22 21 01 ff,
# 'backg excl togg' = 13 12 01 00.
# active_cue is 0xff when the playback is RELEASED -- the same encoding as the
# LPU's 29 81 2f "active cue" push (0xff = none). The old parser required that
# byte to be 0xff, so a RUNNING playback (active_cue = cue index) was discarded
# and its pages were never downloaded (FINDINGS.md section 19).
#
# Whether a running playback's 0x30 reply really carries its cue index there
# or the LPU stays silent has not been captured yet, so this code does not
# depend on 0x30 at all for the page plan: when 0x30 gives no usable reply it
# reads playback property 0x3d, the plain cue count the reference app reads back
# after an upload (29 1d 3d -> 29 01 3d <u32 count>). The cue count is stored
# show data and does not change with the live state.
PB_PROP_STATE     = 0x30       # [00, populated, cue_count, active_cue]
PB_PROP_CUE_COUNT = 0x3d       # u32 number of cues
DIR_SLOT_COUNT    = 64         # playback slots 0..63
ACTIVE_CUE_NONE   = 0xff       # active_cue value of a released playback

# On the wire playbacks and cues are 0-based; everything this script PRINTS is
# 1-based to match the reference app (playback 1..64, cue 1..N).

# Playback Properties window. Go mode, repeat, Background and Exclusive come
# packed in the 0x30 reply (above); the rest is read with 29 1d <prop>
# (values match the .show files in download_show_M400... and
# selecting_and_deselcting_lpu_in_device_list.pcapng):
#   0x05 label (string)   0x17 intensity (float)   0x15 speed (float)
# They also have stand-alone properties (write/read): go mode 0x21/-,
# repeat 0x2e/0x2d, background 0x1e/0x1d, exclusive 0x3a/0x39 (confirmed
# live with live_vn_monitor.py, 2026-10-22) -- not needed here.
PB_PROP_LABEL     = 0x05
PB_PROP_SPEED     = 0x15
PB_PROP_INTENSITY = 0x17
GO_MODES     = {0: "Go", 1: "Toggle", 2: "Flash", 3: "Solo"}
REPEAT_MODES = {0: "Loop", 1: "Bounce", 2: "Random", 3: "Off"}


class SeqCounter:
    """Packet counter for bytes 14-15 of every extended request (+1 per frame)."""

    def __init__(self, start: int = 0x0100):
        self.value = start & 0xFFFF

    def next(self) -> int:
        v = self.value
        self.value = (self.value + 1) & 0xFFFF
        return v


def make_property_read(op: int, prop: int, i1: int, i2: int, i3: int,
                       seq: int) -> bytes:
    """
    Build a 20-byte property READ request exactly as the reference app sends it:
      <op> 1d <prop> 00 | <i1 u16> | <i2 u16> | <i3 u16> | ff ff |
      00 00 | <seq u16> | 00 00 00 00
    op = 0x29 playback / 0x2b cue / 0x1f fixture; i1 = pb (or fixture),
    i2 = cue, i3 = block.
    """
    return struct.pack("<BBBBHHHHHHI", op, EXT_REQ_TYPE, prop, 0x00,
                       i1 & 0xFFFF, i2 & 0xFFFF, i3 & 0xFFFF,
                       0xFFFF, 0x0000, seq & 0xFFFF, 0)


def make_directory_request(pb: int, seq: int) -> bytes:
    """Playback property 0x30 read (state + cue count) for one playback slot."""
    return make_property_read(EXT_MAGIC_FADER, PB_PROP_STATE, pb, 0, 0, seq)


def parse_directory_response(data: bytes) -> Optional[Tuple[int, int, int, int, int, int, int]]:
    """
    Parse a playback property 0x30 reply (29 01 30 ..).

    Body @20:24 = [go_mode << 4 | exclusive << 1 | background,
                   repeat << 4 | state, cue_count, active_cue].
    Accepted whatever the active_cue byte is (0xff = released, else the live
    cue index), so a running playback is never dropped here.

    Returns (pb, go_mode, checkboxes, repeat, state, cue_count, active_cue)
    or None if this is not a 0x30 reply.
    """
    if len(data) < 24:
        return None
    if data[0] != EXT_MAGIC_FADER or data[1] != 0x01 or data[2] != PB_PROP_STATE:
        return None
    pb   = struct.unpack_from("<H", data, 4)[0]
    body = data[20:24]
    return (pb, body[0] >> 4, body[0] & 0x0f, body[1] >> 4, body[1] & 0x0f,
            body[2], body[3])


def _await_reply(sock, lpu_ip: str, timeout: float, match) -> Optional[bytes]:
    """Receive until match(data) is truthy or timeout; other datagrams are dropped."""
    sock.settimeout(timeout)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            return None
        except OSError:
            return None
        if addr[0] != lpu_ip:
            continue
        if match(data):
            return data
    return None


def query_cue_count(sock, lpu_ip: str, lpu_port: int, pb: int, seq: SeqCounter,
                    per_request_timeout: float = 0.5,
                    max_retries: int = 3) -> Optional[int]:
    """
    Read playback property 0x3d (number of cues) for one playback.
    Independent of the live state -- used when the 0x30 read gives no reply.
    """
    def is_reply(d: bytes) -> bool:
        return (len(d) >= 24 and d[0] == EXT_MAGIC_FADER and d[1] == 0x01
                and d[2] == PB_PROP_CUE_COUNT
                and struct.unpack_from("<H", d, 4)[0] == pb)

    for _ in range(max(1, max_retries)):
        sock.sendto(make_property_read(EXT_MAGIC_FADER, PB_PROP_CUE_COUNT,
                                       pb, 0, 0, seq.next()),
                    (lpu_ip, lpu_port))
        data = _await_reply(sock, lpu_ip, per_request_timeout, is_reply)
        if data is not None:
            return struct.unpack_from("<I", data, 20)[0]
    return None


def read_property(sock, lpu_ip: str, lpu_port: int, op: int, prop: int,
                  i1: int, seq: SeqCounter, per_request_timeout: float = 0.5,
                  max_retries: int = 3):
    """
    Read one property and decode it by the reply's value-type byte:
    0x00 string, 0x01/0x02 u32, 0x03 float. Returns None on no reply.
    """
    def is_reply(d: bytes) -> bool:
        return (len(d) >= 20 and d[0] == op and d[2] == prop
                and d[1] in (0x00, 0x01, 0x02, 0x03)
                and struct.unpack_from("<H", d, 4)[0] == i1)

    for _ in range(max(1, max_retries)):
        sock.sendto(make_property_read(op, prop, i1, 0, 0, seq.next()),
                    (lpu_ip, lpu_port))
        d = _await_reply(sock, lpu_ip, per_request_timeout, is_reply)
        if d is None:
            continue
        body = d[20:]
        if d[1] == 0x00:
            return body.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        if len(body) < 4:
            return None
        if d[1] == 0x03:
            return struct.unpack_from("<f", body)[0]
        return struct.unpack_from("<I", body)[0]
    return None


def read_playback_options(sock, lpu_ip: str, lpu_port: int, pb: int,
                          seq: SeqCounter, go_mode: int, checkboxes: int,
                          repeat: int) -> str:
    """Format one playback's Playback Properties for [DIR-DBG] (reads label/intensity/speed)."""
    def rd(prop):
        return read_property(sock, lpu_ip, lpu_port, EXT_MAGIC_FADER, prop, pb, seq)

    label     = rd(PB_PROP_LABEL)
    intensity = rd(PB_PROP_INTENSITY)
    speed     = rd(PB_PROP_SPEED)

    def fmt(v, f):
        return "?" if v is None else f(v)

    return (f"label={label!r} go={GO_MODES.get(go_mode, go_mode)} "
            f"repeat={REPEAT_MODES.get(repeat, repeat)} "
            f"intensity={fmt(intensity, lambda v: f'{v * 100:.0f}%')} "
            f"speed={fmt(speed, lambda v: f'{v:g}')} "
            f"background={checkboxes & 1} exclusive={(checkboxes >> 1) & 1}")


def query_directory(sock, lpu_ip: str, lpu_port: int, seq: SeqCounter,
                    per_request_timeout: float = 0.5,
                    slot_count: int = DIR_SLOT_COUNT,
                    max_retries: int = 4,
                    debug: bool = False):
    """
    Build the page plan from the LPU: the cue count of every playback 0..63,
    whatever its live state.

    Per playback:
      1. read property 0x30 (what the reference app does) -- any reply is accepted,
         running or released;
      2. if that gets no reply, read property 0x3d (cue count), which does not
         depend on the live state.
    A playback is planned when either read reports cue_count > 0.

    Returns (pages_per_pb, total_pages): pages_per_pb is an ordered list of
    (pb, cue_count); total_pages is their sum.
    """
    pages_per_pb = []
    total_pages  = 0
    running: Dict[int, int] = {}
    via_fallback = []

    # Drain stale datagrams from the init phase so they cannot be mistaken for
    # a reply to the first query.
    sock.settimeout(0.05)
    try:
        while True:
            sock.recvfrom(4096)
    except (socket.timeout, OSError):
        pass

    for pb in range(slot_count):
        parsed = None
        for _attempt in range(max(1, max_retries)):
            try:
                sock.sendto(make_directory_request(pb, seq.next()), (lpu_ip, lpu_port))
            except OSError:
                break
            data = _await_reply(
                sock, lpu_ip, per_request_timeout,
                lambda d: (parse_directory_response(d) or (None,))[0] == pb)
            if data is not None:
                parsed = parse_directory_response(data)
                break

        if parsed is not None:
            _, go_mode, checkboxes, repeat, state, cue_count, active_cue = parsed
            if active_cue != ACTIVE_CUE_NONE and cue_count > 0:
                running[pb] = active_cue
            if debug:
                live = ("released" if active_cue == ACTIVE_CUE_NONE
                        else f"RUNNING on cue {active_cue + 1}")
                kind = live if state else "empty"
                line = (f"[DIR-DBG] pb{pb + 1:<2d} 0x30 state={state} "
                        f"cues={cue_count} active=0x{active_cue:02x} ({kind})")
                if state or cue_count:
                    line += " | " + read_playback_options(
                        sock, lpu_ip, lpu_port, pb, seq, go_mode, checkboxes, repeat)
                print(line)
        else:
            # No 0x30 reply -- ask for the cue count directly.
            cue_count = query_cue_count(sock, lpu_ip, lpu_port, pb, seq,
                                        per_request_timeout=per_request_timeout)
            if cue_count is None:
                if debug:
                    print(f"[DIR-DBG] pb{pb + 1:<2d} no reply to 0x30 or 0x3d -- skipped")
                continue
            if cue_count > 0:
                via_fallback.append(pb)
            if debug:
                print(f"[DIR-DBG] pb{pb + 1:<2d} no 0x30 reply; 0x3d cue count={cue_count}")

        if cue_count > 0:
            pages_per_pb.append((pb, cue_count))
            total_pages += cue_count

    if running:
        detail = ", ".join(f"pb{p + 1}:cue {c + 1}" for p, c in sorted(running.items()))
        print(f"[DIRECTORY] running playbacks (included) -> {{{detail}}}")
    if via_fallback:
        print(f"[DIRECTORY] no 0x30 reply, cue count read via 0x3d -> "
              f"{['pb%d' % (p + 1) for p in via_fallback]}")
    return (pages_per_pb, total_pages)


def make_show_meta_request(sub: int, pb_idx: int, cue: int, seq: int) -> bytes:
    """Cue property read (0x05 label, 0x27 condition, 0x29 fade, 0x2b delay)."""
    return make_property_read(EXT_MAGIC_SHOW, sub, pb_idx, cue, 0, seq)


def make_show_download_request(pb_idx: int, cue: int, block: int, seq: int) -> bytes:
    """
    Build the 20-byte show-page read the reference app sends:
      2b 1d 46 00 | <pb u16> | <cue u16> | <block u16> | ff ff |
      00 00 | <seq u16> | 00 00 00 00
    """
    return make_property_read(EXT_MAGIC_SHOW, CMD_SHOW, pb_idx, cue, block, seq)


def parse_show_response(data: bytes) -> Optional[Tuple[int, int, int, bytes]]:
    """
    Parse an 820-byte show page response:
      2b 0a 46 00 | pb u16 @4 | cue u16 @6 | block u16 @8 | ff ff |
      20 03 | seq u16 | 00 00 00 00 | 800-byte payload @20

    Returns (pb_idx, cue, block, payload) or None.
    """
    if len(data) < 20 + SHOW_PAGE_SIZE:
        return None
    if data[0] != EXT_MAGIC_SHOW or data[1] != SHOW_RESP_TYPE or data[2] != CMD_SHOW:
        return None
    pb_idx, cue, block = struct.unpack_from("<HHH", data, 4)
    return (pb_idx, cue, block, data[20:20 + SHOW_PAGE_SIZE])


def _build_page_plan(num_pages: int, pages_per_pb: Optional[list]) -> list:
    """
    Expand [(pb, cue_count), ...] into an ordered list of (linpage, pb, cue),
    truncated to num_pages. Without pages_per_pb, pages are pb0 cues 0..n-1.
    """
    pairs = []
    if pages_per_pb:
        for pb_idx, count in pages_per_pb:
            for cue in range(count):
                pairs.append((pb_idx, cue))
    else:
        pairs = [(0, cue) for cue in range(num_pages)]
    return [(lp, pb, cue) for lp, (pb, cue) in enumerate(pairs[:num_pages])]


def download_show(sock: socket.socket, lpu_ip: str, lpu_port: int = VN_PORT,
                  session_bytes: bytes = b"\x00\x00",
                  num_pages: Optional[int] = None,
                  pages_per_pb: Optional[list] = None,
                  send_metadata: bool = True,
                  per_request_timeout: float = 1.0,
                  max_retries: int = 3,
                  max_pages: int = SHOW_MAX_PAGES_HARD_CAP,
                  seq: Optional[SeqCounter] = None) -> bytes:
    """
    Download every planned cue page, addressed by (pb, cue, block) exactly like
    the reference app. The live state of a playback plays no part: a running
    playback's pages are read like any other.

    Each block is retried up to max_retries times; a block that never arrives is
    recorded as zeros. The plan is never extended, so no request is ever made
    for a (pb, cue) the LPU did not report.
    """
    if seq is None:
        seq = SeqCounter()
    if num_pages is None:
        num_pages = DEFAULT_SHOW_PAGES
    if num_pages < 1:
        print("  [DOWNLOAD] num_pages < 1 -- nothing to do.")
        return b""
    if num_pages > max_pages:
        print(f"  [DOWNLOAD] WARNING: num_pages {num_pages} exceeds hard cap "
              f"{max_pages}; clamping to {max_pages}.")
        num_pages = max_pages

    plan = _build_page_plan(num_pages, pages_per_pb)
    print(f"\n[DOWNLOAD] Starting show download from {lpu_ip}:{lpu_port}")
    print(f"  pages={len(plan)}  blocks/page={SHOW_BLOCKS_PER_PAGE}  "
          f"cue property reads: {'on' if send_metadata else 'off'}")

    old_timeout = sock.gettimeout()
    blocks: Dict[Tuple[int, int, int], bytes] = {}
    total_req = 0

    try:
        for linpage, pb_idx, cue in plan:
            # 1. Cue property reads (mirror the reference app; replies are ignored).
            if send_metadata:
                for sub in SHOW_META_SUBS:
                    try:
                        sock.sendto(make_show_meta_request(sub, pb_idx, cue, seq.next()),
                                    (lpu_ip, lpu_port))
                    except OSError:
                        pass

            # 2. The 4 blocks of this cue page.
            for block in range(SHOW_BLOCKS_PER_PAGE):
                want = (pb_idx, cue, block)
                resp = None
                for _attempt in range(max(1, max_retries)):
                    req = make_show_download_request(pb_idx, cue, block, seq.next())
                    if linpage == 0 and block == 0 and _attempt == 0:
                        print(f"  First download request ({len(req)}B): {req.hex()}")
                    sock.sendto(req, (lpu_ip, lpu_port))
                    total_req += 1
                    data = _await_reply(
                        sock, lpu_ip, per_request_timeout,
                        lambda d: (parse_show_response(d) or (None,))[:3] == want)
                    if data is not None:
                        resp = parse_show_response(data)
                        break

                if resp is None:
                    print(f"  linpage {linpage:2d} pb{pb_idx + 1} cue{cue + 1} block {block}: "
                          f"TIMEOUT after {max_retries} tries (recorded empty)")
                    continue

                payload = resp[3]
                blocks[want] = payload
                nz = sum(1 for b in payload if b != 0)
                print(f"  linpage {linpage:2d} pb{pb_idx + 1} cue{cue + 1} block {block}: "
                      f"{len(payload)}B {nz} non-zero")
    finally:
        sock.settimeout(old_timeout)

    if not blocks:
        print("  [DOWNLOAD] No blocks received.")
        return b""

    # Assemble in plan order: (pb, cue) ascending as planned, block 0..3.
    parts = []
    for _lp, pb_idx, cue in plan:
        for blk in range(SHOW_BLOCKS_PER_PAGE):
            parts.append(blocks.get((pb_idx, cue, blk), b"\x00" * SHOW_PAGE_SIZE))
    show_bytes = b"".join(parts)
    total_nonzero = sum(1 for b in show_bytes if b != 0)
    print(f"\n  [DOWNLOAD] Complete: {len(blocks)}/{len(plan) * SHOW_BLOCKS_PER_PAGE} "
          f"blocks received ({total_req} requests), {len(show_bytes)} bytes total, "
          f"{total_nonzero} non-zero bytes")
    return show_bytes


# ---------------------------------------------------------------------------
# Graceful session close -- return the LPU to its idle keepalive+poll state
# ---------------------------------------------------------------------------
#
# VN_PROTOCOL.md section 13 (Session close / teardown):
# Capture analysis of selecting_and_deselcting_lpu_in_device_list.pcapng proved
# there is NO disconnect command and the app NEVER goes silent -- its keepalive
# (0xFF, 40 Hz) and a light status-poll loop (magic 0x29, cmds 0x05/0x15/0x17/
# 0x30, seq incrementing) run CONTINUOUSLY, even across UI deselects. The app is
# never left sitting in a paged-transfer (0x46/0x47) state.
#
# IMPORTANT -- the earlier "abrupt socket close" / "keepalive hold" theories were
# RED HERRINGS. Holding the session alive for 120s did NOT keep the LPU visible.
# The real cause of the LPU becoming unreachable was the show page download
# asking for OUT-OF-RANGE flash addresses (it climbed open-ended). Disabling the
# page download kept the LPU alive across repeated runs; the fixed, bounded
# download (see download_show) is the actual cure. This graceful wind-down is
# kept only as good hygiene -- it drains any pending replies and resumes the
# app's status-poll loop for a few rounds so the LPU is left in its idle state
# before we stop the keepalive and close the socket.

# Status-poll cmds the reference app cycles forever (magic 0x29, extra 0x0000).
POLL_CMDS = (0x05, 0x15, 0x17, 0x30)


def graceful_session_close(sock: socket.socket, lpu_ip: str, lpu_port: int,
                           session_bytes: bytes,
                           stop_keepalive: threading.Event,
                           poll_rounds: int = 3,
                           keepalive_hold: float = 0.6) -> None:
    """
    Return the LPU to its idle keepalive+poll steady-state before closing.

    VN_PROTOCOL.md section 13 (Session close / teardown):
    1. Drain any inbound packets still queued from the LPU (empties its send
       side so it is not mid-transfer).
    2. Resume the normal status-poll loop (cmds 0x05/0x15/0x17/0x30, magic 0x29)
       for a few rounds -- this is what the app always does after a transfer,
       moving the LPU out of download/upload state back to idle polling.
    3. Hold the session open for a short keepalive_hold dwell (default 0.6s)
       with the keepalive thread still running at 40 Hz and the status-poll loop
       interleaved -- just enough to flush the idle steady-state. (A long hold
       was tried and did NOT keep the LPU visible; the real fix is the bounded
       show download, so a short dwell is all that is needed here.)
    4. Stop the keepalive thread, let it flush, then return so main() can close.
    """
    print("\n[CLOSE] Graceful wind-down -- returning LPU to idle poll state ...")

    old_timeout = sock.gettimeout()
    seq = 0xf000

    def send_poll_round() -> None:
        """Send one round of the app's 0x29 status-poll loop, draining replies."""
        nonlocal seq
        for cmd in POLL_CMDS:
            req = make_extended_request(
                magic=EXT_MAGIC_FADER,   # 0x29 -- the app's poll magic
                cmd=cmd,
                session_bytes=session_bytes,
                index=0,
                seq=seq & 0xFFFF,
                extra=b"\x00\x00",       # poll frames use 0x00 0x00 at [6:7]
            )
            try:
                sock.sendto(req, (lpu_ip, lpu_port))
            except OSError:
                break
            seq += 1
            # Drain the reply (if any) so nothing is left queued.
            try:
                sock.recvfrom(4096)
            except (socket.timeout, OSError):
                pass

    try:
        # 1. Drain any pending inbound data (e.g. trailing show pages).
        sock.settimeout(0.05)
        drained = 0
        try:
            while True:
                data, addr = sock.recvfrom(4096)
                if addr[0] == lpu_ip:
                    drained += 1
        except socket.timeout:
            pass
        except OSError:
            pass
        if drained:
            print(f"  [CLOSE] Drained {drained} pending LPU packet(s)")

        # 2. Resume the normal status-poll loop so the LPU leaves transfer state.
        sock.settimeout(0.05)
        for r in range(poll_rounds):
            send_poll_round()
            time.sleep(0.025)
        print(f"  [CLOSE] Sent {poll_rounds} poll round(s) "
              f"({poll_rounds * len(POLL_CMDS)} status requests)")

        # 3. Hold the session open for keepalive_hold seconds. The keepalive
        #    thread keeps emitting 0xFF at 40 Hz; we additionally fire a status-
        #    poll round every ~2s so the LPU sees the full idle steady-state the
        #    app maintains, keeping the device visible in the reference app.
        if keepalive_hold > 0:
            print(f"  [CLOSE] Holding session alive for {keepalive_hold:.0f}s "
                  f"(keepalive 40 Hz + status poll) ...")
            hold_deadline = time.time() + keepalive_hold
            poll_interval = 2.0
            next_poll = time.time() + poll_interval
            next_report = time.time() + 10.0
            while time.time() < hold_deadline:
                now = time.time()
                if now >= next_poll:
                    send_poll_round()
                    next_poll = now + poll_interval
                if now >= next_report:
                    remaining = hold_deadline - now
                    print(f"  [CLOSE] Keepalive hold -- {remaining:.0f}s remaining ...")
                    next_report = now + 10.0
                time.sleep(0.05)
            print("  [CLOSE] Keepalive hold complete.")

    finally:
        try:
            sock.settimeout(old_timeout)
        except OSError:
            pass
        # 4. Now stop the keepalive thread and let it flush its final send.
        stop_keepalive.set()
        time.sleep(0.05)
        print("  [CLOSE] Keepalive stopped; session is idle.")



# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="LPU VN protocol discovery and session debug tool (v2)"
    )
    parser.add_argument("--ip", metavar="LPU_IP",
                        help="Skip discovery and connect directly to this IP")
    parser.add_argument("--connect", action="store_true",
                        help="After discovery, run session init command sequence")
    parser.add_argument("--download", action="store_true",
                        help="After session init, download the full show (implies --connect)")
    parser.add_argument("--dynamic", action="store_true",
                        help="Query the per-playback DIRECTORY first and derive "
                             "the page plan from it (any size). The page COUNT "
                             "comes entirely from the directory total, so a real "
                             "show of any length downloads completely -- the "
                             "128-page hard cap is NOT applied in this mode. "
                             "Falls back to --pages/--pages-per-pb if the "
                             "directory is empty or unreadable.")
    parser.add_argument("--pages", type=int, default=None,

                        help="Number of linear show pages to download "
                             f"(default: {DEFAULT_SHOW_PAGES}). Bounded -- the "
                             "download walks exactly this many contiguous pages "
                             "and never climbs out of range.")
    parser.add_argument("--base-addr", type=lambda x: int(x, 0), default=None,
                        metavar="HEX",
                        help="IGNORED (kept so old command lines still run). "
                             "There is no flash address in a page request; "
                             "pages are addressed by playback/cue/block.")
    parser.add_argument("--pages-per-pb", default=DEFAULT_SHOW_PAGES_PER_PB,
                        metavar="PB:COUNT,...",
                        help="Per-playback cue counts to download when not "
                             "using --dynamic, e.g. '0:5,1:7,2:6,8:3'.")
    parser.add_argument("--no-metadata", action="store_true",
                        help="Skip the per-page fire-and-forget metadata "
                             "pre-queries (0x05/0x27/0x29/0x2b) before each "
                             "page's download blocks")
    parser.add_argument("--save", metavar="FILE",
                        help="Save downloaded show bytes to FILE")
    parser.add_argument("--log-file", metavar="FILE",
                        help="Log all console output to FILE (default: console only)")
    parser.add_argument("--no-slots", action="store_true",
                        help="Skip cuelist bulk dump + per-slot fader/rotary queries")
    parser.add_argument("--no-bulk-fader", action="store_true",
                        help="Skip bulk fader dump (cmd 0x30) query")
    parser.add_argument("--keepalive-hold", type=float, default=0.6,
                        metavar="SECONDS",
                        help="Short dwell (keepalive + status poll) before "
                             "closing (default: 0.6s). A long hold was a red "
                             "herring; the bounded show download is the real "
                             "fix. Use 0 to close immediately after the poll "
                             "wind-down.")
    parser.add_argument("--dir-debug", action="store_true",
                        help="Print each playback's 0x30 reply (populated, cue "
                             "count, active cue) or the 0x3d fallback "
                             "([DIR-DBG]).")
    args = parser.parse_args()


    # Set up output logging if --log-file specified
    tee = OutputTee(args.log_file)
    sys.stdout = tee

    if args.download:
        args.connect = True

    # Phase 1: Discovery or direct IP
    if args.ip:
        lpu_ip   = args.ip
        lpu_port = int(VN_PORT)
        print(f"[INFO] Using specified LPU IP: {lpu_ip}:{lpu_port}")
    else:
        device = discover_lpu(timeout=DISCOVER_TIMEOUT)
        if device is None:
            print("[ERROR] No LPU found.")
            return
        lpu_ip   = device["ip"]
        lpu_port = int(VN_PORT)
        if not (args.connect or args.download):
            print(f"[DONE] Discovered LPU at {lpu_ip}:{lpu_port} -- use --connect or --download.")
            return

    if not (args.connect or args.download):
        return

    # Phase 1b: Open session -- get session bytes
    result = open_session(lpu_ip, int(lpu_port))
    if result is None:
        print("[ERROR] Failed to open session with LPU.")
        return
    sock, session_bytes = result
    print(f"[SESSION] Got session_bytes: {session_bytes.hex()}")

    # Keepalive at 40 Hz
    stop_keepalive = threading.Event()
    ka_thread = threading.Thread(
        target=keepalive_thread,
        args=(sock, lpu_ip, lpu_port, stop_keepalive),
        daemon=True,
    )
    ka_thread.start()
    print("[SESSION] Keepalive thread started (40 Hz)")

    try:
        # Phase 2: Session init commands
        results = run_session_init(sock, lpu_ip, lpu_port)
        print("\n[SESSION] Init complete.")

        # Phase 2b-i: Bulk fader dump (cmd 0x30 extended, receives 24-byte bursts)
        if not args.no_bulk_fader:
            fader_values = query_bulk_fader_dump(
                sock, lpu_ip, lpu_port,
                session_bytes=session_bytes,
            )
            if fader_values:
                print(f"\n[FADERS] Summary -- {len(fader_values)} channels:")
                for ch in sorted(fader_values):
                    print(f"  ch {ch:3d}: {fader_values[ch]:.4f}")
            else:
                print("[FADERS] No fader values received.")
        else:
            print("[FADERS] Skipping bulk fader dump (--no-bulk-fader)")

        # Phase 2b-ii: Cuelist per-slot queries (9-byte simple format)
        if not args.no_slots:
            # The slot table lives in show page 0; skip separate 0x0a2b query
            # and go straight to per-bank queries (banks 0x01..0x10).
            # Check each bank with cmd (bank<<8)|0x1f (name/fixture).
            # If we get a non-empty string response the slot is populated.
            print("\n[SLOTS] Probing populated slots by querying cmd (bank<<8)|0x1f ...")
            populated = []
            for slot_idx in range(SLOT_COUNT):
                bank = slot_idx + 1
                cmd  = (bank << 8) | 0x1f
                resp = send_command(sock, lpu_ip, lpu_port, cmd, timeout=1.0)
                if resp and len(resp) > 20:
                    name = resp[20:].rstrip(b"\x00").decode("utf-8", errors="replace")
                    if name.strip():
                        populated.append(slot_idx)
                        print(f"  slot {slot_idx:2d}: POPULATED  name='{name[:60]}'")
                    else:
                        print(f"  slot {slot_idx:2d}: empty")
                else:
                    print(f"  slot {slot_idx:2d}: no response")

            if populated:
                slot_data = query_slot_data(sock, lpu_ip, populated, lpu_port)
                print(f"\n[SLOTS] Per-slot query complete for slots: {list(slot_data.keys())}")
            else:
                print("[SLOTS] No populated slots found.")
        else:
            print("[SLOTS] Skipping slot queries (--no-slots)")

        # Phase 3: Show download (BOUNDED -- never climbs out of range)
        if args.download:
            if args.base_addr is not None:
                print("[DOWNLOAD] --base-addr is ignored: pages are addressed "
                      "by playback/cue/block, not by flash address.")
            seq = SeqCounter()

            # Manual/debug plan from --pages / --pages-per-pb (the default path).
            # This path keeps the 128-page hard cap as a safety backstop.
            pages_per_pb = None
            if args.pages_per_pb:
                pages_per_pb = []
                for tok in args.pages_per_pb.split(","):
                    tok = tok.strip()
                    if not tok:
                        continue
                    pb_s, cnt_s = tok.split(":")
                    pages_per_pb.append((int(pb_s, 0), int(cnt_s, 0)))
            num_pages = args.pages if args.pages is not None else DEFAULT_SHOW_PAGES
            max_pages = SHOW_MAX_PAGES_HARD_CAP

            # Dynamic path: read every playback's cue count from the LPU so a
            # show of ANY size downloads completely, released or running. The
            # 128-page hard cap is NOT applied here (max_pages == the total the
            # LPU itself reported, so the walk stays bounded).
            if args.dynamic:
                print("\n[DIRECTORY] Reading cue count of playbacks 1..64 ...")
                dyn_plan, dyn_total = query_directory(
                    sock, lpu_ip, lpu_port, seq,
                    debug=args.dir_debug,
                )

                if dyn_total > 0:
                    pretty = ", ".join(f"pb{pb + 1}:{cnt}" for pb, cnt in dyn_plan)
                    print(f"[DIRECTORY] Populated playbacks -> {{{pretty}}}  "
                          f"total {dyn_total} page(s)")
                    pages_per_pb = dyn_plan
                    num_pages = dyn_total
                    max_pages = dyn_total      # no 128 clamp -- full show
                else:
                    print("[DIRECTORY] Empty/unreadable -- falling back to "
                          "--pages/--pages-per-pb (128-page cap).")

            show_bytes = download_show(
                sock, lpu_ip, lpu_port,
                session_bytes=session_bytes,
                num_pages=num_pages,
                pages_per_pb=pages_per_pb,
                send_metadata=not args.no_metadata,
                max_pages=max_pages,
                seq=seq,
            )
            if show_bytes and args.save:
                with open(args.save, "wb") as f:
                    f.write(show_bytes)
                print(f"[SAVE] Show data written to {args.save} ({len(show_bytes)} bytes)")
            elif show_bytes:
                print(f"\n[SHOW] First 64 bytes: {show_bytes[:64].hex()}")
            else:
                print("[SHOW] No show data received.")

    finally:
        # Graceful wind-down: return the LPU to its idle keepalive+poll
        # steady-state before closing the socket. Closing abruptly right
        # after a paged show download leaves the LPU stuck in transfer
        # state (recoverable only by a power cycle). See VN_PROTOCOL.md
        # section 13. graceful_session_close() also stops the keepalive.
        try:
            graceful_session_close(
                sock, lpu_ip, lpu_port, session_bytes, stop_keepalive,
                keepalive_hold=args.keepalive_hold,
            )

        except Exception as e:
            print(f"[CLOSE] Graceful close failed ({e}); stopping keepalive.")
            stop_keepalive.set()
            time.sleep(0.05)
        sock.close()
        print("[SESSION] Socket closed.")


if __name__ == "__main__":
    main()
