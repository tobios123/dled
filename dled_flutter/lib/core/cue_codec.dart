// cue_codec.dart -- cue records and the LPU programmer, shared by the Flutter
// app and the light page (pure Dart, no Flutter).
//
// A cue is 4 blocks of 16 x 50-byte records, one record per fixture slot:
// FX generators at bytes 0 / 4 / 8 ([waveform, size, speed, phase]), the
// channel values as u16 little-endian at kAttrRecordOffset, pan / tilt signed
// around the centre (fixture_codes.dart recordDmx / setRecordDmx).
// Values here are 0.0..1.0 = DMX 0..65535; pan / tilt 0.5 = the centre.
//
// The LPU's programmer has 17 attributes (FINDINGS 20.5a):
//   0 intensity      float 0..1
//   1 / 3 / 5        intensity / position / colour FX: the 4 FX bytes
//   2 position       2 floats pan, tilt, -1..+1
//   4 colour         5 x u16 little-endian R, G, B, A, W
//   6-16             floats 0..1: colour wheel, shutter, gobo, gobo rotation,
//                    prism, focus, iris, frost, zoom, custom 1, custom 2
// UV has no programmer attribute (the reference app cannot set it either).
// The EDIT page keeps sliders 0-255 (pan / tilt 0-255, 128 = centre).

import 'dart:typed_data';

import 'fixture_codes.dart';
import 'frame.dart' show tFloat;
import 'show_file.dart' show ShowCue, blockSize, recordSize;

/// One FX generator as the EDIT page shows it: size / phase 0..100 %,
/// speed -100..100 %.
typedef FxValues = ({String waveform, double size, double speed, double phase});

const FxValues noFx = (waveform: 'None', size: 0, speed: 0, phase: 0);

/// FX generators in cue / programmer order.
const List<String> fxGenerators = ['intensity', 'position', 'colour'];

/// Waveform names per generator -> waveform id.
const Map<String, Map<String, int>> fxWaves = {
  'intensity': {'None': 0, 'Sinus': 1, 'Ramp': 2, 'Inversed Ramp': 3, 'Square': 4, 'Random': 5},
  'position': {'None': 0, 'Circle': 6, 'Eight': 7, 'Square': 4, 'Pan': 8, 'Tilt': 9, 'Random': 5},
  'colour': {'None': 0, 'Rainbow': 10, 'Random': 5, 'Full Sinus': 11, 'Full Twinkle': 12},
};

/// UI FX speed (-100..100 %) -> signed byte, +100 % = 127. (The reference app
/// writes +100 % as 128, which the LPU takes as -128: the FX runs backwards,
/// lpd/DMX_ENGINE.md 7.)
int fxSpeedByte(double pct) {
  // not rounded to whole percent first: a byte read from a cue (12 = 9.45 %)
  // must come back the same (it came back as 11)
  final p = pct.clamp(-100.0, 100.0);
  return (p * 1.27).round() & 0xff;
}

/// FX speed byte -> UI percent (signed, about 1.27 per %; 127 = +100 %, and
/// 128, from shows made with the reference app, too).
double fxSpeedFromByte(int b) {
  if (b == 128) return 100.0;
  final s = b > 128 ? b - 256 : b;
  return s / 127.0 * 100.0;
}

/// The 4 bytes of one FX generator, as in a cue record and the programmer.
List<int> fxBytes(String generator, FxValues fx) {
  final id = fxWaves[generator]![fx.waveform] ?? 0;
  if (id == 0 && fx.size == 0 && fx.speed == 0 && fx.phase == 0) return [0, 0, 0, 0];
  return [
    id,
    (fx.size * 2.55).round().clamp(0, 255),
    fxSpeedByte(fx.speed),
    (fx.phase * 2.55).round().clamp(0, 255),
  ];
}

