"""personality_add.py -- add a fixture to the personality library
(assets/personalities.xml, used by the Flutter app and the light page).

    python tool/personality_add.py show MANUFACTURER [MODEL]
    python tool/personality_add.py read FILE|FOLDER... > spec.json   (fixture files -> spec to check)
    python tool/personality_add.py add spec.json               (shows what would change)
    python tool/personality_add.py add spec.json --write       (writes it)

read takes QLC+ (.qxf), Avolites (.R20, one file per mode), grandMA
fixture XML and Freestyler (.fxt) files, recognised by their contents, and
merges them into one spec. Where two files describe the same mode it
compares them and reports any difference. Sunlite .ssl2 and most binary
formats cannot be read (encrypted / compressed); use them only as names.

A spec (JSON):
    {"manufacturer": "Shehds", "model": "CoralPar P18A", "class": "Led", "parts": "off",
     "modes": [{"label": "6 ch", "channels": ["red", "green", "blue", "white", "amber", "uv"]}, ...]}

Channel names become the LPU's function codes (two hex digits per DMX
channel, lib/core/fixture_codes.dart) by the table below, which follows
the conventions of the existing library; a channel may also be given as a
code ("0C"). A name not in the table is an error (say what it is, or give
its code): nothing is guessed silently.
  "<name> fine"      the low byte of a 16-bit channel: pan / tilt fine 22 /
                     23, others the code + 20 (the library's pattern)
  "part:<part>:<name>"  a channel of a second part of the fixture (an LED
                     ring, pixel zones). The LPU has one set of faders per
                     fixture: "parts": "off" (default) gives them no fader
                     (they stay dark), "follow" the same code as the main
                     channel (they take the fixture's colour / dimmer).
  custom faders      a channel without a fader of its own (a ring's dimmer,
                     an effect wheel, a speed, programs ...) can go on custom 1
                     (12) or custom 2 (13), if the fixture does not use them
                     already (UV is 13): the two most useful (value()) get
                     them, the best custom 1; the table says which channels
                     got one, which did not (full) and which never do (reset,
                     control). "custom": "off" in the spec turns this off; a
                     channel given as "custom 1" / "custom 2" keeps its fader.
A model with one mode is written the library's short way (the codes
directly in <model>). The file keeps its layout: the model is inserted in
its manufacturer (alphabetical, ignoring case), a new manufacturer likewise.
"""
import json
import re
import sys
from pathlib import Path

# your own library (personalities.local.xml, not in Git) when it is there,
# else the public one
_ASSETS = Path(__file__).resolve().parent.parent / 'assets'
LIBRARY = next((p for p in (_ASSETS / 'personalities.local.xml', _ASSETS / 'personalities.xml') if p.exists()),
               _ASSETS / 'personalities.xml')

