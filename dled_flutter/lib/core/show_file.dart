// show_file.dart -- .show files: read, write, decode cue records. Pure Dart.
//
// Mirrors analysis/lpu/showfile.py; test/core/show_file_test.dart checks that
// both read the same values and write byte-identical files.
//
// XML: <show application version>
//        <system><host>os, ips</host><device>mac ip subnet dhcp pcb_version
//          firmware_version type</device></system>
//        <fixtures><fixture index [label] address manufacturer model [mode] profile
//          [invert_pan invert_tilt swap_pan_tilt virtual_dimmer]/></fixtures>
//        <playbacks><playback index [label intensity gomode repeat speed background
//          exclusive]><cues><cue [label fade delay condition]><blocks><block>base64
// Like the app, attributes are written only when not default. Unknown
// attributes and sections (e.g. <buttons>) are kept and written back.
// Cue times are "HH-MM-SS-FF", FF = hundredths of a second.
// A block holds 16 records x 50 bytes; global fixture index = block * 16 + record.

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'fixture_codes.dart';

const int blockSize = 800;
const int recordSize = 50;
const List<String> goModes = ['Go', 'Toggle', 'Flash', 'Solo'];
const List<String> repeatModes = ['Loop', 'Bounce', 'Random', 'Off'];

const Map<String, Map<int, String>> fxWaves = {
  'intensity': {0: 'None', 1: 'Sine', 2: 'Ramp', 3: 'Inversed ramp', 4: 'Square', 5: 'Random'},
  'position': {0: 'None', 4: 'Square', 5: 'Random', 6: 'Circle', 7: 'Eight', 8: 'Pan', 9: 'Tilt'},
  'colour': {0: 'None', 5: 'Random', 10: 'Rainbow', 11: 'Full Sines', 12: 'Full Twinkle'},
};

// --- times ------------------------------------------------------------------

int parseTimeMs(String? s) {
  if (s == null || s.isEmpty) return 0;
  final parts = s.split('-').map((p) => int.tryParse(p) ?? 0).toList();
  while (parts.length < 4) {
    parts.insert(0, 0);
  }
  final n = parts.length;
  final h = parts[n - 4], m = parts[n - 3], sec = parts[n - 2], ff = parts[n - 1];
  return ((h * 60 + m) * 60 + sec) * 1000 + ff * 10;
}

String formatTimeMs(int ms) {
  final h = ms ~/ 3600000;
  ms %= 3600000;
  final m = ms ~/ 60000;
  ms %= 60000;
  final s = ms ~/ 1000;
  ms %= 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}-${two(m)}-${two(s)}-${two(ms ~/ 10)}';
}

// --- FX ---------------------------------------------------------------------

/// FX speed byte -> UI percent: signed int8, ~1.27 per %; the reference app writes +100 % as 128
/// (we write 127).
int fxSpeedPercent(int b) {
  if (b == 128) return 100;
  return ((b > 128 ? b - 256 : b) / 1.27).round();
}

class FxSlot {
  final int wave, size, speed, phase;
  const FxSlot(this.wave, this.size, this.speed, this.phase);
  bool get active => wave != 0 || size != 0 || speed != 0 || phase != 0;
  List<int> toList() => [wave, size, speed, phase];
}

// --- records ----------------------------------------------------------------

class Record {
  final Uint8List raw;
  Record(this.raw);

  /// The raw u16 at [offset] (little-endian).
  int u16(int offset) => recordU16(raw, 0, offset);
  FxSlot _fx(int o) => FxSlot(raw[o], raw[o + 1], raw[o + 2], raw[o + 3]);

  FxSlot get fxIntensity => _fx(kFxIntensityOffset);
  FxSlot get fxPosition => _fx(kFxPositionOffset);
  FxSlot get fxColour => _fx(kFxColourOffset);
  /// Pan / tilt as 16-bit DMX (32767 = centre, also when not set).
  int get pan => recordDmx(raw, 0, 'Pan');
  int get tilt => recordDmx(raw, 0, 'Tilt');
  int get intensity => u16(16);
  List<int> get rgbaw => [for (final o in const [20, 22, 24, 26, 28]) u16(o)];

  /// Non-zero faders by name ('colour wheel', 'gobo', ... 'custom 2').
  Map<String, int> get attrs => {
        for (final e in kFaderNames.entries)
          if (u16(e.key) != 0) e.value: u16(e.key),
      };

  bool get empty => !raw.any((b) => b != 0);
}

Record decodeRecord(Uint8List block, int record) =>
    Record(Uint8List.fromList(block.sublist(record * recordSize, (record + 1) * recordSize)));

// --- show model -------------------------------------------------------------

class ShowFixture {
  int index;
  int address;
  String manufacturer, model, mode, profile;
  String name; // patch-screen name, XML attribute "label"
  bool invertPan, invertTilt, swapPanTilt, virtualDimmer;
  Map<String, String> extraAttrs;

