"""VN protocol client for the LPU-1 (UDP 16945).

Typed property frame (FINDINGS.md 20.1), 20-byte header + payload:
    0 object   1 value type   2 property   3 0
    4-5 index1 (fixture / playback)   6-7 index2 (cue)   8-9 index3 (block)
    10-11 ff ff   12-13 payload length   14-15 packet counter   16-19 0
Value types: 0x00 string, 0x01 u32, 0x02 bool, 0x03 float, 0x05 8-byte blob,
0x0a 800-byte page, 0x1d no body (read request / delete / action).
Write id = read id + 1. The LPU echoes every write byte for byte; the real
app sends the next frame only after the echo, and so does this client.

Short device properties (9-byte frames): [00, prop, 0 x6, length, value].
"""

import socket
import struct
import threading
import time

VN_PORT = 16945

T_STR, T_U32, T_BOOL, T_FLOAT, T_BLOB, T_PAGE, T_NOBODY = 0x00, 0x01, 0x02, 0x03, 0x05, 0x0a, 0x1d
OBJ_FIXTURE, OBJ_ACTION, OBJ_PLAYBACK, OBJ_CUE, OBJ_GLOBAL, OBJ_PROG = 0x1f, 0x28, 0x29, 0x2b, 0x2c, 0x2d


class LpuError(RuntimeError):
    pass


def make_frame(op, typ, prop, i1=0, i2=0, i3=0, body=b"", seq=0):
    return struct.pack("<BBBBHHHHHHI", op, typ, prop, 0, i1 & 0xFFFF, i2 & 0xFFFF,
                       i3 & 0xFFFF, 0xFFFF, len(body), seq & 0xFFFF, 0) + body


def parse_frame(data):
    """-> (op, typ, prop, i1, i2, i3, mask, seq, body) or None for non-typed frames."""
    if len(data) < 20:
        return None
    op, typ, prop, _, i1, i2, i3, mask, ln, seq, _ = struct.unpack_from("<BBBBHHHHHHI", data)
    return op, typ, prop, i1, i2, i3, mask, seq, data[20:20 + ln]


def enc_str(s):
    return s.encode("latin1", errors="replace") + b"\0"


def dec_str(b):
    return b.split(b"\0", 1)[0].decode("latin1")


def enc_u32(v):
    return struct.pack("<I", int(v) & 0xFFFFFFFF)


def enc_float(v):
    return struct.pack("<f", float(v))


def dec_value(typ, body):
    t = typ & 0x7F
    if t == T_STR:
        return dec_str(body)
    if t == T_FLOAT and len(body) >= 4:
        return struct.unpack_from("<f", body)[0]
    if t in (T_U32, T_BOOL) and len(body) >= 4:
        return struct.unpack_from("<I", body)[0]
    return bytes(body)