# name (lower case, without spaces / - / _ / digits at the end) -> function code
CODES = {
    # intensity / colour mixing
    'dimmer': '01', 'dim': '01', 'intensity': '01', 'master': '01', 'masterdimmer': '01',
    'red': '04', 'r': '04', 'green': '05', 'g': '05', 'blue': '06', 'b': '06',
    'amber': '07', 'a': '07', 'white': '08', 'w': '08', 'coolwhite': '08', 'warmwhite': '08',
    'lime': '07',  # RGBL: the 4th colour on the amber fader
    'uv': '13', 'violet': '13', 'ultraviolet': '13', 'purple': '13',
    'cyan': '04', 'magenta': '05', 'yellow': '06',  # CMY: on the R / G / B faders, like the library
    # movement
    'pan': '02', 'tilt': '03',
    'pantiltspeed': '14', 'ptspeed': '14', 'xyspeed': '14', 'movementspeed': '14', 'motorspeed': '14',
    # beam
    'colourwheel': '09', 'colorwheel': '09', 'colour': '09', 'color': '09',
    'gobo': '0A', 'gobowheel': '0A', 'rotatinggobo': '0A', 'staticgobo': '0A',
    'goborotation': '0B', 'gobrotation': '0B', 'gobo1rotation': '0B', 'rotation': '0B',
    'strobe': '0C', 'shutter': '0C', 'shutterstrobe': '0C',
    'iris': '0D', 'frost': '0E', 'focus': '0F', 'prism': '10', 'prismrotation': '80', 'zoom': '11',
    # no fader of their own: 80 here; the most useful two of them get the custom
    # faders (see VALUE / allocate), the rest stays 80
    'macro': '80', 'program': '80', 'programs': '80', 'auto': '80', 'automode': '80', 'function': '80',
    'mode': '80', 'effect': '80', 'effects': '80', 'effectrot': '80', 'effectrotation': '80',
    'effectwheel': '80', 'rainbow': '80', 'rainbowwheel': '80', 'animation': '80', 'animationwheel': '80',
    'sound': '80', 'soundmode': '80', 'colormacro': '80', 'colourmacro': '80',
    'cto': '80', 'ctc': '80', 'colortemperature': '80', 'colourtemperature': '80', 'colortemp': '80',
    'macrospeed': '80', 'programspeed': '80', 'speed': '80', 'autospeed': '80', 'effectspeed': '80',
    'speedcontrol': '80',
    # custom 1 = 12 (confirmed); custom 2 = 13, the code UV uses too (FINDINGS 20.x:
    # the PLUTO 200's only channel for the custom 2 fader is its 13) - a fixture
    # with UV has no custom 2 left
    'custom': '12', 'custom1': '12', 'custom2': '13', 'none': '80', 'unused': '80', 'reset': '80', 'control': '80', 'special': '80',
}

# Channels without a fader of their own (code 80) compete for the two custom
# faders (custom 1 = 12, custom 2 = 13, unless the fixture uses them already,
# UV on 13): the most useful get them, the best custom 1. None = never on a
# fader (it would reset the motors, mirror pan / tilt ...).
NEVER = {'reset', 'control', 'function', 'mode', 'none', 'unused', 'special', 'maintenance'}
PROGRAMS = {'macro', 'program', 'programs', 'auto', 'automode', 'sound', 'soundmode', 'colormacro', 'colourmacro'}


def value(channel):
    """(score, why) for a custom fader, or None (never)."""
    part = channel.startswith('part:')
    name = channel.split(':', 2)[2] if part else channel
    k = re.sub(r'\d+$', '', re.sub(r'[\s\-_/+.()]', '', name.lower()))
    if k in NEVER or 'notdescribed' in k:
        return None
    if part:
        if k in ('dimmer', 'dim', 'intensity', 'master'):
            return 100, 'its own brightness for this part'
        if 'speed' in k:
            return 65, "speed of this part's effects"
        if 'effect' in k or 'macro' in k or 'program' in k:
            return 85, "this part's built-in effects (0 = none)"
        if k in ('strobe', 'shutter'):
            return 60, 'strobe of this part'
        return None  # a part's colours: "parts" off / follow
    if k in ('cto', 'ctc', 'colortemperature', 'colourtemperature', 'colortemp'):
        return 95, 'colour temperature'
    if k in ('effect', 'effects', 'effectwheel', 'rainbow', 'rainbowwheel', 'animation', 'animationwheel'):
        return 90, 'effect wheel'
    if 'rot' in k:
        return 80, 'rotation'
    if 'speed' in k:
        return 70, 'speed of the programs / effects'
    if k in PROGRAMS:
        return 40, "the fixture's own programs - NOT 0 starts them (auto / sound)"
    return 30, 'no fader of its own'


def allocate(spec, mode):
    """(codes, given, left, never): the codes with the custom faders handed
    out; given = [(channel no, name, custom code, why)], left = channels that
    did not get one (the custom faders were full), never = never on a fader."""
    out = [code_for(c, spec.get('parts', 'off')) for c in mode['channels']]
    given, left, never = [], [], []
    if spec.get('custom', 'auto') == 'off':
        return out, given, left, never
    free = [c for c in ('12', '13') if c not in out]
    cands = []
    for i, (c, k) in enumerate(zip(mode['channels'], out)):
        if k != '80':
            continue
        v = value(c)
        if v is None:
            if not (c.startswith('part:') and spec.get('parts', 'off') == 'off' and value(c) is None
                    and not any(w in c.lower() for w in NEVER)):
                never.append((i + 1, c))
            continue
        cands.append((-v[0], i, c, v[1]))
    for n, (_, i, c, why) in enumerate(sorted(cands)):
        if n < len(free):
            out[i] = free[n]
            given.append((i + 1, c, free[n], why))
        else:
            left.append((i + 1, c, why))
    return out, given, left, never