/// The inverse of [fxBytes]; an unknown waveform id reads as 'None'.
FxValues fxFromBytes(String generator, List<int> b) {
  final names = {for (final e in fxWaves[generator]!.entries) e.value: e.key};
  return (
    waveform: names[b[0]] ?? 'None',
    size: b[1] / 255.0 * 100.0,
    speed: fxSpeedFromByte(b[2]),
    phase: b[3] / 255.0 * 100.0,
  );
}

/// Encode a cue: [channels] 'slot:attr' -> 0.0..1.0, [fx] the intensity /
/// position / colour generator. The FX go to [slots] (the cue's fixtures);
/// when those are not known, to the slots with values, and a pure-FX cue to
/// every patched fixture. Empty blocks come back empty.
List<Uint8List> encodeCueBlocks(Map<String, double> channels, Set<int> slots, List<FxValues> fx,
    Iterable<int> patchedSlots, {Map<int, List<FxValues>> slotFx = const {}}) {
  final blocks = List.generate(4, (_) => Uint8List(blockSize));
  final withValues = <int>{};
  channels.forEach((key, value) {
    final sep = key.indexOf(':');
    final slot = int.tryParse(key.substring(0, sep < 0 ? 0 : sep));
    final offset = kAttrRecordOffset[key.substring(sep + 1)];
    if (slot == null || offset == null || slot < 0 || slot > 63) return;
    setRecordDmx(blocks[slot ~/ 16], (slot % 16) * recordSize, key.substring(sep + 1),
        (value.clamp(0.0, 1.0) * 65535).round());
    withValues.add(slot);
  });
  final fxSlots = slots.isNotEmpty ? slots : (withValues.isEmpty ? patchedSlots : withValues);
  const offsets = [kFxIntensityOffset, kFxPositionOffset, kFxColourOffset];
  for (final slot in fxSlots) {
    if (slot < 0 || slot > 63) continue;
    final rec = blocks[slot ~/ 16];
    final base = (slot % 16) * recordSize;
    final own = slotFx[slot] ?? fx; // a fixture's own FX, or the cue's
    for (var g = 0; g < 3; g++) {
      rec.setRange(base + offsets[g], base + offsets[g] + 4, fxBytes(fxGenerators[g], own[g]));
    }
  }
  return [for (final b in blocks) b.any((x) => x != 0) ? b : Uint8List(0)];
}

/// What a cue holds, straight from its records: the values 'slot:attr' ->
/// 0.0..1.0, the slots with any data (the fixtures LOAD selects), and per
/// generator the FX of the first slot that has one.
({Map<String, double> channels, Set<int> slots, List<FxValues> fx}) decodeCue(ShowCue cue) {
  final channels = <String, double>{};
  final slots = <int>{};
  final fx = List<FxValues?>.filled(3, null);
  const offsets = [kFxIntensityOffset, kFxPositionOffset, kFxColourOffset];
  for (var slot = 0; slot < 64; slot++) {
    final block = cue.block(slot ~/ 16);
    final base = (slot % 16) * recordSize;
    if (block.length < base + recordSize) continue;
    if (!block.sublist(base, base + recordSize).any((x) => x != 0)) continue;
    slots.add(slot);
    for (final attr in kAttrRecordOffset.keys) {
      // a slot left at zero is not part of the cue (for pan / tilt: the centre)
      if (recordU16(block, base, kAttrRecordOffset[attr]!) != 0) {
        channels['$slot:$attr'] = recordDmx(block, base, attr) / 65535;
      }
    }
    for (var g = 0; g < 3; g++) {
      final b = block.sublist(base + offsets[g], base + offsets[g] + 4);
      if (fx[g] == null && (b[0] != 0 || b[1] != 0 || b[2] != 0)) fx[g] = fxFromBytes(fxGenerators[g], b);
    }
  }
  return (channels: channels, slots: slots, fx: [for (final f in fx) f ?? noFx]);
}

// --- programmer ---------------------------------------------------------------

/// Value types of the programmer attributes (as the LPU echoes them).
const int tFx = 0x07, tPosition = 0x06, tColour = 0x08;

const List<String> colourKeys = ['R', 'G', 'B', 'A', 'W'];

