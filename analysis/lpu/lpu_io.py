"""Download a whole show from an LPU, or upload a Show to it.

Download (what the reference app does on connect, FINDINGS 20.7/20.8):
  device:    short properties 0x00 MAC, 0x03 subnet, 0x09 firmware, 0x0a PCB,
             0x11 alias, 0x34 Art-Net universe (UI x 16), 0xce/0xef Art-Net/sACN
             enabled, 0xf0 sACN universe
  fixtures:  per slot 0-63: 1f 30 state (address << 16 | pan/tilt flags),
             1f 07 definition, 1f 05 name, 1f 13 virtual dimmer
  playbacks: per slot 0-63: 29 30 packed state, 29 05 label, 29 17 intensity,
             29 15 speed
  cues:      per existing cue: 2b 05 label, 27 condition, 29 fade, 2b delay,
             46 blocks 0-3
Only indexes the LPU itself reported are read, so the walk never leaves the
valid range.

Upload (what the reference app does when it opens a .show, VN_PROTOCOL.md 12):
  28 1d 42 release all (our addition, FINDINGS 20.13), 2c 1d 38 reset,
  2c 05 3c clear selection, then for slots 0-63 either the
  fixture/playback writes or a delete, every frame lock-step on its echo.
"""

import struct

from .protocol import (OBJ_ACTION, OBJ_CUE, OBJ_FIXTURE, OBJ_GLOBAL, OBJ_PLAYBACK, T_BLOB, T_BOOL,
                       T_FLOAT, T_NOBODY, T_PAGE, T_STR, T_U32, VN_PORT, LpuClient, LpuError, dec_str,
                       dec_value, enc_float, enc_str, enc_u32)
from .personalities import split_profile
from .showfile import BLOCK_SIZE, GO_MODES, REPEAT_MODES, Cue, Fixture, Playback, Show

SLOTS = 64


def _u32(b):
    return struct.unpack_from("<I", b)[0] if len(b) >= 4 else 0


def parse_definition(s):
    """'"Mfr","Model","Mode","PROFILE"' -> 4 strings (or None if empty)."""
    parts = [p.strip().strip('"') for p in s.split('","')]
    parts = [p.strip('"') for p in parts]
    if len(parts) != 4 or not any(parts):
        return None
    return parts


# --- download ---------------------------------------------------------------------
def read_device(c, show, log=print):
    d = {}
    try:
        mac = c.short_read(0x00)
        d["mac"] = ":".join(f"{b:02X}" for b in mac)
        sub = c.short_read(0x03)
        d["subnet"] = ".".join(str(b) for b in sub[:4])
        fw = c.short_read(0x09)
        d["firmware_version"] = f"{fw[0]}.{fw[1]:02d}" if len(fw) >= 2 else ""
        pcb = c.short_read(0x0a)
        d["pcb_version"] = f"{pcb[0]}.{pcb[1]}" if len(pcb) >= 2 else ""
        show.extra["alias"] = dec_str(c.short_read(0x11))
        art = _u32(c.short_read(0x34))
        show.extra["Art-Net"] = (f"{'enabled' if _u32(c.short_read(0xce)) else 'disabled'}, "
                                 f"universe {art // 16} (raw {art})")
        show.extra["sACN"] = (f"{'enabled' if _u32(c.short_read(0xef)) else 'disabled'}, "
                              f"universe {_u32(c.short_read(0xf0))}")
    except Exception as e:                      # device info is optional
        log(f"  device info incomplete: {e}")
    d["ip"] = c.addr[0]
    d["type"] = "LPU-1"
    show.device = d


# The reads are made in batches (LpuClient.read_many: several in flight, FINDINGS
# 20.16) - 0.6 s instead of ~17 s for a typical show on Wi-Fi. Results keep
# their slot / cue order, so the .show is the same as one read at a time.

def _val(r):
    return dec_value(*r)


def read_fixtures(c, show, log=print):
    states = [_u32(r[1]) for r in c.read_many([(OBJ_FIXTURE, 0x30, i) for i in range(SLOTS)])]
    patched = [i for i in range(SLOTS) if states[i] >> 16 != 0xFFFF]
    info = c.read_many([(OBJ_FIXTURE, prop, i) for i in patched for prop in (0x07, 0x05)])
    vdim = c.read_many([(OBJ_FIXTURE, 0x13, i) for i in patched], optional=True)
    for n, i in enumerate(patched):
        parts = parse_definition(dec_str(info[2 * n][1]))
        if not parts:
            continue
        state = states[i]
        f = Fixture(index=i, address=state >> 16, manufacturer=parts[0], model=parts[1],
                    mode=parts[2], profile=parts[3])
        f.name = _val(info[2 * n + 1]) or ""
        f.invert_pan = bool(state & 1)
        f.invert_tilt = bool(state & 2)
        f.swap_pan_tilt = bool(state & 4)
        if vdim[n] is not None:
            f.virtual_dimmer = bool(_val(vdim[n]))
        show.fixtures.append(f)
    log(f"  fixtures: {len(show.fixtures)} patched")