NAMES = {  # code -> what the LPU calls it (for the table)
    '01': 'intensity', '02': 'pan', '03': 'tilt', '04': 'red', '05': 'green', '06': 'blue',
    '07': 'amber', '08': 'white', '09': 'colour wheel', '0A': 'gobo', '0B': 'gobo rotation',
    '0C': 'shutter / strobe', '0D': 'iris', '0E': 'frost', '0F': 'focus', '10': 'prism',
    '11': 'zoom', '12': 'custom 1', '13': 'UV / custom 2', '14': 'pan/tilt speed', '22': 'pan fine',
    '23': 'tilt fine', '80': '(no fader)',
}

CLASSES = ['Led', 'Yoke spot', 'Yoke wash', 'Scanner', 'Colour changer', 'Laser', 'Panel', 'Fog',
           'Flower', 'Strobe', 'Barrel', 'Unknown']

# first word of a channel name that marks a second part of the fixture
PART_WORDS = ('ring', 'zone', 'cell', 'pixel', 'segment', 'outer', 'inner', 'back', 'aura')


def key_of(name):
    k = re.sub(r'[\s\-_/+.()]', '', name.lower())
    return k if k in CODES else re.sub(r'\d+$', '', k)  # "Gobo1" / "Color2" -> gobo / color


def code_for(channel, parts='off'):
    c = channel.strip()
    if re.fullmatch(r'[0-9A-Fa-f]{2}', c):
        return c.upper()
    if c.startswith('part:'):
        name = c.split(':', 2)[2]
        return code_for(name) if parts == 'follow' else '80'
    m = re.fullmatch(r'(.+?)\s*(fine|low|lsb|16bit)', c, re.I)
    if m:
        coarse = code_for(m.group(1))
        return f'{int(coarse, 16) + 0x20:02X}' if int(coarse, 16) < 0x20 else '80'
    k = key_of(c)
    if k not in CODES:
        raise SystemExit(f'unknown channel "{channel}": add it to CODES or give its code (e.g. "0C")')
    return CODES[k]


def codes(spec, mode):
    return allocate(spec, mode)[0]


def esc(s):
    return s.replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;')


def model_xml(spec):
    modes = spec['modes']
    head = f'        <model label="{esc(spec["model"])}" class="{esc(spec["class"])}">'
    if len(modes) == 1:
        return head + ''.join(codes(spec, modes[0])) + '</model>\n'
    out = head + '\n'
    for m in modes:
        out += f'            <mode label="{esc(m["label"])}">{"".join(codes(spec, m))}</mode>\n'
    return out + '        </model>\n'


def table(spec):
    lines = [f'{spec["manufacturer"]} / {spec["model"]} ({spec["class"]})']
    if any(c.startswith('part:') for m in spec['modes'] for c in m['channels']):
        lines.append(f'  parts (ring / zones): {spec.get("parts", "off")}')
    shown = lambda c: c.replace('part:', '').replace(':', ' ', 1) if c.startswith('part:') else c
    for m in spec['modes']:
        cs, given, left, never = allocate(spec, m)
        why = {i: w for i, _, _, w in given}
        lines.append(f'  mode "{m["label"]}": {len(cs)} channels, profile {"".join(cs)}')
        for i, (c, k) in enumerate(zip(m['channels'], cs), 1):
            name = NAMES.get(k, 'fine' if 0x20 < int(k, 16) < 0x40 else '?')
            extra = f'   <- custom fader: {why[i]}' if i in why else ''
            lines.append(f'    {i:2}  {shown(c):<22} -> {k}  {name}{extra}')
        if left:
            lines.append('    no custom fader left for: ' + ', '.join(f'{i} {shown(c)} ({w})' for i, c, w in left))
        if never:
            lines.append('    never on a fader: ' + ', '.join(f'{i} {shown(c)}' for i, c in never))
    return '\n'.join(lines)