class LpuClient:
    """Lock-step VN client. Use as a context manager.

    Every request waits for its answer before the next one is sent, and every
    read is for an index the caller knows exists, so the LPU is never asked
    for out-of-range data (open-ended reads have wedged the firmware before).
    """

    def __init__(self, ip, port=VN_PORT, timeout=0.6, retries=4, keepalive=True, verbose=False):
        self.addr = (ip, port)
        self.timeout = timeout
        self.retries = retries
        self.verbose = verbose
        self._seq = 0x0100
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.bind(("", 0))
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._ka = None
        if keepalive:
            self._ka = threading.Thread(target=self._keepalive, daemon=True)
            self._ka.start()

    # -- plumbing -----------------------------------------------------------
    def _keepalive(self):
        while not self._stop.is_set():
            try:
                self._sock.sendto(b"\xff", self.addr)
            except OSError:
                return
            self._stop.wait(0.025)

    def _next_seq(self):
        s = self._seq
        self._seq = (self._seq + 1) & 0xFFFF
        return s

    def _exchange(self, frame, match, what):
        with self._lock:
            for attempt in range(self.retries):
                self._sock.sendto(frame, self.addr)
                deadline = time.time() + self.timeout
                while True:
                    left = deadline - time.time()
                    if left <= 0:
                        break
                    self._sock.settimeout(left)
                    try:
                        data, src = self._sock.recvfrom(4096)
                    except socket.timeout:
                        break
                    except ConnectionResetError:
                        continue
                    if src[0] != self.addr[0]:
                        continue
                    if match(data):
                        return data
                if self.verbose:
                    print(f"  retry {attempt + 1} for {what}")
        raise LpuError(f"no answer from LPU {self.addr[0]} for {what}")

    def close(self):
        self._stop.set()
        if self._ka:
            self._ka.join(timeout=0.5)
        time.sleep(0.05)
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # -- typed frames ---------------------------------------------------------
    def read(self, op, prop, i1=0, i2=0, i3=0):
        """Read one property -> (value type, body bytes)."""
        frame = make_frame(op, T_NOBODY, prop, i1, i2, i3, seq=self._next_seq())

        def match(d):
            p = parse_frame(d)
            return (p is not None and p[0] == op and p[2] == prop and p[1] not in (T_NOBODY,)
                    and not p[1] & 0x80 and p[3:6] == (i1, i2, i3) and p[6] == 0xFFFF)

        p = parse_frame(self._exchange(frame, match, f"read {op:02x}/{prop:02x} [{i1},{i2},{i3}]"))
        return p[1], p[8]

    def read_value(self, op, prop, i1=0, i2=0, i3=0):
        typ, body = self.read(op, prop, i1, i2, i3)
        return dec_value(typ, body)

    def read_many(self, requests, window=16, gap=0.0005, optional=False):
        """Read several properties [(op, prop, i1, i2, i3), ...] -> [(type, body), ...].

        Up to `window` reads are in flight at once and sends are `gap` seconds
        apart: one answer takes ~20 ms on Wi-Fi, and back-to-back requests
        make the LPU drop answers (FINDINGS 20.16). Each read is retried on
        its own. Unanswered reads raise LpuError, or give None with
        `optional`. Writes stay lock-step (write()).
        """
        slots = {}                                  # key -> result positions
        for n, r in enumerate(requests):
            slots.setdefault(tuple(r) + (0,) * (5 - len(r)), []).append(n)
        results = [None] * len(requests)
        todo = list(slots)
        inflight = {}                               # key -> [frame, attempts, deadline]
        failed = []
        last = [0.0]

        def send(frame):
            while time.perf_counter() - last[0] < gap:   # time.sleep is too coarse
                pass
            last[0] = time.perf_counter()
            self._sock.sendto(frame, self.addr)

        with self._lock:
            while todo or inflight:
                now = time.time()
                for key, f in list(inflight.items()):
                    if now >= f[2]:
                        if f[1] >= self.retries:
                            del inflight[key]
                            failed.append(key)
                        else:
                            send(f[0])
                            f[1] += 1
                            f[2] = time.time() + self.timeout
                while todo and len(inflight) < window:
                    key = todo.pop(0)
                    op, prop, i1, i2, i3 = key
                    frame = make_frame(op, T_NOBODY, prop, i1, i2, i3, seq=self._next_seq())
                    send(frame)
                    inflight[key] = [frame, 1, time.time() + self.timeout]
                if not inflight:
                    break
                self._sock.settimeout(max(0.001, min(f[2] for f in inflight.values()) - time.time()))
                try:
                    data, src = self._sock.recvfrom(4096)
                except socket.timeout:
                    continue
                except ConnectionResetError:
                    continue
                p = parse_frame(data) if src[0] == self.addr[0] else None
                if p is None or p[1] == T_NOBODY or p[1] & 0x80 or p[6] != 0xFFFF:
                    continue
                key = (p[0], p[2], p[3], p[4], p[5])
                if key in inflight:
                    del inflight[key]
                    for n in slots[key]:
                        results[n] = (p[1], p[8])
        if failed and not optional:
            op, prop, i1, i2, i3 = failed[0]
            raise LpuError(f"no answer from LPU {self.addr[0]} for read {op:02x}/{prop:02x} "
                           f"[{i1},{i2},{i3}]" + (f" (+{len(failed) - 1} more)" if len(failed) > 1 else ""))
        return results

    def write(self, op, typ, prop, i1=0, i2=0, i3=0, body=b""):
        """Send one write (or delete/action with typ 0x1d) and wait for the echo."""
        frame = make_frame(op, typ, prop, i1, i2, i3, body, seq=self._next_seq())
        self._exchange(frame, lambda d: d == frame,
                       f"write {op:02x} {typ:02x} {prop:02x} [{i1},{i2},{i3}]")

    # -- short device properties ----------------------------------------------
    def short_read(self, prop):
        frame = bytes([0, prop]) + bytes(7)

        def match(d):
            return len(d) > 9 and d[0] == 0 and d[1] == prop

        d = self._exchange(frame, match, f"device property 0x{prop:02x}")
        return d[9:9 + d[8]]


def discover(timeout=4.0):
    """Broadcast visual_identify; return a list of (ip, label, firmware)."""
    import xml.etree.ElementTree as ET
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", 0))
    found = {}
    end = time.time() + timeout
    next_send = 0.0
    try:
        while time.time() < end:
            if time.time() >= next_send:
                s.sendto(b"visual_identify", ("255.255.255.255", VN_PORT))
                next_send = time.time() + 1.0
            s.settimeout(0.2)
            try:
                data, src = s.recvfrom(4096)
            except socket.timeout:
                continue
            if not data.startswith(b"<"):
                continue
            try:
                root = ET.fromstring(data.rstrip(b"\0").decode("utf-8", "replace"))
                found[src[0]] = (root.findtext("ip") or src[0], root.get("label", "?"),
                                 root.findtext("version") or "?")
            except ET.ParseError:
                pass
    finally:
        s.close()
    return list(found.values())