def read_playbacks(c, show, log=print, progress=None):
    head = c.read_many([(OBJ_PLAYBACK, prop, p) for p in range(SLOTS) for prop in (0x30, 0x05, 0x17, 0x15)])
    found = []
    for p in range(SLOTS):
        body = head[4 * p][1]
        b0, b1, count, _active = body[:4] if len(body) >= 4 else (0, 0, 0, 0xFF)
        label = _val(head[4 * p + 1]) or ""
        intensity = _val(head[4 * p + 2])
        speed = _val(head[4 * p + 3])
        gomode, repeat = b0 >> 4, b1 >> 4
        state = b1 & 0x0F
        pb = Playback(index=p, label=label, intensity=intensity, speed=speed,
                      gomode=GO_MODES[gomode] if gomode < 4 else "Go",
                      repeat=REPEAT_MODES[repeat] if repeat < 4 else "Loop",
                      background=bool(b0 & 1), exclusive=bool(b0 & 2))
        nondefault = (label or abs(intensity - 1) > 1e-6 or abs(speed) > 1e-6 or gomode
                      or repeat or pb.background or pb.exclusive)
        if not (state or count or nondefault):
            continue
        found.append((pb, count))
    # all cues of all playbacks in one batch: label, condition, fade, delay, 4 blocks
    cue_props = [(0x05, 0), (0x27, 0), (0x29, 0), (0x2b, 0), (0x46, 0), (0x46, 1), (0x46, 2), (0x46, 3)]
    reqs = [(OBJ_CUE, prop, pb.index, q, b) for pb, count in found for q in range(count) for prop, b in cue_props]
    res = c.read_many(reqs)
    n = 0
    for pb, count in found:
        for q in range(count):
            r = res[n:n + 8]
            n += 8
            cue = Cue(label=_val(r[0]) or "", follow=bool(_val(r[1])),
                      fade_ms=_val(r[2]), delay_ms=_val(r[3]))
            cue.blocks = [bytes(x[1]) if any(x[1]) else b"" for x in r[4:]]
            pb.cues.append(cue)
            if progress:
                progress(pb.index, q, count)
        show.playbacks.append(pb)
    log(f"  playbacks: {len(show.playbacks)}, cues: {sum(len(x.cues) for x in show.playbacks)}")


def download(ip, port=VN_PORT, log=print, verbose=False, progress=None):
    show = Show(application="DLED", version="1.19.0")
    with LpuClient(ip, port=port, verbose=verbose) as c:
        log(f"Reading show from LPU {ip} ...")
        read_device(c, show, log)
        read_fixtures(c, show, log)
        read_playbacks(c, show, log, progress)
    return show


# --- upload -------------------------------------------------------------------------
def upload(ip, show, port=VN_PORT, log=print, verbose=False, progress=None):
    """Write `show` to the LPU, replacing everything on it."""
    # A cue count above 48 hangs the LPU (no answers, no DMX, until a power
    # cycle; lpd/DMX_ENGINE.md 12): refuse before anything is sent.
    for pb in show.playbacks:
        if len(pb.cues) > 48:
            raise LpuError(f"playback {pb.index + 1} has {len(pb.cues)} cues; the LPU takes at most 48")
    with LpuClient(ip, port=port, verbose=verbose) as c:
        w = c.write
        # RELEASE ALL first: replacing the show under running playbacks can
        # leave the LPU stuck in "releasing" until a power cycle (FINDINGS 20.13).
        w(OBJ_ACTION, T_NOBODY, 0x42)
        w(OBJ_GLOBAL, T_NOBODY, 0x38)                       # CLEAR programmer (FINDINGS 20.17)
        w(OBJ_GLOBAL, T_BLOB, 0x3c, body=bytes(8))          # clear fixture selection
        fixtures = {f.index: f for f in show.fixtures}
        for i in range(SLOTS):
            f = fixtures.get(i)
            if f is None:
                w(OBJ_FIXTURE, T_NOBODY, 0x38, i)
                continue
            w(OBJ_FIXTURE, T_STR, 0x08, i, body=enc_str(f.definition))
            w(OBJ_FIXTURE, T_U32, 0x0c, i, body=enc_u32(f.address))
            # Name and patch flags come from the .show (<fixture label=..
            # invert_pan=.. ..>; absent = empty/off, as the app writes them).
            # Always written so the LPU matches the file.
            w(OBJ_FIXTURE, T_STR, 0x06, i, body=enc_str(f.name or ""))
            for prop, on in ((0x0e, f.invert_pan), (0x10, f.invert_tilt),
                             (0x12, f.swap_pan_tilt), (0x14, f.virtual_dimmer)):
                w(OBJ_FIXTURE, T_BOOL, prop, i, body=enc_u32(1 if on else 0))
        log(f"  fixtures written: {len(fixtures)}")
        playbacks = {p.index: p for p in show.playbacks}
        frames = 0
        for p in range(SLOTS):
            pb = playbacks.get(p)
            if pb is None:
                w(OBJ_PLAYBACK, T_NOBODY, 0x38, p)
                continue
            w(OBJ_PLAYBACK, T_U32, 0x48, p, body=enc_u32(len(pb.cues)))
            for q, cue in enumerate(pb.cues):
                for b in range(4):
                    w(OBJ_CUE, T_PAGE, 0x47, p, q, b, body=cue.block(b)[:BLOCK_SIZE])
                    frames += 1
                w(OBJ_CUE, T_STR, 0x06, p, q, body=enc_str(cue.label))
                w(OBJ_CUE, T_U32, 0x2a, p, q, body=enc_u32(cue.fade_ms))
                w(OBJ_CUE, T_U32, 0x2c, p, q, body=enc_u32(cue.delay_ms))
                w(OBJ_CUE, T_U32, 0x28, p, q, body=enc_u32(1 if cue.follow else 0))
                if progress:
                    progress(p, q, len(pb.cues))
            w(OBJ_PLAYBACK, T_STR, 0x06, p, body=enc_str(pb.label))
            w(OBJ_PLAYBACK, T_FLOAT, 0x18, p, body=enc_float(pb.intensity))
            w(OBJ_PLAYBACK, T_FLOAT, 0x16, p, body=enc_float(pb.speed))
            w(OBJ_PLAYBACK, T_U32, 0x21, p, body=enc_u32(GO_MODES.index(pb.gomode)
                                                           if pb.gomode in GO_MODES else 0))
            w(OBJ_PLAYBACK, T_U32, 0x2e, p, body=enc_u32(REPEAT_MODES.index(pb.repeat)
                                                           if pb.repeat in REPEAT_MODES else 0))
            w(OBJ_PLAYBACK, T_BOOL, 0x1e, p, body=enc_u32(1 if pb.background else 0))
            w(OBJ_PLAYBACK, T_BOOL, 0x3a, p, body=enc_u32(1 if pb.exclusive else 0))
        log(f"  playbacks written: {len(playbacks)} ({frames} cue blocks)")