  ShowFixture({
    required this.index,
    this.address = 0,
    this.manufacturer = '',
    this.model = '',
    this.mode = '',
    this.profile = '',
    this.name = '',
    this.invertPan = false,
    this.invertTilt = false,
    this.swapPanTilt = false,
    this.virtualDimmer = false,
    Map<String, String>? extraAttrs,
  }) : extraAttrs = extraAttrs ?? {};

  /// The fixture definition string the LPU stores (property 0x07 / 0x08).
  String get definition => '"$manufacturer","$model","$mode","$profile"';

  /// DMX function codes in channel order.
  List<int> get codes => [
        for (var i = 0; i + 1 < profile.length; i += 2)
          int.tryParse(profile.substring(i, i + 2), radix: 16) ?? 0,
      ];
}

class ShowCue {
  String label;
  int fadeMs, delayMs;
  bool follow;
  List<Uint8List> blocks; // 4 entries; empty = no data
  Map<String, String> extraAttrs;

  ShowCue({
    this.label = '',
    this.fadeMs = 0,
    this.delayMs = 0,
    this.follow = false,
    List<Uint8List>? blocks,
    Map<String, String>? extraAttrs,
  })  : blocks = blocks ?? List.generate(4, (_) => Uint8List(0)),
        extraAttrs = extraAttrs ?? {};

  Uint8List block(int b) =>
      b < blocks.length && blocks[b].isNotEmpty ? blocks[b] : Uint8List(blockSize);

  Record record(int fixtureIndex) => decodeRecord(block(fixtureIndex ~/ 16), fixtureIndex % 16);
}

class ShowPlayback {
  int index;
  String label;
  double intensity, speed;
  String goMode, repeat;
  bool background, exclusive;
  List<ShowCue> cues;
  Map<String, String> extraAttrs;

  ShowPlayback({
    required this.index,
    this.label = '',
    this.intensity = 1.0,
    this.speed = 0.0,
    this.goMode = 'Go',
    this.repeat = 'Loop',
    this.background = false,
    this.exclusive = false,
    List<ShowCue>? cues,
    Map<String, String>? extraAttrs,
  })  : cues = cues ?? [],
        extraAttrs = extraAttrs ?? {};
}

class Show {
  String application, version;
  Map<String, String> device; // mac ip subnet dhcp pcb_version firmware_version type
  String hostOs;
  List<String> hostIps;
  List<ShowFixture> fixtures;
  List<ShowPlayback> playbacks;
  Map<String, String> rootAttrs; // other <show> attributes, e.g. readonly
  List<XmlElement> extraElements; // unknown sections, e.g. <buttons>, kept verbatim

  Show({
    this.application = 'DLED',
    this.version = showFormatVersion,
    Map<String, String>? device,
    this.hostOs = 'Windows',
    List<String>? hostIps,
    List<ShowFixture>? fixtures,
    List<ShowPlayback>? playbacks,
    Map<String, String>? rootAttrs,
    List<XmlElement>? extraElements,
  })  : device = device ?? {},
        hostIps = hostIps ?? [],
        fixtures = fixtures ?? [],
        playbacks = playbacks ?? [],
        rootAttrs = rootAttrs ?? {},
        extraElements = extraElements ?? [];

  ShowFixture? fixture(int index) {
    for (final f in fixtures) {
      if (f.index == index) return f;
    }
    return null;
  }

  ShowPlayback? playback(int index) {
    for (final p in playbacks) {
      if (p.index == index) return p;
    }
    return null;
  }
}

// --- reading ----------------------------------------------------------------

const _fixtureAttrs = {
  'index', 'address', 'manufacturer', 'model', 'mode', 'profile', 'label',
  'invert_pan', 'invert_tilt', 'swap_pan_tilt', 'virtual_dimmer',
};
const _playbackAttrs = {
  'index', 'label', 'intensity', 'speed', 'gomode', 'repeat', 'background', 'exclusive',
};
const _cueAttrs = {'label', 'fade', 'delay', 'condition'};
const _showChildren = {'system', 'fixtures', 'playbacks'};

Map<String, String> _extra(XmlElement el, Set<String> known) => {
      for (final a in el.attributes)
        if (!known.contains(a.name.qualified)) a.name.qualified: a.value,
    };

double _float(XmlElement el, String name, double dflt) =>
    double.tryParse(el.getAttribute(name) ?? '') ?? dflt;

Iterable<XmlElement> _children(XmlElement el, String tag) => el.childElements.where((c) => c.name.local == tag);