# --- the library file ------------------------------------------------------------

def manufacturers(text):
    """[(label, start, end)] with end = after its </manufacturer> line."""
    out = []
    for m in re.finditer(r'^    <manufacturer label="([^"]*)"\s*(/>|>)\n', text, re.M):
        if m.group(2) == '/>':
            out.append((m.group(1), m.start(), m.end()))
        else:
            end = text.index('    </manufacturer>\n', m.end()) + len('    </manufacturer>\n')
            out.append((m.group(1), m.start(), end))
    return out


def models(block):
    """[(label, start, end)] of the <model> elements in a manufacturer block."""
    out = []
    for m in re.finditer(r'^        <model label="([^"]*)"[^>]*?(/>|>)', block, re.M):
        if m.group(2) == '/>':
            end = block.index('\n', m.end()) + 1
        else:
            close = block.find('</model>', m.end())
            end = block.index('\n', close) + 1
        out.append((m.group(1), m.start(), end))
    return out


def add(spec, write):
    if spec.get('class') not in CLASSES:
        raise SystemExit(f'class must be one of {CLASSES}')
    if not spec.get('modes'):
        raise SystemExit('no modes')
    text = LIBRARY.read_text(encoding='utf-8')
    new_model = model_xml(spec)
    mans = manufacturers(text)
    found = [m for m in mans if m[0].lower() == spec['manufacturer'].lower()]
    if found:
        label, start, end = found[0]
        block = text[start:end]
        if block.rstrip().endswith('/>'):  # an empty manufacturer
            block = f'    <manufacturer label="{esc(label)}">\n    </manufacturer>\n'
        ms = models(block)
        if any(m[0].strip().lower() == spec['model'].strip().lower() for m in ms):
            raise SystemExit(f'{label} / {spec["model"]} is in the library already')
        at = next((m[1] for m in ms if m[0].lower() > spec['model'].lower()),
                  block.index('    </manufacturer>\n'))
        new_block = block[:at] + new_model + block[at:]
        where = f'into "{label}" (in the library already), alphabetically'
        new_text = text[:start] + new_block + text[end:]
    else:
        at = next((m[1] for m in mans if m[0].lower() > spec['manufacturer'].lower()), text.rindex('</personalities>'))
        new_block = f'    <manufacturer label="{esc(spec["manufacturer"])}">\n{new_model}    </manufacturer>\n'
        where = f'as a new manufacturer "{spec["manufacturer"]}", alphabetically'
        new_text = text[:at] + new_block + text[at:]

    print(table(spec))
    print(f'\nadded {where}:')
    print(new_model, end='')
    if write:
        LIBRARY.write_text(new_text, encoding='utf-8', newline='')
        print(f'\nwritten to {LIBRARY}')
    else:
        print('\n(not written: add --write)')


def show(manufacturer, model=None):
    text = LIBRARY.read_text(encoding='utf-8')
    for label, start, end in manufacturers(text):
        if manufacturer.lower() in label.lower():
            block = text[start:end]
            for m in models(block):
                if model is None or model.lower() in m[0].lower():
                    print(f'{label} / {block[m[1]:m[2]].strip()}' if model else f'{label} / {m[0]}')


# --- converters: a fixture file -> {manufacturer, model, class, modes, source} ------

def part_name(name):
    """'Ring Red' -> 'part:Ring:Red'; other names unchanged."""
    w = name.split(None, 1)
    if len(w) == 2 and w[0].lower() in PART_WORDS:
        return f'part:{w[0]}:{w[1]}'
    return name


def mode_label(raw, count):
    """'19CH' / '10CH' / 'mode=19CH' -> '19 ch'; else the text, or 'N ch'."""
    m = re.search(r'(\d+)\s*ch', raw or '', re.I)
    return f'{m.group(1)} ch' if m else (raw.strip() if raw and raw.strip() else f'{count} ch')