# --- compare ------------------------------------------------------------------------
def compare(expected, actual):
    """-> list of human-readable differences (empty = identical show content)."""
    diffs = []
    ef = {f.index: f for f in expected.fixtures}
    af = {f.index: f for f in actual.fixtures}
    for i in sorted(set(ef) | set(af)):
        a, b = ef.get(i), af.get(i)
        if a is None or b is None:
            diffs.append(f"fixture {i + 1}: {'missing on LPU' if b is None else 'extra on LPU'}")
            continue
        if a.address != b.address:
            diffs.append(f"fixture {i + 1}: address {a.address} != {b.address}")
        if (a.manufacturer, a.mode, a.profile.upper()) != (b.manufacturer, b.mode, b.profile.upper()):
            diffs.append(f"fixture {i + 1}: definition differs")
        if not (a.model == b.model or a.model.startswith(b.model)):   # LPU truncates names
            diffs.append(f"fixture {i + 1}: model '{a.model}' != '{b.model}'")
        if (a.name or "") != (b.name or ""):
            diffs.append(f"fixture {i + 1}: name {a.name!r} != {b.name!r}")
        # The LPU only keeps pan/tilt flags on fixtures that have pan or tilt.
        codes = split_profile(a.profile)
        flags = ["virtual_dimmer"] + (["invert_pan", "invert_tilt", "swap_pan_tilt"]
                                      if 0x02 in codes or 0x03 in codes else [])
        for attr in flags:
            if bool(getattr(a, attr)) != bool(getattr(b, attr)):
                diffs.append(f"fixture {i + 1}: {attr} {bool(getattr(a, attr))} != {bool(getattr(b, attr))}")
    ep = {p.index: p for p in expected.playbacks}
    ap = {p.index: p for p in actual.playbacks}
    for i in sorted(set(ep) | set(ap)):
        a, b = ep.get(i), ap.get(i)
        if a is None or b is None:
            diffs.append(f"playback {i + 1}: {'missing on LPU' if b is None else 'extra on LPU'}")
            continue
        for attr in ("label", "gomode", "repeat", "background", "exclusive"):
            if getattr(a, attr) != getattr(b, attr):
                diffs.append(f"playback {i + 1}: {attr} {getattr(a, attr)!r} != {getattr(b, attr)!r}")
        for attr in ("intensity", "speed"):
            if abs(getattr(a, attr) - getattr(b, attr)) > 1e-4:
                diffs.append(f"playback {i + 1}: {attr} {getattr(a, attr):g} != {getattr(b, attr):g}")
        if len(a.cues) != len(b.cues):
            diffs.append(f"playback {i + 1}: {len(a.cues)} cues != {len(b.cues)}")
        for q, (ca, cb) in enumerate(zip(a.cues, b.cues)):
            for attr in ("label", "fade_ms", "delay_ms", "follow"):
                if getattr(ca, attr) != getattr(cb, attr):
                    diffs.append(f"playback {i + 1} cue {q + 1}: {attr} "
                                 f"{getattr(ca, attr)!r} != {getattr(cb, attr)!r}")
            for blk in range(4):
                if ca.block(blk) != cb.block(blk):
                    diffs.append(f"playback {i + 1} cue {q + 1}: block {blk} differs")
    return diffs
