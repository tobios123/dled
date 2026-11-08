""".show files: read, write, and decode the 50-byte fixture records.

XML layout (dled_flutter/SHOW_FORMAT.md):
    <show application="DLED" version=..>
      <system><host>..</host><device>mac ip subnet dhcp pcb_version firmware_version type</device></system>
      <fixtures><fixture index address manufacturer model mode profile/></fixtures>
      <playbacks><playback index label intensity gomode repeat speed background exclusive>
        <cues><cue label fade delay condition><blocks><block>base64 800 bytes</block> x4

Cue times are "HH-MM-SS-FF", FF = hundredths of a second.
A block holds 16 records x 50 bytes; global fixture index = block * 16 + record.

Record layout (FINDINGS.md 20.5a + sample-show survey 2026-10-22):
    0-3 intensity FX, 4-7 position FX, 8-11 colour FX  [waveform, size, speed, phase]
    12-13 pan, 14-15 tilt       int16 LE, signed around the centre: DMX = 32767 + value
    16 intensity                u16 LE
    18 colour wheel             u16 LE
    20 R, 22 G, 24 B, 26 A, 28 W  u16 LE (same order as the programmer colour)
    30 gobo, 32 gobo rotation, 34 shutter, 36 iris, 38 frost, 40 focus,
    42 prism, 44 zoom, 46 custom 1, 48 custom 2   u16 LE (ATTR_OFFSETS)
Little-endian and the signed pan / tilt were measured from the LPU's DMX
output (lpd/DMX_ENGINE.md section 2, 2026-10-27); the value is the 16-bit
DMX value (coarse channel = high byte, fine channel = low byte).
"""

import base64
import struct
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

GO_MODES = ["Go", "Toggle", "Flash", "Solo"]
REPEAT_MODES = ["Loop", "Bounce", "Random", "Off"]
FX_WAVES = {
    "intensity": {0: "None", 1: "Sine", 2: "Ramp", 3: "Inversed ramp", 4: "Square", 5: "Random"},
    "position": {0: "None", 4: "Square", 5: "Random", 6: "Circle", 7: "Eight", 8: "Pan", 9: "Tilt"},
    "colour": {0: "None", 5: "Random", 10: "Rainbow", 11: "Full Sines", 12: "Full Twinkle"},
}
BLOCK_SIZE = 800
RECORD_SIZE = 50
# Record offset -> programmer fader. Each confirmed by an app-saved cue that
# switched exactly that fader on or off (show_all_fx_options.show, pb4-pb6, 2026-10-23).
ATTR_OFFSETS = {18: "colour wheel", 30: "gobo", 32: "gobo rotation", 34: "shutter",
                36: "iris", 38: "frost", 40: "focus", 42: "prism", 44: "zoom",
                46: "custom 1", 48: "custom 2"}
UNMAPPED_OFFSETS = [o for o in range(30, 50, 2) if o not in ATTR_OFFSETS]


# --- times ---------------------------------------------------------------------
def parse_time_ms(s):
    if not s:
        return 0
    parts = [int(p or 0) for p in s.split("-")]
    while len(parts) < 4:
        parts.insert(0, 0)
    h, m, sec, ff = parts[-4:]
    return ((h * 60 + m) * 60 + sec) * 1000 + ff * 10


