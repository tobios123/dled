"""LPU-1 emulator: a fake device the reference app (and our tools) can talk to.

Implements the behaviour decoded in analysis/FINDINGS.md section 20:
  * discovery: answers "visual_identify" with the identify XML, and broadcasts
    it every second like the real LPU
  * typed frames: every write is echoed byte for byte and stored; reads are
    answered with read id = write id - 1; deletes and actions are echoed
  * packed states 29 30 (playback) and 1f 30 (fixture), short device
    properties (MAC, alias, Art-Net, sACN, ...)
  * live behaviour: GO / FLASH / RELEASE / RELEASE ALL with active-cue and
    cue-phase notifications, swap, insert/delete cue, programmer load/record
  * notifications (bit 7 set, mask 0000) go to every client seen recently

It is an emulator of the protocol, not of the LPU's DMX engine: no DMX is
output and fades/follow timing are not simulated.
"""

import socket
import struct
import threading
import time

from .protocol import VN_PORT, dec_str, enc_str, enc_u32, make_frame, parse_frame
from .showfile import BLOCK_SIZE, GO_MODES, REPEAT_MODES, Cue, Fixture, Playback, Show, decode_record
from .personalities import split_profile

NOTIFY_TTL = 15.0           # seconds a client stays subscribed without traffic

# Empty programmer attribute per index (value type, body): 0 intensity float,
# 1/3/5 FX (4 bytes), 2 position (2 floats), 4 colour (5 x u16), 6-16 floats.
ATTR_DEFAULTS = {1: (0x07, bytes(4)), 2: (0x06, bytes(8)), 3: (0x07, bytes(4)),
                 4: (0x08, bytes(10)), 5: (0x07, bytes(4))}


def attr_default(i):
    return ATTR_DEFAULTS.get(i, (0x03, struct.pack("<f", 0.0)))


def _u32(b):
    return struct.unpack_from("<I", b)[0] if len(b) >= 4 else 0


def _f32(b):
    return struct.unpack_from("<f", b)[0] if len(b) >= 4 else 0.0


class LpuState:
    def __init__(self, show=None, alias="LPU", ip="127.0.0.1"):
        show = show or Show()
        self.fixtures = {f.index: f for f in show.fixtures}
        self.playbacks = {p.index: p for p in show.playbacks}
        self.alias = alias
        self.ip = ip
        self.mac = bytes.fromhex("020000000002")
        self.artnet_universe = 0          # raw (UI x 16)
        self.artnet_enabled = 0
        self.sacn_universe = 1
        self.sacn_enabled = 0
        self.active = {}                  # pb -> active cue index
        self.selection = bytes(8)
        self.choose_mode = 0
        self.edit_pb = 0
        self.attrs = {}                   # programmer attr -> (type, body)
        self.lock = threading.RLock()

    # -- snapshots ------------------------------------------------------------
    def to_show(self):
        show = Show(device={"type": "LPU-1", "firmware_version": "1.29", "pcb_version": "2.0",
                            "ip": self.ip, "mac": ":".join(f"{b:02X}" for b in self.mac),
                            "subnet": "255.255.255.0", "dhcp": "true"})
        show.fixtures = [self.fixtures[i] for i in sorted(self.fixtures)]
        show.playbacks = [self.playbacks[i] for i in sorted(self.playbacks)]
        return show

    def pb(self, i):
        if i not in self.playbacks:
            self.playbacks[i] = Playback(index=i)
        return self.playbacks[i]

    def fixture_state(self, i):
        f = self.fixtures.get(i)
        if f is None:
            return 0xFFFF0000
        codes = split_profile(f.profile)
        flags = 0
        if 0x02 in codes or 0x03 in codes:          # the LPU ignores flags without pan/tilt
            flags = bool(f.invert_pan) * 1 | bool(f.invert_tilt) * 2 | bool(f.swap_pan_tilt) * 4
        return (f.address & 0xFFFF) << 16 | flags

    def playback_state(self, i):
        p = self.playbacks.get(i)
        if p is None:
            return bytes([0, 0, 0, 0xFF])
        go = GO_MODES.index(p.gomode) if p.gomode in GO_MODES else 0
        rep = REPEAT_MODES.index(p.repeat) if p.repeat in REPEAT_MODES else 0
        active = self.active.get(i)
        state = 3 if active is not None else (1 if p.cues else 0)
        return bytes([go << 4 | p.exclusive << 1 | p.background, rep << 4 | state,
                      len(p.cues) & 0xFF, 0xFF if active is None else active])

    def next_address(self, nch):
        used = sorted((f.address, f.address + len(split_profile(f.profile)) - 1)
                      for f in self.fixtures.values() if f.address < 0xFFFF)
        addr = 1
        for lo, hi in used:
            if addr + nch - 1 < lo:
                break
            addr = max(addr, hi + 1)
        return addr if addr + nch - 1 <= 512 else 1