Show parseShow(String xml) {
  final root = XmlDocument.parse(xml).rootElement;
  final show = Show(
    application: root.getAttribute('application') ?? 'DLED',
    version: root.getAttribute('version') ?? '',
    rootAttrs: _extra(root, {'application', 'version'}),
    extraElements: [
      for (final c in root.childElements)
        if (!_showChildren.contains(c.name.local)) c.copy(),
    ],
  );
  for (final system in _children(root, 'system')) {
    for (final dev in _children(system, 'device')) {
      show.device = {for (final c in dev.childElements) c.name.local: c.innerText};
    }
    for (final host in _children(system, 'host')) {
      show.hostOs = _children(host, 'os').map((e) => e.innerText).firstOrNull ?? '';
      show.hostIps = [
        for (final ips in _children(host, 'ips'))
          for (final ip in _children(ips, 'ip')) ip.innerText,
      ];
    }
  }
  for (final f in root.findAllElements('fixture')) {
    show.fixtures.add(ShowFixture(
      index: int.parse(f.getAttribute('index')!),
      address: int.tryParse(f.getAttribute('address') ?? '0') ?? 0,
      manufacturer: f.getAttribute('manufacturer') ?? '',
      model: f.getAttribute('model') ?? '',
      mode: f.getAttribute('mode') ?? '',
      profile: f.getAttribute('profile') ?? '',
      name: f.getAttribute('label') ?? '',
      invertPan: f.getAttribute('invert_pan') == 'true',
      invertTilt: f.getAttribute('invert_tilt') == 'true',
      swapPanTilt: f.getAttribute('swap_pan_tilt') == 'true',
      virtualDimmer: f.getAttribute('virtual_dimmer') == 'true',
      extraAttrs: _extra(f, _fixtureAttrs),
    ));
  }
  for (final pb in root.findAllElements('playback')) {
    final p = ShowPlayback(
      index: int.parse(pb.getAttribute('index')!),
      label: pb.getAttribute('label') ?? '',
      intensity: _float(pb, 'intensity', 1.0),
      speed: _float(pb, 'speed', 0.0),
      goMode: pb.getAttribute('gomode') ?? 'Go',
      repeat: pb.getAttribute('repeat') ?? 'Loop',
      background: (pb.getAttribute('background') ?? 'false') == 'true',
      exclusive: (pb.getAttribute('exclusive') ?? 'false') == 'true',
      extraAttrs: _extra(pb, _playbackAttrs),
    );
    // Real files: <cues><cue><blocks><block>. Hand-made files without the
    // wrapper elements are read too (descendant search).
    for (final cue in pb.findAllElements('cue')) {
      final blocks = [for (final b in cue.findAllElements('block')) _decodeBlock(b.innerText)];
      while (blocks.length < 4) {
        blocks.add(Uint8List(0));
      }
      p.cues.add(ShowCue(
        label: cue.getAttribute('label') ?? '',
        fadeMs: parseTimeMs(cue.getAttribute('fade')),
        delayMs: parseTimeMs(cue.getAttribute('delay')),
        follow: (cue.getAttribute('condition') ?? 'Halt').toLowerCase() == 'follow',
        blocks: blocks.sublist(0, 4),
        extraAttrs: _extra(cue, _cueAttrs),
      ));
    }
    show.playbacks.add(p);
  }
  show.fixtures.sort((a, b) => a.index.compareTo(b.index));
  show.playbacks.sort((a, b) => a.index.compareTo(b.index));
  return show;
}

Uint8List _decodeBlock(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), '');
  return t.isEmpty ? Uint8List(0) : base64Decode(t);
}

// --- writing ----------------------------------------------------------------

/// Write a .show the reference app can open (defaults omitted like the app does).
/// Output is byte-identical to analysis/lpu/showfile.py save_show.
/// The .show format version written into new files: the format the
/// reference app reads (its files carry this number), not DLED's version.
const showFormatVersion = '1.19.0';