def format_time_ms(ms):
    ms = int(ms)
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}-{m:02d}-{s:02d}-{ms // 10:02d}"


# --- FX ------------------------------------------------------------------------
def fx_speed_percent(b):
    """Signed int8, ~1.27 per %; +100 % is 127 (ours) or 128 (the reference app)."""
    if b == 128:
        return 100
    return round((b - 256 if b > 128 else b) / 1.27)


def describe_fx(kind, slot):
    wave, size, speed, phase = slot
    if not (wave or size or speed or phase):
        return None
    name = FX_WAVES[kind].get(wave, f"wave {wave}")
    return f"{name} size {size / 2.55:.0f}% speed {fx_speed_percent(speed)}% phase {phase / 2.55:.0f}%"


# --- records -------------------------------------------------------------------
@dataclass
class Record:
    fx_intensity: tuple
    fx_position: tuple
    fx_colour: tuple
    pan: int             # 16-bit DMX, 32767 = centre (also when not set)
    tilt: int
    intensity: int
    rgbaw: tuple
    attrs: dict          # fader name -> u16, from ATTR_OFFSETS (non-zero only)
    other: dict          # offset -> u16 for unmapped bytes 30..48
    raw: bytes

    @property
    def empty(self):
        return not any(self.raw)


def signed_dmx(raw):
    """Pan / tilt: the stored int16 -> 16-bit DMX (32767 = centre)."""
    return max(0, min(65535, (raw - 65536 if raw >= 32768 else raw) + 32767))


def dmx_to_signed(dmx):
    """The inverse of signed_dmx, as stored (u16), kept within -32767..32767."""
    return max(-32767, min(32767, dmx - 32767)) & 0xFFFF


def decode_record(rec):
    u16 = lambda o: rec[o] | rec[o + 1] << 8
    return Record(
        fx_intensity=tuple(rec[0:4]), fx_position=tuple(rec[4:8]), fx_colour=tuple(rec[8:12]),
        pan=signed_dmx(u16(12)), tilt=signed_dmx(u16(14)), intensity=u16(16),
        rgbaw=tuple(u16(o) for o in (20, 22, 24, 26, 28)),
        attrs={n: u16(o) for o, n in ATTR_OFFSETS.items() if u16(o)},
        other={o: u16(o) for o in UNMAPPED_OFFSETS if u16(o)},
        raw=bytes(rec))


# --- show model ----------------------------------------------------------------
@dataclass
class Fixture:
    index: int
    address: int
    manufacturer: str
    model: str
    mode: str
    profile: str
    # Patch-screen name and flags. In the .show they are the <fixture>
    # attributes label / invert_pan / invert_tilt / swap_pan_tilt /
    # virtual_dimmer (seen in files saved with those options on); like all
    # attributes the app writes them only when not default, so "absent" means
    # empty / off.
    name: str = ""
    invert_pan: bool = False
    invert_tilt: bool = False
    swap_pan_tilt: bool = False
    virtual_dimmer: bool = False
    extra_attrs: dict = field(default_factory=dict)   # unknown attributes, kept as-is

    @property
    def definition(self):
        return f'"{self.manufacturer}","{self.model}","{self.mode}","{self.profile}"'


@dataclass
class Cue:
    label: str = ""
    fade_ms: int = 0
    delay_ms: int = 0
    follow: bool = False
    blocks: list = field(default_factory=lambda: [b"", b"", b"", b""])
    extra_attrs: dict = field(default_factory=dict)

    def block(self, b):
        data = self.blocks[b] if b < len(self.blocks) else b""
        return data if data else bytes(BLOCK_SIZE)

    def record(self, fixture_index):
        b, r = divmod(fixture_index, 16)
        data = self.block(b)
        return decode_record(data[r * RECORD_SIZE:(r + 1) * RECORD_SIZE])


@dataclass
class Playback:
    index: int
    label: str = ""
    intensity: float = 1.0
    speed: float = 0.0
    gomode: str = "Go"
    repeat: str = "Loop"
    background: bool = False
    exclusive: bool = False
    cues: list = field(default_factory=list)
    extra_attrs: dict = field(default_factory=dict)   # e.g. "level" (seen in the app, meaning unknown)


@dataclass
class Show:
    application: str = "DLED"
    # the .show format version (what the reference app's files carry), not DLED's
    version: str = "1.19.0"
    device: dict = field(default_factory=dict)       # mac ip subnet dhcp pcb_version firmware_version type
    host: dict = field(default_factory=dict)         # os, ips
    extra: dict = field(default_factory=dict)        # LPU-only info (alias, Art-Net, sACN)
    fixtures: list = field(default_factory=list)
    playbacks: list = field(default_factory=list)
    root_attrs: dict = field(default_factory=dict)   # other <show> attributes, e.g. readonly
    extra_elements: list = field(default_factory=list)  # unknown sections, e.g. <buttons>, kept verbatim

    def fixture(self, index):
        return next((f for f in self.fixtures if f.index == index), None)


# --- XML -----------------------------------------------------------------------
def _float_attr(el, name, default):
    v = el.get(name)
    try:
        return float(v) if v is not None else default
    except ValueError:
        return default


FIXTURE_ATTRS = {"index", "address", "manufacturer", "model", "mode", "profile", "label",
                 "invert_pan", "invert_tilt", "swap_pan_tilt", "virtual_dimmer"}
PLAYBACK_ATTRS = {"index", "label", "intensity", "speed", "gomode", "repeat", "background", "exclusive"}
CUE_ATTRS = {"label", "fade", "delay", "condition"}
SHOW_CHILDREN = {"system", "fixtures", "playbacks"}


def _extra(el, known):
    return {k: v for k, v in el.attrib.items() if k not in known}


def load_show(path):
    root = ET.parse(path).getroot()
    show = Show(application=root.get("application", "DLED"), version=root.get("version", ""))
    show.root_attrs = _extra(root, {"application", "version"})
    show.extra_elements = [c for c in root if c.tag not in SHOW_CHILDREN]
    dev = root.find("system/device")
    if dev is not None:
        show.device = {c.tag: (c.text or "") for c in dev}
    host = root.find("system/host")
    if host is not None:
        show.host = {"os": host.findtext("os", ""),
                     "ips": [i.text or "" for i in host.findall("ips/ip")]}
    for f in root.iter("fixture"):
        show.fixtures.append(Fixture(
            index=int(f.get("index")), address=int(f.get("address", "0")),
            manufacturer=f.get("manufacturer", ""), model=f.get("model", ""),
            mode=f.get("mode", ""), profile=f.get("profile", ""),
            name=f.get("label", ""),
            invert_pan=f.get("invert_pan") == "true", invert_tilt=f.get("invert_tilt") == "true",
            swap_pan_tilt=f.get("swap_pan_tilt") == "true",
            virtual_dimmer=f.get("virtual_dimmer") == "true",
            extra_attrs=_extra(f, FIXTURE_ATTRS)))
    for pb in root.iter("playback"):
        p = Playback(index=int(pb.get("index")), label=pb.get("label", ""),
                     intensity=_float_attr(pb, "intensity", 1.0),
                     speed=_float_attr(pb, "speed", 0.0),
                     gomode=pb.get("gomode", "Go"), repeat=pb.get("repeat", "Loop"),
                     background=pb.get("background", "false") == "true",
                     exclusive=pb.get("exclusive", "false") == "true",
                     extra_attrs=_extra(pb, PLAYBACK_ATTRS))
        for cue in pb.findall("cues/cue"):
            blocks = []
            for blk in cue.findall("blocks/block"):
                t = (blk.text or "").strip()
                blocks.append(base64.b64decode(t) if t else b"")
            blocks += [b""] * (4 - len(blocks))
            p.cues.append(Cue(label=cue.get("label", ""),
                              fade_ms=parse_time_ms(cue.get("fade")),
                              delay_ms=parse_time_ms(cue.get("delay")),
                              follow=cue.get("condition", "Halt") == "Follow",
                              blocks=blocks[:4], extra_attrs=_extra(cue, CUE_ATTRS)))
        show.playbacks.append(p)
    show.fixtures.sort(key=lambda f: f.index)
    show.playbacks.sort(key=lambda p: p.index)
    return show


def _fmt_float(v):
    return f"{v:g}"


def save_show(show, path):
    """Write a .show the reference app can open (defaults omitted like the app does)."""
    root = ET.Element("show", {"application": show.application or "DLED",
                               "version": show.version or "1.19.0", **show.root_attrs})
    system = ET.SubElement(root, "system")
    host = ET.SubElement(system, "host")
    ET.SubElement(host, "os").text = show.host.get("os", "Windows")
    ips = ET.SubElement(host, "ips")
    for ip in show.host.get("ips", []):
        ET.SubElement(ips, "ip").text = ip
    dev = ET.SubElement(system, "device")
    for tag in ("mac", "ip", "subnet", "dhcp", "pcb_version", "firmware_version", "type"):
        if tag in show.device:
            ET.SubElement(dev, tag).text = str(show.device[tag])
    fx = ET.SubElement(root, "fixtures")
    for f in show.fixtures:
        # Attribute order as the app writes it (pan_tiltt_dimmer.show, 2026-10-23).
        a = {"index": str(f.index)}
        if f.name:
            a["label"] = f.name
        a.update({"address": str(f.address), "manufacturer": f.manufacturer, "model": f.model})
        if f.mode:                        # the app omits mode for models without modes
            a["mode"] = f.mode
        a["profile"] = f.profile
        for attr in ("invert_pan", "invert_tilt", "swap_pan_tilt", "virtual_dimmer"):
            if getattr(f, attr):
                a[attr] = "true"
        a.update(f.extra_attrs)
        ET.SubElement(fx, "fixture", a)
    pbs = ET.SubElement(root, "playbacks")
    for p in show.playbacks:
        a = {"index": str(p.index)}
        if p.label:
            a["label"] = p.label
        if abs(p.intensity - 1.0) > 1e-6:
            a["intensity"] = _fmt_float(p.intensity)
        if p.gomode != "Go":
            a["gomode"] = p.gomode
        if p.repeat != "Loop":
            a["repeat"] = p.repeat
        if abs(p.speed) > 1e-6:
            a["speed"] = _fmt_float(p.speed)
        if p.background:
            a["background"] = "true"
        if p.exclusive:
            a["exclusive"] = "true"
        a.update(p.extra_attrs)
        pel = ET.SubElement(pbs, "playback", a)
        if not p.cues:
            continue
        cues = ET.SubElement(pel, "cues")
        for c in p.cues:
            ca = {}
            if c.label:
                ca["label"] = c.label
            if c.fade_ms:
                ca["fade"] = format_time_ms(c.fade_ms)
            if c.delay_ms:
                ca["delay"] = format_time_ms(c.delay_ms)
            if c.follow:
                ca["condition"] = "Follow"
            ca.update(c.extra_attrs)
            cel = ET.SubElement(cues, "cue", ca)
            blocks = ET.SubElement(cel, "blocks")
            for b in range(4):
                data = c.blocks[b] if b < len(c.blocks) else b""
                bel = ET.SubElement(blocks, "block")
                if data and any(data):
                    bel.text = base64.b64encode(data).decode("ascii")
    for el in show.extra_elements:            # e.g. <buttons>: not decoded, kept verbatim
        root.append(el)
    ET.indent(root, space="    ")
    body = ET.tostring(root, encoding="unicode", short_empty_elements=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n')
        fh.write(body + "\n")
