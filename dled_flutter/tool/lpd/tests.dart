// tests.dart -- the LPD tests: a show to upload and the steps to run on it,
// written out as data (lpd/tests/NAME.show + NAME.steps.json) so the C++
// engine's tests can replay exactly the same thing later.
//
// Steps (JSON objects; pb is the 0-based playback index):
//   {"op":"releaseAll"}  {"op":"go","pb":0}  {"op":"release","pb":0}
//   {"op":"flash","pb":0,"ms":500}   {"op":"intensity","pb":0,"value":0.5}
//   {"op":"speed","pb":0,"value":0.0}   {"op":"wait","ms":2000}
//   {"op":"snap","name":"idle"}  -- note the DMX frame now, for the report
//   {"op":"goDown"|"goUp"|"flashDown"|"flashUp","pb":0}  -- a button held
//   {"op":"edit","value":true}  {"op":"select","slots":[0,1]}
//   {"op":"prog","values":{"In":255,"R":128,"Pan":0}}   (programmer sliders 0-255)
//   {"op":"progFx","fx":["intensity","Sinus",100,50,0]}  {"op":"progClear"}
//   {"op":"load","pb":0,"cue":0}

import 'dart:typed_data';

import 'package:dled/core/cue_codec.dart';
import 'package:dled/core/fixture_codes.dart';
import 'package:dled/core/show_file.dart';

import 'tests_more.dart';

typedef Step = Map<String, Object>;

class LpdTest {
  final String name, about;
  final Show show;
  final List<Step> steps;
  const LpdTest(this.name, this.about, this.show, this.steps);
}

/// The probe fixture: one channel per function code the LPU knows (and a few
/// it may not), so one patched fixture shows how every attribute comes out.
const List<(int, String)> probeChannels = [
  (0x01, 'intensity'),
  (0x21, 'intensity fine?'),
  (0x02, 'pan'),
  (0x22, 'pan fine'),
  (0x03, 'tilt'),
  (0x23, 'tilt fine'),
  (0x04, 'red'),
  (0x24, 'red fine?'),
  (0x05, 'green'),
  (0x06, 'blue'),
  (0x07, 'amber'),
  (0x08, 'white'),
  (0x09, 'colour wheel'),
  (0x0A, 'gobo'),
  (0x0B, 'gobo rotation'),
  (0x0C, 'shutter'),
  (0x0D, 'iris'),
  (0x0E, 'frost'),
  (0x0F, 'focus'),
  (0x10, 'prism'),
  (0x11, 'zoom'),
  (0x12, 'custom 1'),
  (0x13, 'UV / custom 2?'),
  (0x14, 'pan/tilt speed'),
  (0x80, 'no fader'),
  (0x00, 'code 00?'),
  (0x15, 'code 15?'),
];

String get probeProfile =>
    probeChannels.map((c) => c.$1.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

ShowFixture probe(int slot, int address, {String name = ''}) => ShowFixture(
      index: slot,
      address: address,
      manufacturer: 'LPD',
      model: 'Probe',
      mode: '${probeChannels.length} ch',
      profile: probeProfile,
      name: name.isEmpty ? 'Probe ${slot + 1}' : name,
    );

/// Every record byte different, so each DMX value tells which byte it came
/// from: attr k (in offset order) = byte at the offset 10 + 12k, the next
/// byte 3 + 11k (cueWith).
Map<String, int> distinctValues() {
  final attrs = kAttrRecordOffset.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
  return {
    for (var k = 0; k < attrs.length; k++) attrs[k].key: (10 + 12 * k) << 8 | (3 + 11 * k),
  };
}

/// A cue with raw [values] per fixture slot: attr -> v, v >> 8 goes to the
/// record byte at the attr's offset, v & 0xff to offset + 1 (raw bytes as
/// the "static" test was recorded with; the LPU reads them as u16 LE).
ShowCue cueWith(Map<int, Map<String, int>> values, {String label = '', int fadeMs = 0, int delayMs = 0}) {
  final blocks = List.generate(4, (_) => Uint8List(blockSize));
  values.forEach((slot, attrs) {
    final base = (slot % 16) * recordSize;
    attrs.forEach((attr, v) {
      final o = kAttrRecordOffset[attr]!;
      blocks[slot ~/ 16][base + o] = v >> 8;
      blocks[slot ~/ 16][base + o + 1] = v & 0xff;
    });
  });
  return ShowCue(
      label: label,
      fadeMs: fadeMs,
      delayMs: delayMs,
      blocks: [for (final b in blocks) b.any((x) => x != 0) ? b : Uint8List(0)]);
}

/// The DMX value a cue record gives a channel with [code] at full
/// (lpd/DMX_ENGINE.md section 2; code 13 = custom 2). Null: no record slot.
int? expectedDmx(Uint8List rec, int code) =>
    code == 0x13 ? recordDmx(rec, 0, 'Custom2') >> 8 : recordDmxForCode(rec, 0, code);

Step wait(int ms) => {'op': 'wait', 'ms': ms};
Step snap(String name) => {'op': 'snap', 'name': name};

final List<LpdTest> lpdTests = [..._basicTests, ...moreTests];

final List<LpdTest> _basicTests = [
  LpdTest(
    'static',
    'Patch and static values: probe 1 at DMX 1 gets a cue with a different '
        'value in every record byte; probe 2 at DMX 101 is in no cue. Idle, the '
        'cue at full, the playback fader at 50 % and 0 %, and after release.',
    Show(
      fixtures: [probe(0, 1), probe(1, 101)],
      playbacks: [
        ShowPlayback(index: 0, label: 'Probe values', cues: [cueWith({0: distinctValues()}, label: 'all')]),
      ],
    ),
    [
      {'op': 'releaseAll'},
      wait(2000),
      snap('idle'),
      {'op': 'go', 'pb': 0},
      wait(2000),
      snap('cue'),
      {'op': 'intensity', 'pb': 0, 'value': 0.5},
      wait(1500),
      snap('fader 50%'),
      {'op': 'intensity', 'pb': 0, 'value': 0.0},
      wait(1500),
      snap('fader 0%'),
      {'op': 'intensity', 'pb': 0, 'value': 1.0},
      wait(1500),
      snap('fader 100%'),
      {'op': 'release', 'pb': 0},
      wait(3000),
      snap('released'),
    ],
  ),
  LpdTest(
    'encode',
    "The apps' cue encoder (encodeCueBlocks) against the LPU: probe 1 with "
        'intensity 200/255, red 50 %, pan full left, tilt 3/4, gobo 1/3; the '
        "report's \"cue\" column is what the encoder means, the snap what the LPU does.",
    Show(
      fixtures: [probe(0, 1)],
      playbacks: [
        ShowPlayback(index: 0, label: 'Encoder', cues: [
          ShowCue(
              label: 'enc',
              blocks: encodeCueBlocks(
                  {'0:In': 200 / 255, '0:R': 0.5, '0:Pan': 0.0, '0:Tilt': 0.75, '0:Go': 1 / 3},
                  const {}, [noFx, noFx, noFx], const [0])),
        ]),
      ],
    ),
    [
      {'op': 'releaseAll'},
      wait(1500),
      {'op': 'go', 'pb': 0},
      wait(2000),
      snap('cue'),
      {'op': 'release', 'pb': 0},
      wait(1500),
      snap('released'),
    ],
  ),
];