String writeShow(Show show) {
  final root = _Node('show', {
    'application': show.application.isEmpty ? 'DLED' : show.application,
    'version': show.version.isEmpty ? showFormatVersion : show.version,
    ...show.rootAttrs,
  });
  final system = root.add(_Node('system'));
  final host = system.add(_Node('host'));
  host.add(_Node('os', {}, show.hostOs));
  final ips = host.add(_Node('ips'));
  for (final ip in show.hostIps) {
    ips.add(_Node('ip', {}, ip));
  }
  final dev = system.add(_Node('device'));
  for (final tag in const ['mac', 'ip', 'subnet', 'dhcp', 'pcb_version', 'firmware_version', 'type']) {
    if (show.device.containsKey(tag)) dev.add(_Node(tag, {}, show.device[tag]));
  }
  final fx = root.add(_Node('fixtures'));
  for (final f in show.fixtures) {
    // Attribute order as the app writes it (pan_tiltt_dimmer.show, 2026-10-23).
    final a = <String, String>{'index': '${f.index}'};
    if (f.name.isNotEmpty) a['label'] = f.name;
    a['address'] = '${f.address}';
    a['manufacturer'] = f.manufacturer;
    a['model'] = f.model;
    if (f.mode.isNotEmpty) a['mode'] = f.mode;
    a['profile'] = f.profile;
    if (f.invertPan) a['invert_pan'] = 'true';
    if (f.invertTilt) a['invert_tilt'] = 'true';
    if (f.swapPanTilt) a['swap_pan_tilt'] = 'true';
    if (f.virtualDimmer) a['virtual_dimmer'] = 'true';
    a.addAll(f.extraAttrs);
    fx.add(_Node('fixture', a));
  }
  final pbs = root.add(_Node('playbacks'));
  for (final p in show.playbacks) {
    final a = <String, String>{'index': '${p.index}'};
    if (p.label.isNotEmpty) a['label'] = p.label;
    if ((p.intensity - 1.0).abs() > 1e-6) a['intensity'] = formatG(p.intensity);
    if (p.goMode != 'Go') a['gomode'] = p.goMode;
    if (p.repeat != 'Loop') a['repeat'] = p.repeat;
    if (p.speed.abs() > 1e-6) a['speed'] = formatG(p.speed);
    if (p.background) a['background'] = 'true';
    if (p.exclusive) a['exclusive'] = 'true';
    a.addAll(p.extraAttrs);
    final pel = pbs.add(_Node('playback', a));
    if (p.cues.isEmpty) continue;
    final cues = pel.add(_Node('cues'));
    for (final c in p.cues) {
      final ca = <String, String>{};
      if (c.label.isNotEmpty) ca['label'] = c.label;
      if (c.fadeMs != 0) ca['fade'] = formatTimeMs(c.fadeMs);
      if (c.delayMs != 0) ca['delay'] = formatTimeMs(c.delayMs);
      if (c.follow) ca['condition'] = 'Follow';
      ca.addAll(c.extraAttrs);
      final blocks = cues.add(_Node('cue', ca)).add(_Node('blocks'));
      for (var b = 0; b < 4; b++) {
        final data = b < c.blocks.length ? c.blocks[b] : Uint8List(0);
        blocks.add(_Node('block', {}, data.any((x) => x != 0) ? base64Encode(data) : null));
      }
    }
  }
  for (final el in show.extraElements) {
    root.add(_Node.fromXml(el));
  }
  final out = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n');
  root.write(out, 0);
  out.write('\n');
  return out.toString();
}

/// Python's "%g": 6 significant digits, trailing zeros removed.
String formatG(double v) {
  if (v == 0) return '0';
  if (v.isNaN) return 'nan';
  if (v.isInfinite) return v > 0 ? 'inf' : '-inf';
  final exp = int.parse(v.toStringAsExponential(5).split('e')[1]);
  if (exp < -4 || exp >= 6) {
    var m = v.toStringAsExponential(5).split('e');
    var mant = m[0].contains('.') ? m[0].replaceFirst(RegExp(r'\.?0+$'), '') : m[0];
    final e = int.parse(m[1]);
    return '${mant}e${e < 0 ? '-' : '+'}${e.abs().toString().padLeft(2, '0')}';
  }
  final s = v.toStringAsFixed(5 - exp < 0 ? 0 : 5 - exp);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// Minimal element tree written like Python's ElementTree with ET.indent(space='    ').
class _Node {
  final String tag;
  final Map<String, String> attrs;
  final String? text;
  final List<_Node> children = [];

  _Node(this.tag, [Map<String, String>? attrs, this.text]) : attrs = attrs ?? {};

  _Node add(_Node child) {
    children.add(child);
    return child;
  }

  factory _Node.fromXml(XmlElement el) {
    final hasChildren = el.childElements.isNotEmpty;
    final text = hasChildren ? null : el.innerText;
    final n = _Node(el.name.qualified, {for (final a in el.attributes) a.name.qualified: a.value},
        text == null || text.isEmpty ? null : text);
    for (final c in el.childElements) {
      n.add(_Node.fromXml(c));
    }
    return n;
  }

  void write(StringBuffer out, int level) {
    out.write('<$tag');
    attrs.forEach((k, v) => out.write(' $k="${_escAttr(v)}"'));
    if (children.isEmpty && (text == null || text!.isEmpty)) {
      out.write(' />');
      return;
    }
    out.write('>');
    if (children.isEmpty) {
      out.write(_escText(text!));
    } else {
      final pad = '    ' * (level + 1);
      for (final c in children) {
        out.write('\n$pad');
        c.write(out, level + 1);
      }
      out.write('\n${'    ' * level}');
    }
    out.write('</$tag>');
  }
}

String _escText(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escAttr(String s) => _escText(s)
    .replaceAll('"', '&quot;')
    .replaceAll('\r', '&#13;')
    .replaceAll('\n', '&#10;')
    .replaceAll('\t', '&#09;');
