"""Human-readable text report of a Show.

Numbers are 1-based like the reference app (fixture 1-64, playback 1-64, cue 1-N).
16-bit channel values are shown as percent (65535 = 100 %).
"""

from .personalities import Personalities, channel_list, split_profile
from .showfile import describe_fx, format_time_ms

# Fader -> the DMX function code that fader drives (FINDINGS 20.11). Used to
# mark values stored for a fader the fixture has no channel for.
FADER_CODES = {"colour wheel": 0x09, "gobo": 0x0A, "gobo rotation": 0x0B, "shutter": 0x0C,
               "iris": 0x0D, "frost": 0x0E, "focus": 0x0F, "prism": 0x10, "zoom": 0x11}


def _pct(v):
    return f"{v / 655.35:.0f}%"


def _time(ms):
    return f"{ms / 1000:g}s"


def fixture_line(f, pers):
    chans = channel_list(f.profile)
    last = f.address + len(chans) - 1 if chans else f.address
    info = pers.lookup(f.manufacturer, f.model, f.mode) if pers and pers.loaded else None
    cls = f" [{info[1]}]" if info and info[1] else ""
    note = ""
    if pers and pers.loaded:
        if info is None:
            note = "  (not found in personalities.xml)"
        elif info[0] != f.profile.upper():
            note = f"  (personalities.xml profile differs: {info[0]})"
    flags = [n for n, on in (("invert pan", f.invert_pan), ("invert tilt", f.invert_tilt),
                              ("swap pan/tilt", f.swap_pan_tilt), ("virtual dimmer", f.virtual_dimmer)) if on]
    lines = [f"  {f.index + 1:2d}  DMX {f.address}-{last}  {f.manufacturer} / {f.model} / {f.mode}{cls}{note}"]
    if f.name:
        lines.append(f"        name: {f.name}")
    if flags:
        lines.append(f"        flags: {', '.join(flags)}")
    lines.append("        channels: " + ", ".join(f"{n} {name}" for n, _, name in chans))
    return lines


def record_line(rec, codes=None):
    """codes: the fixture's function codes; faders it has no channel for get a note."""
    parts = []
    lacks = lambda n: codes is not None and n in FADER_CODES and FADER_CODES[n] not in codes
    if rec.intensity:
        parts.append(f"int {_pct(rec.intensity)}")
    if any(rec.rgbaw):
        parts.append("RGBAW " + "/".join(_pct(v) for v in rec.rgbaw))
    if any(rec.raw[12:16]):  # pan / tilt set (all zero = centre, not in the cue)
        parts.append(f"pan {_pct(rec.pan)} tilt {_pct(rec.tilt)}")
    parts.extend(f"{n} {_pct(v)}" + (" (no channel)" if lacks(n) else "")
                 for n, v in rec.attrs.items())
    for kind, slot in (("intensity", rec.fx_intensity), ("position", rec.fx_position),
                       ("colour", rec.fx_colour)):
        d = describe_fx(kind, slot)
        if d:
            parts.append(f"{kind} FX {d}")
    if rec.other:
        parts.append("other " + " ".join(f"@{o}={_pct(v)}" for o, v in sorted(rec.other.items())))
    return "; ".join(parts)


def render(show, pers=None, source="", details=True):
    if pers is None:
        pers = Personalities()
    out = []
    w = out.append
    w(f"Show report{(' - ' + source) if source else ''}")
    w(f"application {show.application} {show.version}".rstrip())
    w("")
    w("DEVICE")
    d = show.device
    for key, label in (("type", "type"), ("firmware_version", "firmware"), ("pcb_version", "PCB"),
                       ("mac", "MAC"), ("ip", "IP"), ("subnet", "subnet"), ("dhcp", "DHCP")):
        if d.get(key):
            w(f"  {label:9s} {d[key]}")
    for key, val in show.extra.items():
        w(f"  {key:9s} {val}")
    w("")
    w(f"FIXTURES ({len(show.fixtures)} patched)" + ("" if pers.loaded else "  [personalities.xml not loaded]"))
    for f in show.fixtures:
        out.extend(fixture_line(f, pers))
    w("")
    used = [p for p in show.playbacks]
    w(f"PLAYBACKS ({len(used)} in show, {sum(len(p.cues) for p in used)} cues)")
    patched = {f.index for f in show.fixtures}
    for p in used:
        opts = [f"go {p.gomode}", f"repeat {p.repeat}", f"intensity {p.intensity * 100:.0f}%",
                f"speed {p.speed * 100:+.0f}%"]
        if p.background:
            opts.append("background")
        if p.exclusive:
            opts.append("exclusive")
        w(f"  PB {p.index + 1:2d}  {p.label or '(no label)'}  - {len(p.cues)} cue(s); " + ", ".join(opts))
        for c, cue in enumerate(p.cues):
            cond = "Follow" if cue.follow else "Halt"
            w(f"      cue {c + 1}: {cue.label or '(no label)'}  [{cond}, fade {_time(cue.fade_ms)}, "
              f"delay {_time(cue.delay_ms)}]")
            if not details:
                continue
            for f in show.fixtures:
                rec = cue.record(f.index)
                if not rec.empty:
                    w(f"          fixture {f.index + 1:2d}: "
                      f"{record_line(rec, set(split_profile(f.profile)))}")
            stray = [g for g in range(64) if g not in patched and not cue.record(g).empty]
            if stray:
                w(f"          (data on unpatched slots {', '.join(str(g + 1) for g in stray)} - ignored by the app)")
    w("")
    w("Notes: values in % of full (16-bit). '(no channel)' = a value stored for a fader")
    w("this fixture has no DMX channel for (it has no effect). See analysis/FINDINGS.md 20.11.")
    return "\n".join(out) + "\n"