QLC_PRESETS = {
    'IntensityMasterDimmer': 'dimmer', 'IntensityDimmer': 'dimmer', 'IntensityRed': 'red',
    'IntensityGreen': 'green', 'IntensityBlue': 'blue', 'IntensityWhite': 'white',
    'IntensityAmber': 'amber', 'IntensityUV': 'uv', 'IntensityCyan': 'cyan', 'IntensityLime': 'lime',
    'IntensityMagenta': 'magenta', 'IntensityYellow': 'yellow', 'PositionPan': 'pan',
    'PositionTilt': 'tilt', 'PositionPanFine': 'pan fine', 'PositionTiltFine': 'tilt fine',
    'ShutterStrobeSlowFast': 'strobe', 'ShutterStrobeFastSlow': 'strobe', 'ShutterIrisMinToMax': 'iris',
    'BeamZoomSmallBig': 'zoom', 'BeamZoomBigSmall': 'zoom', 'BeamFocusNearFar': 'focus',
    'BeamFocusFarNear': 'focus', 'ColorWheel': 'colour wheel', 'GoboWheel': 'gobo',
    'SpeedPanTiltSlowFast': 'pan/tilt speed', 'SpeedPanTiltFastSlow': 'pan/tilt speed',
}
QLC_GROUPS = {'Intensity': 'dimmer', 'Pan': 'pan', 'Tilt': 'tilt', 'Colour': 'colour wheel',
              'Gobo': 'gobo', 'Shutter': 'strobe', 'Prism': 'prism', 'Beam': 'zoom',
              'Effect': 'macro', 'Speed': 'speed', 'Maintenance': 'none', 'Nothing': 'none'}
QLC_CLASSES = {'color changer': 'Led', 'moving head': 'Yoke spot', 'scanner': 'Scanner', 'laser': 'Laser',
               'smoke': 'Fog', 'hazer': 'Fog', 'strobe': 'Strobe', 'flower': 'Flower',
               'led bar (pixels)': 'Panel', 'led bar (beams)': 'Panel'}


def from_qxf(path, text):
    import xml.etree.ElementTree as ET
    ns = {'q': 'http://www.qlcplus.org/FixtureDefinition'}
    root = ET.fromstring(text)
    kinds = {}
    for ch in root.findall('q:Channel', ns):
        g = ch.find('q:Group', ns)
        kinds[ch.get('Name')] = (QLC_PRESETS.get(ch.get('Preset') or '')
                                 or (QLC_GROUPS.get(g.text) if g is not None else None)
                                 or part_name(ch.get('Name')))
    qtype = (root.findtext('q:Type', default='', namespaces=ns) or '').lower()
    return {
        'manufacturer': root.findtext('q:Manufacturer', namespaces=ns),
        'model': root.findtext('q:Model', namespaces=ns),
        'class': QLC_CLASSES.get(qtype, 'Unknown'),
        'modes': [{'label': mode_label(m.get('Name'), 0),
                   'channels': [kinds[c.text] for c in m.findall('q:Channel', ns)]}
                  for m in root.findall('q:Mode', ns)],
    }