class LpuEmulator:
    def __init__(self, state=None, bind_ip="0.0.0.0", port=VN_PORT, log=print, verbose=False):
        self.state = state or LpuState()
        self.log = log
        self.verbose = verbose
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind((bind_ip, port))
        self.clients = {}
        self.other_lpus = set()       # real LPUs on the network: never answer them
        self._stop = threading.Event()
        self._threads = []

    # -- lifecycle ----------------------------------------------------------------
    def start(self, announce=True):
        t = threading.Thread(target=self._serve, daemon=True)
        t.start()
        self._threads.append(t)
        if announce:
            a = threading.Thread(target=self._announce, daemon=True)
            a.start()
            self._threads.append(a)
        return self

    def stop(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass

    def identify_xml(self):
        s = self.state
        return (f'<?xml version="1.0" ?> <visual_identify label="LPU-1"> <version>1.29</version> '
                f'<os>Embedded</os> <ip>{s.ip}</ip> <port>{self.port}</port> </visual_identify>'
                ).encode() + b"\0"

    def _announce(self):
        try:                                              # real LPUs answer; see _serve
            self.sock.sendto(b"visual_identify", ("255.255.255.255", self.port))
        except OSError:
            pass
        while not self._stop.wait(1.0):
            try:
                self.sock.sendto(self.identify_xml(), ("255.255.255.255", self.port))
            except OSError:
                pass

    # -- io -----------------------------------------------------------------------
    def _send(self, data, addr):
        try:
            self.sock.sendto(data, addr)
        except OSError:
            pass

    def notify(self, op, typ, prop, i1=0, i2=0, i3=0, body=b""):
        frame = bytearray(make_frame(op, typ | 0x80, prop, i1, i2, i3, body))
        frame[10:12] = b"\0\0"
        now = time.time()
        for addr, seen in list(self.clients.items()):
            if now - seen < NOTIFY_TTL:
                self._send(bytes(frame), addr)

    def changed(self, op, i1=0, i2=0, code=0x121):
        self.notify(op, 0x01, 0x00, i1, i2, body=enc_u32(code))

    def _serve(self):
        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(4096)
            except (socket.timeout, ConnectionResetError):
                continue
            except OSError:
                return
            if data.startswith(b"<?xml") and b"visual_identify" in data:
                if f"<ip>{self.state.ip}</ip>".encode() not in data:
                    self.other_lpus.add(addr[0])          # another (real) LPU
                continue
            # A real LPU's replies look like writes; echoing them starts an endless
            # echo loop with it (seen 2026-10-23). Same for our own frames.
            if addr[0] in self.other_lpus or addr == self.sock.getsockname():
                continue
            self.clients[addr] = time.time()
            try:
                self._handle(data, addr)
            except Exception as e:                        # never die on a bad frame
                self.log(f"[emulator] error on {data[:24].hex(' ')}: {e}")

    def _handle(self, data, addr):
        if data == b"\xff":
            return
        if data.startswith(b"visual_identify"):
            self._send(self.identify_xml(), addr)
            return
        if len(data) < 20 and data[:1] == b"\0":
            self._short(data, addr)
            return
        p = parse_frame(data)
        if p is None:
            return
        op, typ, prop, i1, i2, i3, mask, seq, body = p
        if typ & 0x80:                                    # a notification: not for us
            return
        with self.state.lock:
            if typ == 0x1d:
                self._request(op, prop, i1, i2, i3, seq, data, addr)
            else:
                self._send(data, addr)                    # echo every write
                self._write(op, typ, prop, i1, i2, i3, body)
        if self.verbose:
            self.log(f"[emulator] {addr[0]}:{addr[1]} {data[:3].hex(' ')} [{i1},{i2},{i3}]")

    # -- short device properties --------------------------------------------------
    def _short(self, data, addr):
        s = self.state
        prop = data[1]
        if len(data) > 9:                                  # write
            value = data[9:9 + data[8]]
            if prop == 0x12:
                s.alias = value.split(b"\0")[0].decode("latin1")
                self.notify(0x02, 0x01, 0x00, body=enc_u32(0))
            self._send(data, addr)
            return
        u = lambda v: struct.pack("<I", v)
        values = {0x00: s.mac, 0x03: bytes([255, 255, 255, 0, 0, 0]), 0x09: bytes([1, 29]),
                  0x0a: bytes([2, 0]), 0x11: s.alias.encode("latin1") + b"\0",
                  0x34: u(s.artnet_universe), 0xce: u(s.artnet_enabled), 0xea: u(1),
                  0xef: u(s.sacn_enabled), 0xf0: u(s.sacn_universe)}
        v = values.get(prop, u(0))
        self._send(bytes([0, prop]) + bytes(6) + bytes([len(v)]) + v, addr)

    # -- reads / deletes / actions --------------------------------------------------
    def _reply(self, addr, op, typ, prop, i1, i2, i3, seq, body):
        self._send(make_frame(op, typ, prop, i1, i2, i3, body, seq), addr)

    def _request(self, op, prop, i1, i2, i3, seq, raw, addr):
        s = self.state
        r = lambda typ, body: self._reply(addr, op, typ, prop, i1, i2, i3, seq, body)
        f = s.fixtures.get(i1) if op == 0x1f else None
        if prop == 0x38 and op in (0x1f, 0x29, 0x2c):        # delete / reset
            self._send(raw, addr)
            if op == 0x1f and i1 in s.fixtures:
                del s.fixtures[i1]
                self.notify(0x1f, 0x00, 0x07, i1, body=enc_str('"","","",""'))
                self.changed(0x1f, i1, code=0x121)
            elif op == 0x29 and i1 in s.playbacks:
                del s.playbacks[i1]
                s.active.pop(i1, None)
                self.changed(0x29, i1, code=0x121)
            elif op == 0x2c:
                # CLEAR the programmer (the reference app's CLEAR button, captured
                # 2026-10-24; also the first frame of an upload). The show stays.
                s.attrs = {}
                for a in range(17):
                    typ, body = attr_default(a)
                    self.notify(0x2c, typ, 0x32, a, body=body)
                self.notify(0x2c, 0x02, 0x45, body=enc_u32(0))
            return
        if op == 0x1f:
            if prop == 0x05:
                return r(0x00, enc_str((f.name or "") if f else ""))
            if prop == 0x07:
                return r(0x00, enc_str(f.definition if f else '"","","",""'))
            if prop == 0x0b:
                return r(0x01, enc_u32(f.address if f else 0xFFFF))
            if prop == 0x30:
                return r(0x01, enc_u32(s.fixture_state(i1)))
            flags = {0x0d: "invert_pan", 0x0f: "invert_tilt", 0x11: "swap_pan_tilt", 0x13: "virtual_dimmer"}
            if prop in flags:
                return r(0x02, enc_u32(int(bool(f and getattr(f, flags[prop])))))
        if op == 0x29:
            p = s.playbacks.get(i1)
            if prop == 0x30:
                return r(0x01, s.playback_state(i1))
            if prop == 0x05:
                return r(0x00, enc_str(p.label if p else ""))
            if prop == 0x17:
                return r(0x03, struct.pack("<f", p.intensity if p else 1.0))
            if prop == 0x15:
                return r(0x03, struct.pack("<f", p.speed if p else 0.0))
            if prop == 0x3d:
                return r(0x01, enc_u32(len(p.cues) if p else 0))
            if prop == 0x2d:
                return r(0x01, enc_u32(REPEAT_MODES.index(p.repeat) if p and p.repeat in REPEAT_MODES else 0))
            if prop == 0x1d:
                return r(0x02, enc_u32(int(bool(p and p.background))))
            if prop == 0x39:
                return r(0x02, enc_u32(int(bool(p and p.exclusive))))
            if prop == 0x42:                                   # release one playback
                self._send(raw, addr)
                return self._release(i1)
            if prop == 0x04:                                   # delete cues
                self._send(raw, addr)
                if p:
                    gone = range(i2, min(len(p.cues), i2 + max(1, i3)))
                    del p.cues[i2:i2 + max(1, i3)]
                    self._playback_changed(i1)
                    # Like the real LPU: the deleted cues are announced as
                    # changed too (and reads of them get no answer, below).
                    for q in gone:
                        self.changed(0x2b, i1, q, code=0x121)
                return
        if op == 0x2b:
            p = s.playbacks.get(i1)
            c = p.cues[i2] if p and i2 < len(p.cues) else None
            if c is None and prop in (0x46, 0x05, 0x27, 0x29, 0x2b):
                return  # the real LPU does not answer reads of cues that do not exist

            if prop == 0x46:
                return r(0x0a, c.block(i3) if c else bytes(BLOCK_SIZE))
            if prop == 0x05:
                return r(0x00, enc_str(c.label if c else ""))
            if prop == 0x27:
                return r(0x01, enc_u32(int(bool(c and c.follow))))
            if prop == 0x29:
                return r(0x01, enc_u32(c.fade_ms if c else 0))
            if prop == 0x2b:
                return r(0x01, enc_u32(c.delay_ms if c else 0))
        if op == 0x2c:
            if prop == 0x34:
                return r(0x01, enc_u32(s.choose_mode))
            if prop == 0x3e:
                return r(0x01, enc_u32(s.edit_pb))
            if prop == 0x3b:
                return r(0x05, s.selection)
            if prop == 0x45:
                return r(0x02, enc_u32(int(bool(s.attrs))))
            # LOAD / RECORD only while the edited playback (3f) is 0-63: else
            # the LPU drops LOAD unanswered and records nothing (2026-10-28)
            if prop == 0x36:                                   # load cue into programmer
                if s.edit_pb >= 64:
                    return
                self._load_cue(i1, i2)
                return self._send(raw, addr)                   # the echo after the values
            if prop == 0x37:                                   # record programmer into cue
                self._send(raw, addr)
                return self._record_cue(i1, i2) if s.edit_pb < 64 else None
        if op == 0x2d and prop == 0x32:
            typ, body = s.attrs.get(i1, attr_default(i1))
            return r(typ, body)
        if op in (0x0a, 0x0b):
            en, uni = ((s.artnet_enabled, s.artnet_universe) if op == 0x0a
                       else (s.sacn_enabled, s.sacn_universe))
            if prop == 0x25:
                return r(0x02, enc_u32(en))
            if prop == 0x32:
                return r(0x01, enc_u32(uni))
        if op == 0x28:
            if prop == 0x4f:
                return r(0x02, enc_u32(0))
            if prop == 0x42:                                   # release all
                self._send(raw, addr)
                for pb in list(s.active):
                    self._release(pb)
                return
            if prop == 0x49:                                   # swap playbacks i1 <-> i2
                self._send(raw, addr)
                a, b = s.playbacks.pop(i1, None), s.playbacks.pop(i2, None)
                if a:
                    a.index = i2
                    s.playbacks[i2] = a
                if b:
                    b.index = i1
                    s.playbacks[i1] = b
                self._playback_changed(i1)
                self._playback_changed(i2)
                return
        self._send(raw, addr)                                  # unknown: echo like the LPU

    # -- writes -------------------------------------------------------------------
    def _write(self, op, typ, prop, i1, i2, i3, body):
        s = self.state
        u = _u32(body)
        if op == 0x1f:
            if prop == 0x08:
                parts = [x.strip('"') for x in dec_str(body).split('","')]
                if len(parts) == 4:
                    old = s.fixtures.get(i1)
                    nch = len(split_profile(parts[3]))
                    addr = old.address if old else s.next_address(nch)
                    keep = {k: getattr(old, k) for k in ("name", "invert_pan", "invert_tilt",
                                                         "swap_pan_tilt", "virtual_dimmer")} if old else {}
                    s.fixtures[i1] = Fixture(index=i1, address=addr, manufacturer=parts[0],
                                             model=parts[1][:29], mode=parts[2], profile=parts[3],
                                             **keep)
                    self.changed(0x1f, i1, code=0x14)
                    self.notify(0x1f, 0x00, 0x07, i1, body=enc_str(s.fixtures[i1].definition))
                return
            f = s.fixtures.get(i1)
            if f is None:
                return
            if prop == 0x0c:
                f.address = u
            elif prop == 0x06:
                f.name = dec_str(body)
                self.changed(0x1f, i1)
            elif prop in (0x0e, 0x10, 0x12, 0x14):
                setattr(f, {0x0e: "invert_pan", 0x10: "invert_tilt", 0x12: "swap_pan_tilt",
                            0x14: "virtual_dimmer"}[prop], bool(u))
                if prop == 0x14:
                    self.notify(0x1f, 0x02, 0x13, i1, body=enc_u32(u))
            return
        if op == 0x29:
            if prop == 0x48:                                   # cue count (allocates)
                p = s.pb(i1)
                p.cues = p.cues[:u] + [Cue() for _ in range(u - len(p.cues))]
                self.notify(0x29, 0x01, 0x24, i1, body=enc_u32(1))
                self.changed(0x29, i1, code=3)
                return
            if prop == 0x03:                                   # insert cue
                p = s.pb(i1)
                pos = len(p.cues) if u == 0xFFFFFFFF or u > len(p.cues) else u
                # the LPU's new cue: fade 2 s, delay 2 s, follow on (read back 2026-10-28)
                p.cues.insert(pos, Cue(label="", fade_ms=2000, delay_ms=2000, follow=True))
                self._playback_changed(i1)
                return
            p = s.pb(i1)
            if prop == 0x06:
                p.label = dec_str(body)
                self.changed(0x29, i1)
            elif prop == 0x18:
                p.intensity = _f32(body)
                self.notify(0x29, 0x03, 0x17, i1, body=body[:4])
            elif prop == 0x16:
                p.speed = _f32(body)
                self.notify(0x29, 0x03, 0x15, i1, body=body[:4])
            elif prop == 0x21:
                p.gomode = GO_MODES[u] if u < 4 else "Go"
                self.changed(0x29, i1, code=0x79)
            elif prop == 0x2e:
                p.repeat = REPEAT_MODES[u] if u < 4 else "Loop"
                self.changed(0x29, i1, code=0x123)
            elif prop == 0x1e:
                p.background = bool(u)
                self.notify(0x29, 0x02, 0x1d, i1, body=enc_u32(u))
            elif prop == 0x3a:
                p.exclusive = bool(u)
                self.changed(0x29, i1, code=0x2e)
            elif prop == 0x22:
                self._go(i1, bool(u))
            elif prop == 0x23:
                self._flash(i1, bool(u))
            return
        if op == 0x2b:
            p = s.pb(i1)
            while len(p.cues) <= i2:
                p.cues.append(Cue())
            c = p.cues[i2]
            if prop == 0x47:
                blocks = list(c.blocks) + [b""] * (4 - len(c.blocks))
                blocks[i3] = bytes(body[:BLOCK_SIZE]) if any(body) else b""
                c.blocks = blocks[:4]
                if any(body):
                    self.changed(0x2b, i1, i2, code=0x128)
            elif prop in (0x06, 0x2a, 0x2c, 0x28):
                # several selected cues at once: i3 = how many from cue i2 on
                # (the reference app, 2026-10-28)
                for q in range(i2, min(len(p.cues), i2 + max(i3, 1))):
                    cq = p.cues[q]
                    if prop == 0x06:
                        cq.label = dec_str(body)
                        self.changed(0x2b, i1, q)
                    elif prop == 0x2a:
                        cq.fade_ms = u
                        self.changed(0x2b, i1, q, code=0x1a)
                    elif prop == 0x2c:
                        cq.delay_ms = u
                        self.changed(0x2b, i1, q, code=0x36)
                    else:
                        cq.follow = bool(u)
                        self.changed(0x2b, i1, q, code=0x5a)
            return
        if op == 0x2c:
            if prop == 0x3c:
                s.selection = bytes(body[:8]).ljust(8, b"\0")
                self.notify(0x2c, 0x05, 0x3b, body=s.selection)
            elif prop == 0x35:
                s.choose_mode = u
                self.changed(0x2c, code=0x126)
            elif prop == 0x3f:
                s.edit_pb = u
                self.changed(0x2c, code=0x190)
            return
        if op == 0x2d and prop == 0x33:
            s.attrs[i1] = (typ, bytes(body))
            self.notify(0x2d, typ, 0x32, i1, body=body)
            return
        if op in (0x0a, 0x0b):
            art = op == 0x0a
            if prop == 0x26:
                if art:
                    s.artnet_enabled = u
                else:
                    s.sacn_enabled = u
                self.changed(op, code=0x13)
            elif prop == 0x33:
                if art:
                    s.artnet_universe, s.artnet_enabled = u, 1
                else:
                    s.sacn_universe, s.sacn_enabled = u, 1
                self.changed(op, code=0x13)
                self.changed(op, code=0x17)

    # -- live playback behaviour ------------------------------------------------------
    def _phase(self, pb, phase):
        self.notify(0x29, 0x01, 0x24, pb, body=enc_u32(phase))

    def _activate(self, pb, cue):
        self.state.active[pb] = cue
        self.notify(0x29, 0x01, 0x2f, pb, body=enc_u32(cue))
        self._phase(pb, 2)
        self._phase(pb, 3)

    def _release(self, pb):
        if self.state.active.pop(pb, None) is None:
            return
        self._phase(pb, 4)
        self.notify(0x29, 0x01, 0x2f, pb, body=enc_u32(0xFF))
        self._phase(pb, 1)

    def _go(self, pb, pressed):
        p = self.state.playbacks.get(pb)
        self.notify(0x29, 0x02, 0x50, pb, body=enc_u32(int(pressed)))
        if pressed or not p or not p.cues:
            return
        cur = self.state.active.get(pb)
        self._activate(pb, 0 if cur is None else (cur + 1) % len(p.cues))

    def _flash(self, pb, pressed):
        p = self.state.playbacks.get(pb)
        if not p or not p.cues:
            return
        if pressed and pb not in self.state.active:
            self._activate(pb, 0)
            self._flashed = getattr(self, "_flashed", set()) | {pb}
        elif not pressed and pb in getattr(self, "_flashed", set()):
            self._flashed.discard(pb)
            self._release(pb)

    def _playback_changed(self, pb):
        p = self.state.playbacks.get(pb)
        self.changed(0x29, pb, code=3)
        self.notify(0x29, 0x01, 0x3d, pb, body=enc_u32(len(p.cues) if p else 0))

    # -- programmer -------------------------------------------------------------------
    def _load_cue(self, pb, cue):
        s = self.state
        p = s.playbacks.get(pb)
        c = p.cues[cue] if p and cue < len(p.cues) else None
        sel = 0
        rec = None
        for f in sorted(s.fixtures):
            if c and not c.record(f).empty:
                sel |= 1 << f
                rec = rec or c.record(f)
        s.attrs = {}
        if rec is not None:
            s.attrs = {
                0: (0x03, struct.pack("<f", rec.intensity / 65535)),
                1: (0x07, bytes(rec.fx_intensity)),
                2: (0x06, struct.pack("<2f", (rec.pan - 32767) / 32767, (rec.tilt - 32767) / 32767)),
                3: (0x07, bytes(rec.fx_position)),
                4: (0x08, struct.pack("<5H", *rec.rgbaw)),
                5: (0x07, bytes(rec.fx_colour)),
            }
        for a in range(17):
            typ, body = s.attrs.get(a, attr_default(a))
            self.notify(0x2c, typ, 0x32, a, body=body)
        self.notify(0x2c, 0x02, 0x45, body=enc_u32(int(bool(s.attrs))))
        s.selection = sel.to_bytes(8, "little")

    def _record_cue(self, pb, cue):
        s = self.state
        p = s.pb(pb)
        if cue >= len(p.cues):                         # the LPU only records into a cue that exists
            return
        c = p.cues[cue]
        sel = int.from_bytes(s.selection, "little")
        blocks = [bytearray(c.block(b)) for b in range(4)]
        get = lambda a, default: s.attrs.get(a, (None, default))[1]
        for f in range(64):
            if not sel >> f & 1:
                continue
            b, r = divmod(f, 16)
            rec = blocks[b]
            o = r * 50
            rec[o:o + 4] = get(1, bytes(4))[:4]
            rec[o + 4:o + 8] = get(3, bytes(4))[:4]
            rec[o + 8:o + 12] = get(5, bytes(4))[:4]
            # records are little-endian, pan / tilt signed (-1..+1 -> -32767..32767)
            pan, tilt = struct.unpack("<2f", get(2, struct.pack("<2f", 0.0, 0.0))[:8])
            struct.pack_into("<hh", rec, o + 12, *(max(-32767, min(32767, round(v * 32767)))
                                                   for v in (pan, tilt)))
            inten = struct.unpack("<f", get(0, struct.pack("<f", 0.0))[:4])[0]
            struct.pack_into("<H", rec, o + 16, max(0, min(65535, int(inten * 65535))))
            colour = struct.unpack("<5H", get(4, bytes(10))[:10])
            struct.pack_into("<5H", rec, o + 20, *colour)
        c.blocks = [bytes(x) if any(x) else b"" for x in blocks]
        self.changed(0x2b, pb, cue, code=0x6b)
        self.changed(0x2b, pb, cue, code=0x128)


def run(show=None, bind_ip="0.0.0.0", ip=None, port=VN_PORT, alias="LPU", verbose=False, log=print):
    """Start an emulator in background threads and return it."""
    if ip is None:
        ip = _local_ip() if bind_ip == "0.0.0.0" else bind_ip
    state = LpuState(show, alias=alias, ip=ip)
    return LpuEmulator(state, bind_ip=bind_ip, port=port, log=log, verbose=verbose).start(
        announce=bind_ip != "127.0.0.1")


def _local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()