/// EDIT slider -> attribute 6-16.
const Map<String, int> otherAttrs = {
  'Col': 6, 'Sh': 7, 'Go': 8, 'Rota': 9, 'Prism': 10, 'Focus': 11,
  'Iris': 12, 'Frost': 13, 'Zoom': 14, 'Custom': 15, 'Custom2': 16,
};

typedef ProgrammerWrite = ({int attr, int type, Uint8List body});

Uint8List _float(double v) => Uint8List(4)..buffer.asByteData().setFloat32(0, v, Endian.little);

/// The attribute writes for the sliders in [changed] ('Pan' / 'Tilt' for the
/// joystick). [attrs] holds every slider 0-255.
List<ProgrammerWrite> sliderWrites(Map<String, double> attrs, double pan, double tilt, Iterable<String> changed) {
  final out = <ProgrammerWrite>[];
  final keys = changed.toSet();
  double v(String k) => ((attrs[k] ?? 0) / 255).clamp(0.0, 1.0);
  if (keys.contains('In')) out.add((attr: 0, type: tFloat, body: _float(v('In'))));
  if (keys.contains('Pan') || keys.contains('Tilt')) {
    final b = ByteData(8)
      ..setFloat32(0, ((pan - 127.5) / 127.5).clamp(-1.0, 1.0), Endian.little)
      ..setFloat32(4, ((tilt - 127.5) / 127.5).clamp(-1.0, 1.0), Endian.little);
    out.add((attr: 2, type: tPosition, body: b.buffer.asUint8List()));
  }
  if (keys.any(colourKeys.contains)) {
    final b = ByteData(10);
    for (final (i, k) in colourKeys.indexed) {
      b.setUint16(i * 2, (v(k) * 65535).round(), Endian.little);
    }
    out.add((attr: 4, type: tColour, body: b.buffer.asUint8List()));
  }
  for (final k in keys) {
    final a = otherAttrs[k];
    if (a != null) out.add((attr: a, type: tFloat, body: _float(v(k))));
  }
  return out;
}

/// The write for one FX generator ('intensity' / 'position' / 'colour').
ProgrammerWrite fxWrite(String generator, FxValues fx) => (
      attr: switch (generator) { 'intensity' => 1, 'position' => 3, _ => 5 },
      type: tFx,
      body: Uint8List.fromList(fxBytes(generator, fx)),
    );

/// What a programmer attribute value means for the EDIT page (the inverse of
/// [sliderWrites] / [fxWrite]): slider values 0-255 by key ('Pan' / 'Tilt'
/// for the joystick), or one FX generator. Null when it is not understood.
({Map<String, double> sliders, ({String generator, FxValues fx})? fx})? decodeProgrammer(int attr, Uint8List body) {
  final d = ByteData.sublistView(body);
  double f(int at) => d.getFloat32(at, Endian.little);
  switch (attr) {
    case 0 when body.length >= 4:
      return (sliders: {'In': (f(0) * 255).clamp(0.0, 255.0)}, fx: null);
    case 1 || 3 || 5 when body.length >= 4:
      final g = attr == 1 ? 'intensity' : (attr == 3 ? 'position' : 'colour');
      return (sliders: const <String, double>{}, fx: (generator: g, fx: fxFromBytes(g, body)));
    case 2 when body.length >= 8:
      return (
        sliders: {
          'Pan': (f(0) * 127.5 + 127.5).clamp(0.0, 255.0),
          'Tilt': (f(4) * 127.5 + 127.5).clamp(0.0, 255.0),
        },
        fx: null
      );
    case 4 when body.length >= 10:
      return (
        sliders: {
          for (final (i, k) in colourKeys.indexed) k: d.getUint16(i * 2, Endian.little) / 65535 * 255,
        },
        fx: null
      );
  }
  for (final e in otherAttrs.entries) {
    if (e.value == attr && body.length >= 4) {
      return (sliders: {e.key: (f(0) * 255).clamp(0.0, 255.0)}, fx: null);
    }
  }
  return null;
}