def from_r20(path, text):
    """Avolites personality: one mode. DMX table: bank, button, type (H/L/I,
    s = 16-bit coarse), DMX offset, ..., "name". A 16-bit channel's fine
    byte is the next row ("" or "... Low")."""
    lines = text.replace('\r', '').split('\n')
    dev = next((l for l in lines if l.startswith('DEVICE')), '')
    name = next((l for l in lines if l.startswith('NAME ')), None)
    count = next((int(l.split()[2]) for l in lines if l.startswith('TYPE')), 0)
    rows, in_dmx, prev = [], False, None
    for l in lines:
        s = l.strip()
        if s == 'DMX':
            in_dmx = True
            continue
        if in_dmx and s == 'END':
            break
        if not in_dmx or not s or s.startswith(';'):
            continue
        m = re.match(r'\s*\d+\s+\d+\s+(\w)\s+(\d+)\s.*?"([^"]*)"', l)
        if not m:
            raise SystemExit(f'{path.name}: DMX row not understood: {s}')
        kind, offset, label = m.group(1), int(m.group(2)), m.group(3).strip()
        if prev and prev[0] == 's' and (not label or re.search(r'\b(low|fine|lsb)$', label, re.I)):
            label = f'{prev[1]} fine'
        rows.append((offset, label))
        prev = (kind, label)
    rows.sort()
    # a DMX channel the file does not describe stays visible as such (it
    # cannot be added until it is known, e.g. from the manual)
    described = dict(rows)
    last = max([count] + list(described))
    rows = [(o, described.get(o, f'channel {o} not described')) for o in range(1, last + 1)]
    manu, model = (re.findall(r'"([^"]*)"', name) + [None, None])[:2] if name else (None, None)
    raw_mode = (re.search(r'mode=(\S+)', dev) or [None, None])[1] if dev else None
    if model and raw_mode is None:
        raw_mode = model
    if model:
        model = re.sub(r'\s*\d+\s*ch$', '', model, flags=re.I).strip()
    return {'manufacturer': manu, 'model': model or (dev.split()[1] if dev else path.stem),
            'class': None,
            'modes': [{'label': mode_label(raw_mode, len(rows)), 'channels': [part_name(n) for _, n in rows]}]}


MA_ATTRS = {
    'DIM': 'dimmer', 'PAN': 'pan', 'TILT': 'tilt', 'PTSPEED': 'pan/tilt speed', 'SHUTTER': 'strobe',
    'STROBE': 'strobe', 'COLORRGB1': 'red', 'COLORRGB2': 'green', 'COLORRGB3': 'blue',
    'COLORRGB4': 'amber', 'COLORRGB5': 'white', 'COLORRGB6': 'uv', 'COLORRGB7': 'cyan',
    'COLORRGB8': 'magenta', 'COLORRGB9': 'yellow', 'COLOR1': 'colour wheel', 'COLOR2': 'colour wheel',
    'GOBO1': 'gobo', 'GOBO2': 'gobo', 'GOBO1_POS': 'gobo rotation', 'GOBO2_POS': 'gobo rotation',
    'PRISMA1': 'prism', 'PRISMA1_POS': 'prism rotation', 'FOCUS': 'focus', 'ZOOM': 'zoom', 'IRIS': 'iris',
    'FROST': 'frost', 'MODE': 'control', 'CONTROL': 'control', 'MACROS': 'macro', 'MACROSPEED': 'macro speed',
    'MACRORATE': 'macro speed', 'MACROS2': 'macro',
    'EFFECT': 'effect', 'EFFECTROT': 'effect rot', 'EFFECTSPEED': 'effect speed', 'CTO': 'none',
}


def from_ma(path, text):
    """grandMA fixture type: modules of channel types (coarse / fine = DMX
    offset within the module), placed by instances (patch = start offset)."""
    import xml.etree.ElementTree as ET
    root = ET.fromstring(text)
    for el in root.iter():  # newer files use a default namespace: plain tag names
        if el.tag.startswith('{'):
            el.tag = el.tag.split('}', 1)[1]
    ft = root.find('.//FixtureType')
    if ft is None:
        raise SystemExit(f'{path.name}: no FixtureType')
    modules = ft.findall('Modules/Module')
    chans = {}
    insts = ft.findall('Instances/Instance') or [ET.Element('Instance', {'module_index': '0'})]
    for inst in insts:
        mod = modules[int(inst.get('module_index', '0'))]
        base = int(inst.get('patch', '1')) - 1
        part = mod.get('name') if inst.get('module_index', '0') != '0' else None
        for ct in mod.findall('ChannelType'):
            attr = ct.get('attribute', '')
            name = MA_ATTRS.get(attr, attr.lower())
            for kind in ('coarse', 'fine'):
                if ct.get(kind):
                    n = name if kind == 'coarse' else f'{name} fine'
                    chans[base + int(ct.get(kind))] = f'part:{part}:{n}' if part else n
    count = max(chans) if chans else 0
    if sorted(chans) != list(range(1, count + 1)):
        raise SystemExit(f'{path.name}: DMX offsets {sorted(chans)} do not cover 1..{count}')
    beam = (modules[0].get('beamtype') or '').lower()
    if 1 in chans and any(c in ('pan', 'tilt') for c in chans.values()):
        cls = 'Yoke wash' if beam == 'wash' else 'Yoke spot' if beam in ('spot', 'beam') else None
    else:
        cls = {'LED': 'Led'}.get((modules[0].get('class') or ''), None)
    return {'manufacturer': ft.findtext('manufacturer'), 'model': ft.get('name'), 'class': cls,
            'modes': [{'label': mode_label(ft.get('mode'), count), 'channels': [chans[i] for i in range(1, count + 1)]}]}


def from_fxt(path, text):
    """Freestyler: manufacturer, 'Comments:', comment, model, channel count,
    a few numbers and an image name, then the channel names. Where the names
    start is not labelled: they are the only run of exactly <count> text
    lines; when that is not so, stop rather than guess."""
    lines = [l.replace('\x00', ' ').strip() for l in text.replace('\r', '').split('\n')]
    # a .pff package starts with the name and size of the .fxt it holds;
    # other parts (colour macro pictures ...) follow it
    pkg = re.match(r'\S+\.fxt\s+\d+\s+(.*)$', lines[0], re.I)
    if pkg:
        lines[0] = pkg.group(1).strip()
        end = next((j for j in range(2, len(lines)) if re.match(r'\S+\.\w{3}\s+\d+\s', lines[j])), len(lines))
        lines = lines[:end]
    if len(lines) < 6 or lines[1].lower() != 'comments:':
        raise SystemExit(f'{path.name}: not a Freestyler file as known')
    i = 3
    while i < len(lines) and not lines[i].isdigit():
        i += 1  # the comment can take several lines; then the model, then the count
    if i >= len(lines):
        raise SystemExit(f'{path.name}: no channel count found')
    count, model = int(lines[i]), lines[i - 1]
    runs, run = [], []
    for j, l in enumerate(lines[i + 1:], i + 1):
        textual = bool(l) and not re.fullmatch(r'-?\d+', l) and not re.search(r'\.(gif|png|jpe?g|bmp)$', l, re.I)
        if textual:
            run.append(l)
        else:
            if run:
                runs.append(run)
            run = []
    if run:
        runs.append(run)
    exact = [r for r in runs if len(r) == count]
    if len(exact) != 1:
        raise SystemExit(f'{path.name}: {count} channels, but {len(exact)} runs of {count} names - check it by hand')
    return {'manufacturer': lines[0], 'model': model, 'class': None,
            'modes': [{'label': f'{count} ch', 'channels': [part_name(n) for n in exact[0]]}]}


def read_any(path):
    data = path.read_bytes()
    text = data.decode('utf-8', 'replace').lstrip('﻿')
    if '<FixtureDefinition' in text:
        kind, spec = 'QLC+', from_qxf(path, text)
    elif re.search(r'^\s*DMX\s*$', text, re.M) and re.search(r'^\s*DEVICE', text, re.M):
        kind, spec = 'Avolites', from_r20(path, text)
    elif '<FixtureType' in text and '<MA' in text:
        kind, spec = 'grandMA', from_ma(path, text)
    elif text.split('\n', 2)[1:2] and text.split('\n')[1].strip().lower() == 'comments:':
        kind, spec = 'Freestyler', from_fxt(path, text)
    else:
        return None
    spec['source'] = f'{kind}: {path.name}'
    return spec


def read(paths):
    """Files and folders (all files in them, also in subfolders)."""
    files = []
    for p in map(Path, paths):
        files += sorted(f for f in p.rglob('*') if f.is_file()) if p.is_dir() else [p]
    specs = []
    for p in files:
        s = read_any(Path(p))
        print(f'{"read " if s else "skipped (not readable) "}{p}', file=sys.stderr)
        if s:
            specs.append(s)
    if not specs:
        raise SystemExit('nothing readable')
    notes = []

    def safe_codes(m, parts='off'):
        try:
            return codes({'parts': parts}, m)
        except SystemExit:
            return None

    # every mode found, with where it came from
    found = [(s['source'], m) for s in specs for m in s['modes']]
    for src, m in found:
        try:
            codes({}, m)
        except SystemExit as e:  # an unknown name: noted (the mode is kept, to fix by hand)
            notes.append(f'{src}: {e}')

    # a file that is one part of a bigger mode (Avolites keeps pixel zones in a
    # fixture of their own, e.g. RGBW.R20): its channels are a part there
    def is_part(m):
        mine = safe_codes(m, 'follow')
        for _, other in found:
            if other is m or not mine:
                continue
            groups = {}
            for c in other['channels']:
                if c.startswith('part:'):
                    groups.setdefault(c.split(':')[1], []).append(code_for(c, 'follow') if safe_codes(
                        {'channels': [c]}, 'follow') else '?')
            if any(g[i:i + len(mine)] == mine for g in groups.values() for i in range(0, len(g), len(mine))):
                return True
        return False

    modes = []
    for src, m in found:
        if not re.fullmatch(r'\d+ ch', m['label']) and is_part(m):
            notes.append(f'{src}: "{m["label"]}" is one part (zone) of a bigger mode - left out')
        else:
            modes.append((src, m))

    # the same mode in several files: compare them; when they differ in length,
    # the one that has as many channels as the mode says is the complete one
    by_mode = {}
    for src, m in modes:
        key = m['label'] if re.fullmatch(r'\d+ ch', m['label']) else f'{len(m["channels"])} ch'
        n = len(m['channels'])
        if key not in by_mode:
            by_mode[key] = (src, m)
            continue
        src0, m0 = by_mode[key]
        n0, want = len(m0['channels']), int(key.split()[0])
        if n != n0:
            better, worse = ((src, m), (src0, m0)) if n == want else ((src0, m0), (src, m))
            notes.append(f'{key}: {worse[0]} has {len(worse[1]["channels"])} of {want} channels - '
                         f'{better[0]} used')
            by_mode[key] = better
            continue
        a, b = safe_codes(m0), safe_codes(m)
        if a is None or b is None:
            continue
        if a != b:
            diff = [f'ch {i + 1}: {x} / {y}' for i, (x, y) in enumerate(zip(a, b)) if x != y]
            notes.append(f'{key}: {src0} and {src} DIFFER ({", ".join(diff)}) - check which is right')
        else:
            notes.append(f'{key}: {src0} and {src} agree')

    first = lambda k: next((s[k] for s in specs if s.get(k)), None)
    chosen = [by_mode[k][1] for k in sorted(by_mode, key=lambda k: int(re.match(r'\d+', k).group()))]
    cls = first('class')
    if not cls:  # a suggestion from the channels
        all_codes = {c for m in chosen for c in (safe_codes(m) or [])}
        moving = {'02', '03'} <= all_codes
        cls = ('Yoke spot' if moving and all_codes & {'09', '0A'} else 'Yoke wash' if moving
               else 'Led' if all_codes & {'04', '05', '06'} else 'Unknown')
        notes.append(f'class "{cls}" suggested from the channels (no file says)')
    spec = {'manufacturer': first('manufacturer'), 'model': first('model'),
            'class': cls, 'parts': 'off', 'modes': chosen,
            'names_seen': sorted({f'{s.get("manufacturer")} / {s.get("model")}' for s in specs}),
            'notes': notes}
    for n in notes:
        print(n, file=sys.stderr)
    return spec


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['show'] and len(a) >= 2:
        show(a[1], a[2] if len(a) > 2 else None)
    elif a[:1] in (['read'], ['qxf']) and len(a) >= 2:
        print(json.dumps(read(a[1:]), indent=2, ensure_ascii=False))
    elif a[:1] == ['add'] and len(a) >= 2:
        add(json.loads(Path(a[1]).read_text(encoding='utf-8')), '--write' in a)
    else:
        print(__doc__)
