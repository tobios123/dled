// tests_more.dart -- the LPD tests that decode the LPU's engine: FX
// generators, fades, the playback fader, fixture flags, cue lists, go modes,
// flash, mixing, the programmer and all 64 fixtures. Each playback of a test
// show holds one case; the steps run them one after the other, with a
// release in between, so one upload covers a whole area.

import 'dart:typed_data';

import 'package:dled/core/cue_codec.dart';
import 'package:dled/core/fixture_codes.dart';
import 'package:dled/core/show_file.dart';

import 'tests.dart';

// --- fixtures ------------------------------------------------------------------

/// In, pan, pan fine, tilt, tilt fine, R, G, B, A, W: 16-bit position.
const String p10 = '01022203230405060708';

/// In, pan, tilt, R, G, B, A, W: 64 of them fill one universe.
const String p8 = '0102030405060708';

ShowFixture fix(int slot, int address, String profile,
        {String name = '', bool invertPan = false, bool invertTilt = false, bool swap = false, bool vdim = false}) =>
    ShowFixture(
      index: slot,
      address: address,
      manufacturer: 'LPD',
      model: 'P${profile.length ~/ 2}',
      mode: '${profile.length ~/ 2} ch',
      profile: profile,
      name: name.isEmpty ? 'F${slot + 1}' : name,
      invertPan: invertPan,
      invertTilt: invertTilt,
      swapPanTilt: swap,
      virtualDimmer: vdim,
    );

/// [n] fixtures with [profile], packed from DMX 1.
List<ShowFixture> row(int n, String profile) =>
    [for (var i = 0; i < n; i++) fix(i, 1 + i * profile.length ~/ 2, profile)];

// --- cues ------------------------------------------------------------------------

/// The 4 FX bytes of one generator (size / phase 0..100 %, speed -100..100 %).
List<int> fxb(String generator, String wave, {double size = 100, double speed = 50, double phase = 0}) =>
    fxBytes(generator, (waveform: wave, size: size, speed: speed, phase: phase));

/// A cue: per slot the values (attr -> 0..1, pan / tilt 0.5 = centre) and the
/// FX bytes of the intensity / position / colour generator ([fx] slot ->
/// (generator index, 4 bytes)).
ShowCue cue(Map<int, Map<String, double>> values,
    {Map<int, List<(int, List<int>)>> fx = const {},
    String label = '',
    int fadeMs = 0,
    int delayMs = 0,
    bool follow = false}) {
  final blocks = encodeCueBlocks(
      {
        for (final e in values.entries)
          for (final v in e.value.entries) '${e.key}:${v.key}': v.value
      },
      {...values.keys},
      [noFx, noFx, noFx],
      const []);
  for (final e in fx.entries) {
    if (blocks[e.key ~/ 16].isEmpty) blocks[e.key ~/ 16] = Uint8List(blockSize);
    for (final (g, bytes) in e.value) {
      blocks[e.key ~/ 16].setRange((e.key % 16) * recordSize + g * 4, (e.key % 16) * recordSize + g * 4 + 4, bytes);
    }
  }
  return ShowCue(label: label, fadeMs: fadeMs, delayMs: delayMs, follow: follow, blocks: blocks);
}

/// [n] slots with the same values.
Map<int, Map<String, double>> all(int n, Map<String, double> v) => {for (var i = 0; i < n; i++) i: v};

/// One generator on [n] slots, the phase spread evenly (like the app does for
/// a selection) unless [spread] is false.
Map<int, List<(int, List<int>)>> fxAll(int n, int generator, String wave,
        {double size = 100, double speed = 50, bool spread = true, double phase = 0}) =>
    {
      for (var i = 0; i < n; i++)
        i: [
          (
            generator,
            fxb(fxGenerators[generator], wave, size: size, speed: speed, phase: spread ? i * 100 / n : phase)
          )
        ]
    };

ShowPlayback pb(int index, String label, List<ShowCue> cues,
        {String goMode = 'Go', String repeat = 'Loop', bool background = false, bool exclusive = false,
        double intensity = 1.0}) =>
    ShowPlayback(
        index: index,
        label: label,
        cues: cues,
        goMode: goMode,
        repeat: repeat,
        background: background,
        exclusive: exclusive,
        intensity: intensity);

// --- steps -------------------------------------------------------------------------

Step go(int p) => {'op': 'go', 'pb': p};
Step rel(int p) => {'op': 'release', 'pb': p};
const Step relAll = {'op': 'releaseAll'};
Step inten(int p, double v) => {'op': 'intensity', 'pb': p, 'value': v};
Step speed(int p, double v) => {'op': 'speed', 'pb': p, 'value': v};
Step btn(String op, int p) => {'op': op, 'pb': p};

/// GO, run [ms], snap, release, settle.
List<Step> run(int p, int ms, {int after = 1500}) => [go(p), wait(ms), snap('pb${p + 1}'), rel(p), wait(after)];

// --- the tests ---------------------------------------------------------------------

const _iWaves = ['Sinus', 'Ramp', 'Inversed Ramp', 'Square', 'Random'];
const _pWaves = ['Circle', 'Eight', 'Square', 'Pan', 'Tilt', 'Random'];
const _cWaves = ['Rainbow', 'Random', 'Full Sinus', 'Full Twinkle'];

final List<LpdTest> moreTests = [
  // FX: intensity --------------------------------------------------------------
  LpdTest(
    'fx_intensity',
    '8 fixtures (P10). pb1-5: each intensity waveform, In 100 %, size 100, '
        'speed 50, phase spread over the 8. pb6 size 50, pb7 In 50 %, pb8 no In '
        'value, pb9 size 25, pb10 Sinus without phase spread.',
    Show(fixtures: row(8, p10), playbacks: [
      for (final (i, w) in _iWaves.indexed) pb(i, w, [cue(all(8, {'In': 1}), fx: fxAll(8, 0, w))]),
      pb(5, 'size 50', [cue(all(8, {'In': 1}), fx: fxAll(8, 0, 'Sinus', size: 50))]),
      pb(6, 'In 50', [cue(all(8, {'In': 0.5}), fx: fxAll(8, 0, 'Sinus'))]),
      pb(7, 'no In', [cue(all(8, {'R': 1}), fx: fxAll(8, 0, 'Sinus'))]),
      pb(8, 'size 25', [cue(all(8, {'In': 1}), fx: fxAll(8, 0, 'Sinus', size: 25))]),
      pb(9, 'no spread', [cue(all(8, {'In': 1}), fx: fxAll(8, 0, 'Sinus', spread: false))]),
    ]),
    [relAll, wait(1000), for (var p = 0; p < 10; p++) ...run(p, 10000)],
  ),
  // FX: speed ----------------------------------------------------------------------
  LpdTest(
    'fx_speed',
    '2 fixtures (P10), Sinus on intensity, In 100 %. pb1-7: FX speed 5, 10, 25, '
        '50, 75, 100, -50 %. pb8: speed 50 % and the playback speed knob at '
        '+0.5, -0.5, +1, -1, 0. pb9: phase 25 % on both (no spread).',
    Show(fixtures: row(2, p10), playbacks: [
      for (final (i, sp) in [5.0, 10.0, 25.0, 50.0, 75.0, 100.0, -50.0].indexed)
        pb(i, 'speed $sp', [cue(all(2, {'In': 1}), fx: fxAll(2, 0, 'Sinus', speed: sp))]),
      pb(7, 'knob', [cue(all(2, {'In': 1}), fx: fxAll(2, 0, 'Sinus'))]),
      pb(8, 'phase 25', [cue(all(2, {'In': 1}), fx: fxAll(2, 0, 'Sinus', spread: false, phase: 25))]),
    ]),
    [
      relAll,
      wait(1000),
      ...run(0, 25000),
      ...run(1, 15000),
      for (var p = 2; p < 7; p++) ...run(p, 8000),
      go(7),
      wait(6000),
      for (final k in [0.5, -0.5, 1.0, -1.0, 0.0]) ...[speed(7, k), wait(6000)],
      rel(7),
      wait(1500),
      ...run(8, 6000),
    ],
  ),
  // FX: the speed knob and direction -------------------------------------------------------
  LpdTest(
    'fx_knob',
    'F1 (P10). pb1: Ramp at FX speed 50 %, the playback speed knob from '
        '-1 to +1 in steps of 0.1, 4 s each. pb2 Ramp at FX speed -50 %. pb3 Sinus '
        'at FX speed 5 %, pb4 at 1 % (25 s each). pb5 / pb6 Circle at 100 / 25 %, '
        'pb7 Rainbow at 100 %. 4 fixtures, 30 / 30 / 20 / 15 s: pb8 colour Random, '
        'pb9 Full Twinkle, pb10 intensity Random, pb11 position Random.',
    Show(fixtures: row(4, p10), playbacks: [
      pb(0, 'knob', [cue(all(1, {'In': 0.5}), fx: fxAll(1, 0, 'Ramp', size: 50))]),
      pb(1, 'ramp -50', [cue(all(1, {'In': 0.5}), fx: fxAll(1, 0, 'Ramp', size: 50, speed: -50))]),
      pb(2, 'speed 5', [cue(all(1, {'In': 1}), fx: fxAll(1, 0, 'Sinus', speed: 5))]),
      pb(3, 'speed 1', [cue(all(1, {'In': 1}), fx: fxAll(1, 0, 'Sinus', speed: 1))]),
      pb(4, 'circle 100', [cue(all(1, {'In': 1}), fx: fxAll(1, 1, 'Circle', speed: 100))]),
      pb(5, 'circle 25', [cue(all(1, {'In': 1}), fx: fxAll(1, 1, 'Circle', speed: 25))]),
      pb(6, 'rainbow 100', [cue(all(1, {'In': 1}), fx: fxAll(1, 2, 'Rainbow', speed: 100))]),
      pb(7, 'colour random', [cue(all(4, {'In': 1}), fx: fxAll(4, 2, 'Random'))]),
      pb(8, 'twinkle', [cue(all(4, {'In': 1}), fx: fxAll(4, 2, 'Full Twinkle'))]),
      pb(9, 'int random', [cue(all(4, {'In': 1}), fx: fxAll(4, 0, 'Random'))]),
      pb(10, 'pos random', [cue(all(4, {'In': 1}), fx: fxAll(4, 1, 'Random'))]),
    ]),
    [
      relAll,
      wait(2000),
      go(0),
      wait(4000),
      for (var k = -10; k <= 10; k++) ...[speed(0, k / 10), wait(4000)],
      speed(0, 0),
      rel(0),
      wait(1500),
      ...run(1, 6000),
      ...run(2, 25000),
      ...run(3, 25000),
      ...run(4, 8000),
      ...run(5, 12000),
      ...run(6, 10000),
      ...run(7, 30000),
      ...run(8, 30000),
      ...run(9, 20000),
      ...run(10, 15000),
    ],
  ),
  // FX: position ---------------------------------------------------------------------
  LpdTest(
    'fx_position',
    '8 fixtures (P10, 16-bit pan / tilt). pb1-6: each position waveform at the '
        'centre, size 100, speed 50, phase spread. pb7 Circle size 50, pb8 Circle '
        'around pan 25 % / tilt 75 %, pb9 Circle without spread, pb10 Circle and In.',
    Show(fixtures: row(8, p10), playbacks: [
      for (final (i, w) in _pWaves.indexed) pb(i, w, [cue(all(8, {'In': 1}), fx: fxAll(8, 1, w))]),
      pb(6, 'size 50', [cue(all(8, {'In': 1}), fx: fxAll(8, 1, 'Circle', size: 50))]),
      pb(7, 'offset', [cue(all(8, {'In': 1, 'Pan': 0.25, 'Tilt': 0.75}), fx: fxAll(8, 1, 'Circle'))]),
      pb(8, 'no spread', [cue(all(8, {'In': 1}), fx: fxAll(8, 1, 'Circle', spread: false))]),
      pb(9, 'circle+sinus', [
        cue(all(8, {'In': 1}), fx: {
          for (var i = 0; i < 8; i++)
            i: [(0, fxb('intensity', 'Sinus', phase: i * 12.5)), (1, fxb('position', 'Circle', phase: i * 12.5))]
        })
      ]),
    ]),
    [relAll, wait(1000), for (var p = 0; p < 10; p++) ...run(p, 10000)],
  ),
  // FX: colour -------------------------------------------------------------------------
  LpdTest(
    'fx_colour',
    '8 fixtures (P10). pb1-4: each colour waveform, In 100 %, no colour, size '
        '100, speed 50, phase spread. pb5 Rainbow on red, pb6 Rainbow size 50, '
        'pb7 Full Sinus on white 50 %, pb8 Rainbow without In.',
    Show(fixtures: row(8, p10), playbacks: [
      for (final (i, w) in _cWaves.indexed) pb(i, w, [cue(all(8, {'In': 1}), fx: fxAll(8, 2, w))]),
      pb(4, 'on red', [cue(all(8, {'In': 1, 'R': 1}), fx: fxAll(8, 2, 'Rainbow'))]),
      pb(5, 'size 50', [cue(all(8, {'In': 1}), fx: fxAll(8, 2, 'Rainbow', size: 50))]),
      pb(6, 'on white', [cue(all(8, {'In': 1, 'W': 0.5}), fx: fxAll(8, 2, 'Full Sinus'))]),
      pb(7, 'no In', [cue(all(8, {'G': 0.2}), fx: fxAll(8, 2, 'Rainbow'))]),
    ]),
    [relAll, wait(1000), for (var p = 0; p < 8; p++) ...run(p, 10000)],
  ),
  // fades --------------------------------------------------------------------------------
  LpdTest(
    'fades',
    'Probe (27 ch) at DMX 1. pb1: cue 1 every attribute 20 % (snap), cue 2 80 % '
        'fade 2 s, cue 3 20 % fade 2 s delay 1 s, then release. pb2: 80 % fade 3 s '
        'from idle, release. pb3 the same at playback speed +0.5, pb4 at -0.5. pb5: '
        'GO to cue 2 in the middle of cue 1\'s 3 s fade.',
    Show(fixtures: [probe(0, 1)], playbacks: [
      pb(0, 'cue list', [
        cue({0: _every(0.2)}, label: 'a'),
        cue({0: _every(0.8)}, label: 'b', fadeMs: 2000),
        cue({0: _every(0.2)}, label: 'c', fadeMs: 2000, delayMs: 1000),
      ]),
      for (final i in [1, 2, 3]) pb(i, 'fade 3 s', [cue({0: _every(0.8)}, fadeMs: 3000)]),
      pb(4, 'interrupt', [
        cue({0: _every(1.0)}, fadeMs: 3000),
        cue({0: _every(0.0, pan: 0.0)}, fadeMs: 3000),
      ]),
    ]),
    [
      relAll,
      wait(1000),
      go(0), wait(1500), snap('a'),
      go(0), wait(3000), snap('b'),
      go(0), wait(4500), snap('c'),
      rel(0), wait(3000), snap('released'),
      go(1), wait(4000), rel(1), wait(4000),
      speed(2, 0.5), wait(300), go(2), wait(8000), rel(2), wait(6000), speed(2, 0), wait(300),
      speed(3, -0.5), wait(300), go(3), wait(8000), rel(3), wait(6000), speed(3, 0), wait(300),
      go(4), wait(1500), go(4), wait(4500), rel(4), wait(4000),
    ],
  ),
  // playback fader, fixture flags ---------------------------------------------------------
  LpdTest(
    'fader_flags',
    'F1 P10 at 1; F2 RGB at 11; F3 RGB with virtual dimmer at 14; F4 P10 invert '
        'pan at 21; F5 P10 invert tilt at 31; F6 P10 swap pan / tilt at 41. One cue: '
        'In 100 %, R 100 %, G 50 %, B 25 %, pan 25 %, tilt 75 %. The playback '
        'fader from 100 % down to 0 % in steps of 10 %.',
    Show(fixtures: [
      fix(0, 1, p10),
      fix(1, 11, '040506'),
      fix(2, 14, '040506', vdim: true),
      fix(3, 21, p10, invertPan: true),
      fix(4, 31, p10, invertTilt: true),
      fix(5, 41, p10, swap: true),
    ], playbacks: [
      pb(0, 'all', [cue(all(6, {'In': 1, 'R': 1, 'G': 0.5, 'B': 0.25, 'Pan': 0.25, 'Tilt': 0.75}))]),
    ]),
    [
      relAll,
      wait(1000),
      go(0),
      wait(1500),
      snap('100%'),
      for (var k = 9; k >= 0; k--) ...[inten(0, k / 10), wait(800), snap('${k * 10}%')],
      inten(0, 0.25),
      wait(800),
      snap('25%'),
      inten(0, 1.0),
      wait(800),
      rel(0),
      wait(1500),
      snap('released'),
    ],
  ),
  // cue lists -------------------------------------------------------------------------------
  LpdTest(
    'cuelist',
    'F1 P10. Cues: 1 red, 2 green, 3 blue (In 100 %). pb1 Loop, pb2 Bounce, pb3 '
        'Off, pb4 Random: GO again and again. pb5: cues 1 and 2 with follow, fade '
        '0.5 s, one GO. pb6: a cue with delay 1 s. pb7: 2 cues, repeat Off, GO past '
        'the end.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      for (final (i, r) in ['Loop', 'Bounce', 'Off', 'Random'].indexed) pb(i, r, _rgb(), repeat: r),
      pb(4, 'follow', _rgb(fadeMs: 500, follow: true)),
      pb(5, 'delay', [cue({0: {'In': 1, 'W': 1}}, delayMs: 1000)]),
      pb(6, 'end', _rgb().sublist(0, 2), repeat: 'Off'),
    ]),
    [
      relAll,
      wait(1000),
      for (final (p, n) in [(0, 5), (1, 6), (2, 5), (3, 9)]) ...[
        for (var k = 0; k < n; k++) ...[go(p), wait(700), snap('pb${p + 1} go${k + 1}')],
        rel(p),
        wait(800),
      ],
      go(4), wait(6000), snap('follow'), rel(4), wait(800),
      go(5), wait(2000), rel(5), wait(800),
      go(6), wait(700), go(6), wait(700), go(6), wait(700), snap('past end'), go(6), wait(700), rel(6), wait(800),
    ],
  ),
  // go modes and flash ---------------------------------------------------------------------------
  LpdTest(
    'gomodes',
    'F1, F2 P10. pb1 Toggle (F1 red), pb2 Flash mode (F1 green), pb3 Solo (F1 '
        'blue), pb4 Go (F2 white), pb5 Go with fader 30 % (F1 red, In 50 %): the '
        'FLASH button on it idle and running, pb6 Go with a 2 s fade: FLASH.',
    Show(fixtures: row(2, p10), playbacks: [
      pb(0, 'toggle', [cue({0: {'In': 1, 'R': 1}})], goMode: 'Toggle'),
      pb(1, 'flash', [cue({0: {'In': 1, 'G': 1}})], goMode: 'Flash'),
      pb(2, 'solo', [cue({0: {'In': 1, 'B': 1}})], goMode: 'Solo'),
      pb(3, 'go', [cue({1: {'In': 1, 'W': 1}})]),
      pb(4, 'flash btn', [cue({0: {'In': 0.5, 'R': 1}})], intensity: 0.3),
      pb(5, 'flash fade', [cue({0: {'In': 1, 'G': 1}}, fadeMs: 2000)]),
    ]),
    [
      relAll,
      wait(1000),
      go(0), wait(1000), snap('toggle on'), go(0), wait(1000), snap('toggle off'), rel(0), wait(500),
      btn('goDown', 1), wait(1000), snap('flash held'), btn('goUp', 1), wait(1000), snap('flash let go'),
      rel(1), wait(500),
      go(3), wait(800), go(2), wait(1000), snap('solo'), relAll, wait(800),
      go(3), wait(800), btn('flashDown', 2), wait(1000), snap('solo flashed'), btn('flashUp', 2), wait(1000),
      snap('solo flash up'), relAll, wait(800),
      btn('flashDown', 4), wait(1000), snap('flash idle'), btn('flashUp', 4), wait(1000), snap('flash idle up'),
      go(4), wait(1000), snap('running 30%'), btn('flashDown', 4), wait(1000), snap('flash running'),
      btn('flashUp', 4), wait(1000), snap('flash running up'), rel(4), wait(800),
      btn('flashDown', 5), wait(600), snap('flash fade 0.6'), wait(1500), snap('flash fade 2.1'),
      btn('flashUp', 5), wait(600), snap('flash fade up'), wait(2000), rel(5), wait(800),
    ],
  ),
  // mixing -----------------------------------------------------------------------------------------
  LpdTest(
    'mixing',
    'F1 P10. pb1 In 60 % red pan 25 %; pb2 In 30 % green blue 50 % pan 75 %; '
        'pb3 background In 80 % blue; pb4 exclusive In 40 % white; pb5 In 90 % only.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      pb(0, 'a', [cue({0: {'In': 0.6, 'R': 1, 'Pan': 0.25}})]),
      pb(1, 'b', [cue({0: {'In': 0.3, 'G': 1, 'B': 0.5, 'Pan': 0.75}})]),
      pb(2, 'bg', [cue({0: {'In': 0.8, 'B': 1}})], background: true),
      pb(3, 'excl', [cue({0: {'In': 0.4, 'W': 1}})], exclusive: true),
      pb(4, 'in only', [cue({0: {'In': 0.9}})]),
    ]),
    [
      relAll,
      wait(1000),
      go(0), wait(800), snap('a'), go(1), wait(800), snap('a+b'), rel(1), wait(800), snap('a, b released'),
      go(1), wait(800), go(0), wait(800), snap('b then a'), inten(0, 0), wait(800), snap('a fader 0'),
      inten(0, 1), wait(300), relAll, wait(800),
      go(2), wait(800), snap('bg'), go(0), wait(800), snap('bg+a'), rel(0), wait(800), snap('bg, a released'),
      relAll, wait(800),
      go(0), wait(800), go(1), wait(800), go(3), wait(800), snap('a+b+excl'), rel(3), wait(800),
      snap('excl released'), relAll, wait(800),
      go(0), wait(800), go(4), wait(800), snap('a+in only'), rel(0), wait(800), snap('in only alone'),
      relAll, wait(800),
    ],
  ),
  // programmer -----------------------------------------------------------------------------------
  LpdTest(
    'programmer',
    'F1, F2 P10; pb1 runs F1 red In 50 %. EDIT open, F1 selected: programmer In '
        '100 %, green, pan; then F2 selected (not in a cue): In, blue; an FX; CLEAR; '
        'EDIT closed. Then LOAD of pb1 cue 1.',
    Show(fixtures: row(2, p10), playbacks: [
      pb(0, 'red', [cue({0: {'In': 0.5, 'R': 1}})]),
    ]),
    [
      relAll,
      {'op': 'progClear'},
      wait(1000),
      go(0), wait(1000), snap('pb1'),
      {'op': 'edit', 'value': true}, wait(800), snap('edit open'),
      {'op': 'select', 'slots': [0]}, wait(800), snap('F1 selected'),
      {'op': 'prog', 'values': {'In': 255}}, wait(800), snap('prog In'),
      {'op': 'prog', 'values': {'G': 255}}, wait(800), snap('prog G'),
      {'op': 'prog', 'values': {'Pan': 0, 'Tilt': 255}}, wait(800), snap('prog pan'),
      {'op': 'select', 'slots': [1]}, wait(800), snap('F2 selected'),
      {'op': 'prog', 'values': {'In': 128, 'B': 255}}, wait(800), snap('F2 prog'),
      {'op': 'progFx', 'fx': ['intensity', 'Sinus', 100, 50, 0]}, wait(4000), snap('F2 fx'),
      {'op': 'edit', 'value': false}, wait(800), snap('edit closed'),
      {'op': 'progClear'}, wait(800), snap('cleared'),
      {'op': 'edit', 'value': true}, wait(500), {'op': 'load', 'pb': 0, 'cue': 0}, wait(1000), snap('loaded'),
      rel(0), wait(800), snap('loaded, pb1 released'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, wait(800), snap('end'),
    ],
  ),
  // follow-up questions ------------------------------------------------------------------------------
  LpdTest(
    'extra',
    'F1 P10 at 1; F2 (In, In fine, pan, pan fine, R) at 11. pb1: In 50 % red pan '
        '75 % fade 2 s, GO from released 3 times. pb2 Bounce, 8 GOs. pb3 / pb4 '
        'exclusive (red / green), pb5 normal (blue). pb6: cue 1 snap, cue 2 fade '
        '1 s delay 1 s. pb7: one cue delay 1 s fade 1 s from released. pb8 Solo '
        '(F1 white) with GO held, pb9 (F2) running.',
    Show(fixtures: [fix(0, 1, p10), fix(1, 11, '0121022204')], playbacks: [
      pb(0, 'fade in', [cue(all(2, {'In': 0.5, 'R': 1, 'Pan': 0.75}), fadeMs: 2000)]),
      pb(1, 'bounce', _rgb(), repeat: 'Bounce'),
      pb(2, 'excl a', [cue({0: {'In': 0.5, 'R': 1}})], exclusive: true),
      pb(3, 'excl b', [cue({0: {'In': 0.5, 'G': 1}})], exclusive: true),
      pb(4, 'normal', [cue({0: {'In': 0.5, 'B': 1}})]),
      pb(5, 'delay list', [
        cue({0: {'In': 1, 'R': 1}}),
        cue({0: {'In': 1, 'G': 1}}, fadeMs: 1000, delayMs: 1000),
      ]),
      pb(6, 'delay', [cue({0: {'In': 1, 'B': 1}}, fadeMs: 1000, delayMs: 1000)]),
      pb(7, 'solo', [cue({0: {'In': 1, 'W': 1}})], goMode: 'Solo'),
      pb(8, 'other', [cue({1: {'In': 1, 'R': 1}})]),
    ]),
    [
      relAll,
      wait(1000),
      for (var k = 0; k < 3; k++) ...[go(0), wait(3000), rel(0), wait(3000)],
      for (var k = 0; k < 8; k++) ...[go(1), wait(700), snap('bounce go${k + 1}')],
      rel(1), wait(800),
      go(4), wait(800), go(2), wait(800), snap('normal+excl a'), go(3), wait(800), snap('+excl b'),
      rel(3), wait(800), snap('excl b released'), relAll, wait(800),
      go(5), wait(1000), go(5), wait(500), snap('delay 0.5'), wait(1000), snap('delay 1.5'), wait(1500),
      snap('delay 3'), rel(5), wait(1500),
      go(6), wait(500), snap('d 0.5'), wait(1000), snap('d 1.5'), wait(1500), snap('d 3'), rel(6), wait(2000),
      go(8), wait(800), btn('goDown', 7), wait(1000), snap('solo held'), btn('goUp', 7), wait(1000),
      snap('solo up'), relAll, wait(800),
    ],
  ),
  LpdTest(
    'follow_delay',
    'F1 P10. pb1: cues red / green / blue, fade 0.5 s, delay 1 s, cues 1 and 2 '
        'follow: one GO. pb2: the same without follow, GO 3 times 3 s apart.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      pb(0, 'follow delay', [
        for (final (i, c) in ['R', 'G', 'B'].indexed)
          cue({0: {'In': 1, c: 1}}, fadeMs: 500, delayMs: 1000, follow: i < 2),
      ]),
      pb(1, 'delay', [
        for (final c in ['R', 'G', 'B']) cue({0: {'In': 1, c: 1}}, fadeMs: 500, delayMs: 1000),
      ]),
    ]),
    [relAll, wait(1000), go(0), wait(8000), rel(0), wait(1500), for (var k = 0; k < 3; k++) ...[go(1), wait(3000)], rel(1),
      wait(1000)],
  ),
  // the open points of DMX_ENGINE.md ---------------------------------------------------------------
  LpdTest(
    'open',
    'F1, F2 P10 at 1 / 11; F3 In R Rfine G Gfine B Bfine at 21; F4 P10 invert pan '
        'at 31; F5 profile 01 15 04 05 at 41, F6 01 00 04 05 at 46 (unknown codes in '
        'the middle). Playbacks 41-51 (never used before): intensity memory, fader '
        'during a fade, FX with fades, HTP with FX, invert + Circle, colour FX with '
        'fine channels; then the programmer: FX, LOAD with and without CLEAR.',
    Show(fixtures: [
      fix(0, 1, p10),
      fix(1, 11, p10),
      fix(2, 21, '01042405250626'),
      fix(3, 31, p10, invertPan: true),
      fix(4, 41, '01150405'),
      fix(5, 46, '01000405'),
    ], playbacks: [
      pb(40, 'mem list', [
        cue({0: {'In': 0.8, 'R': 1}}, fadeMs: 2000),
        cue({0: {'In': 0.3, 'R': 1}}, fadeMs: 2000),
      ]),
      pb(41, 'mem cut', [cue({0: {'In': 1, 'G': 1}}, fadeMs: 4000)]),
      pb(42, 'mem fader', [cue({0: {'In': 1, 'B': 1}}, fadeMs: 2000)]),
      pb(43, 'fader fade', [cue({1: {'In': 1, 'W': 1}}, fadeMs: 4000)]),
      pb(44, 'fx fade', [
        cue({0: {'In': 1}, 1: {'In': 1}},
            fx: {
              0: [(0, fxb('intensity', 'Sinus'))],
              1: [(0, fxb('intensity', 'Sinus', phase: 50)), (1, fxb('position', 'Circle'))]
            },
            fadeMs: 4000)
      ]),
      pb(45, 'fx in', [
        cue({0: {'In': 1, 'R': 1}}),
        cue({0: {'In': 1, 'R': 1}}, fx: {0: [(0, fxb('intensity', 'Sinus'))]}, fadeMs: 3000),
      ]),
      pb(46, 'static 50', [cue({0: {'In': 0.5}})]),
      pb(47, 'invert circle', [
        cue({0: {'In': 1}, 3: {'In': 1}},
            fx: {0: [(1, fxb('position', 'Circle'))], 3: [(1, fxb('position', 'Circle'))]})
      ]),
      pb(48, 'fine colour', [cue({2: {'In': 1}}, fx: {2: [(2, fxb('colour', 'Full Sinus', speed: 10))]})]),
      pb(49, 'unknown codes', [cue({4: {'In': 1, 'R': 0.5, 'G': 0.25}, 5: {'In': 1, 'R': 0.5, 'G': 0.25}})]),
      pb(50, 'load me', [cue({0: {'In': 0.4, 'G': 1, 'Pan': 0.25}})]),
    ]),
    [
      relAll,
      wait(1000),
      // intensity memory
      go(40), wait(3000), snap('mem c1'), go(40), wait(3000), snap('mem c2'), rel(40), wait(3000),
      go(40), wait(3000), snap('mem again c1'), rel(40), wait(3000),
      go(41), wait(1000), rel(41), wait(5000), go(41), wait(5000), snap('cut again'), rel(41), wait(5000),
      go(42), wait(3000), inten(42, 0.5), wait(1000), rel(42), wait(3000), inten(42, 1), wait(300),
      go(42), wait(3000), snap('fader again'), rel(42), wait(3000),
      relAll, wait(1000), go(40), wait(3000), snap('after release all'), rel(40), wait(3000),
      // fader during a fade
      go(43), wait(1000), inten(43, 0.5), wait(1000), inten(43, 1), wait(3000), rel(43), wait(5000),
      // FX and fades
      go(44), wait(6000), rel(44), wait(6000),
      go(45), wait(2000), go(45), wait(5000), rel(45), wait(4000),
      go(46), wait(1000), go(44), wait(6000), snap('htp fx'), rel(44), wait(5000), rel(46), wait(1000),
      go(47), wait(5000), rel(47), wait(1000),
      go(48), wait(12000), rel(48), wait(1000),
      go(49), wait(1000), snap('unknown codes'), rel(49), wait(1000),
      // the programmer
      {'op': 'edit', 'value': true}, {'op': 'progClear'}, wait(500),
      {'op': 'select', 'slots': [0, 1]}, {'op': 'prog', 'values': {'In': 128}},
      {'op': 'progFx', 'fx': ['intensity', 'Sinus', 100, 50, 0]}, wait(4000), snap('prog fx'),
      {'op': 'progFx', 'fx': ['position', 'Circle', 100, 50, 0]}, wait(5000), snap('prog circle'),
      {'op': 'load', 'pb': 50, 'cue': 0}, wait(1500), snap('load, programmer full'),
      {'op': 'progClear'}, wait(500), {'op': 'load', 'pb': 50, 'cue': 0}, wait(1500), snap('load after clear'),
      {'op': 'edit', 'value': false}, wait(800), snap('edit closed'),
      {'op': 'edit', 'value': true}, wait(800), snap('edit reopened'),
      {'op': 'progClear'}, wait(800), snap('cleared in edit'),
      {'op': 'edit', 'value': false}, wait(500),
    ],
  ),
  LpdTest(
    'load',
    'F1 P10. LOAD (EDIT open, after CLEAR) of playbacks 1, 16, 32, 33, 41, 64, '
        'each with its own cue (In and a different level of red).',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      for (final (k, p) in [0, 15, 31, 32, 40, 63].indexed) pb(p, 'load ${p + 1}', [cue({0: {'In': 1, 'R': (k + 1) / 6}})]),
    ]),
    [
      relAll,
      {'op': 'edit', 'value': true},
      wait(500),
      for (final p in [0, 15, 31, 32, 40, 63]) ...[
        {'op': 'progClear'},
        wait(500),
        {'op': 'load', 'pb': p, 'cue': 0},
        wait(1000),
        snap('load pb${p + 1}'),
      ],
      {'op': 'progClear'},
      {'op': 'edit', 'value': false},
    ],
  ),
  LpdTest(
    'load_when',
    'F1 P10. Which LOAD the LPU answers: pb2 idle, pb2 idle with F1 selected, '
        'pb1 while it runs, pb2 while pb3 runs (red 33 / 67 / 100 % for pb1-3).',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      for (var p = 0; p < 3; p++) pb(p, 'load ${p + 1}', [cue({0: {'In': 1, 'R': (p + 1) / 3}})]),
    ]),
    [
      relAll,
      {'op': 'edit', 'value': true}, wait(500),
      {'op': 'load', 'pb': 1, 'cue': 0}, wait(1000), snap('idle'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, wait(500),
      {'op': 'edit', 'value': true}, {'op': 'select', 'slots': [0]}, wait(500),
      {'op': 'load', 'pb': 1, 'cue': 0}, wait(1000), snap('idle, F1 selected'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, wait(500),
      go(0), wait(1000), {'op': 'edit', 'value': true}, wait(500),
      {'op': 'load', 'pb': 0, 'cue': 0}, wait(1000), snap('pb1 running'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, relAll, wait(500),
      go(2), wait(1000), {'op': 'edit', 'value': true}, wait(500),
      {'op': 'load', 'pb': 1, 'cue': 0}, wait(1000), snap('pb2 while pb3 runs'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, relAll, wait(500),
    ],
  ),
  LpdTest(
    'load_prog',
    'F1 P10. The one LOAD that worked (follow_delay): pb1 running, EDIT, F1 '
        'selected and set, EDIT closed, CLEAR (with EDIT closed: kept), EDIT, LOAD pb1.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      pb(0, 'red', [cue({0: {'In': 0.5, 'R': 1}})]),
    ]),
    [
      relAll, wait(500),
      go(0), wait(1000),
      {'op': 'edit', 'value': true}, wait(500),
      {'op': 'select', 'slots': [0]}, wait(500),
      {'op': 'prog', 'values': {'In': 255, 'G': 255}}, wait(800), snap('prog'),
      {'op': 'edit', 'value': false}, wait(800),
      {'op': 'progClear'}, wait(800),
      {'op': 'edit', 'value': true}, wait(500), snap('edit again'),
      {'op': 'load', 'pb': 0, 'cue': 0}, wait(1000), snap('loaded'),
      rel(0), wait(800), snap('loaded, pb1 released'),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, wait(800),
    ],
  ),
  LpdTest(
    'memory_flash',
    'F1 P10. Do Flash / Solo go modes and the FLASH button use and set the '
        'intensity memory? Each cue In 80 %, fade 3 s, on a playback not used '
        'since the power cycle. pb50 Flash (R) and pb51 Solo (G): GO held 4 s, '
        'let go, GO held again. pb52 Go (B): FLASH 1 s, then GO.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      pb(49, 'flash', [cue({0: {'In': 0.8, 'R': 1}}, fadeMs: 3000)], goMode: 'Flash'),
      pb(50, 'solo', [cue({0: {'In': 0.8, 'G': 1}}, fadeMs: 3000)], goMode: 'Solo'),
      pb(51, 'go', [cue({0: {'In': 0.8, 'B': 1}}, fadeMs: 3000)]),
    ]),
    [
      relAll, wait(1000),
      for (final p in [49, 50]) ...[
        btn('goDown', p), wait(250), snap('pb${p + 1} held 0.25'), wait(3750), snap('pb${p + 1} held 4'),
        btn('goUp', p), wait(4000),
        btn('goDown', p), wait(250), snap('pb${p + 1} again 0.25'), wait(1750), btn('goUp', p), wait(4000),
      ],
      btn('flashDown', 51), wait(250), snap('pb52 flash 0.25'), wait(750), btn('flashUp', 51), wait(4000),
      go(51), wait(250), snap('pb52 go 0.25'), wait(3750), snap('pb52 go 4'), rel(51), wait(4000),
    ],
  ),
  LpdTest(
    'clear_closed',
    'F1, F2 P10. What CLEAR with EDIT closed keeps: F1 In 100 % R, F2 In 50 % G '
        'set in EDIT; (a) EDIT closed and opened, no CLEAR; (b) closed, CLEAR, '
        'opened (F2 selected last); (c) set again with F1 selected last, closed, '
        'CLEAR, opened; (d) CLEAR in EDIT.',
    Show(fixtures: [fix(0, 1, p10), fix(1, 11, p10)], playbacks: [
      pb(0, 'dummy', [cue({0: {'In': 0.1}})]),
    ]),
    [
      relAll,
      for (final last in [1, 0]) ...[
        {'op': 'edit', 'value': true}, wait(500),
        for (final s in last == 1 ? [0, 1] : [1, 0]) ...[
          {'op': 'select', 'slots': [s]}, wait(300),
          {'op': 'prog', 'values': s == 0 ? {'In': 255, 'R': 255} : {'In': 128, 'G': 255}}, wait(500),
        ],
        snap('set, F${last + 1} last'),
        if (last == 1) ...[
          {'op': 'edit', 'value': false}, wait(800), snap('a closed'),
          {'op': 'edit', 'value': true}, wait(800), snap('a reopened'),
        ],
        {'op': 'edit', 'value': false}, wait(800),
        {'op': 'progClear'}, wait(800), snap('${last == 1 ? 'b' : 'c'} cleared closed'),
        {'op': 'edit', 'value': true}, wait(800), snap('${last == 1 ? 'b' : 'c'} reopened'),
        {'op': 'progClear'}, wait(800), snap('${last == 1 ? 'b' : 'd'} cleared in edit'),
        {'op': 'edit', 'value': false}, wait(800),
      ],
    ],
  ),
  LpdTest(
    'live_edit',
    'F1, F2 P10. Edits while playing, as the app sends them: pb1 (F1 R / G / B) '
        'on cue 1, INSERT a cue after it, GO onto the new (empty) cue and on, '
        'DELETE the cue it is on, GO; pb2 (F2 W) on, SWAP pb1 / pb2 while both '
        'run, GO; INSERT pb3 cue 2 and RECORD F1 (In 100 %, W) into it, GO through pb3.',
    Show(fixtures: [fix(0, 1, p10), fix(1, 11, p10)], playbacks: [
      pb(0, 'rgb', [cue({0: {'In': 1, 'R': 1}}), cue({0: {'In': 1, 'G': 1}}), cue({0: {'In': 1, 'B': 1}})]),
      pb(1, 'white', [cue({1: {'In': 1, 'W': 1}})]),
      pb(2, 'record', [cue({1: {'In': 0.5, 'R': 1}})]),
    ]),
    [
      relAll, wait(500),
      go(0), wait(800), snap('pb1 c1'),
      {'op': 'insertCue', 'pb': 0, 'at': 1}, wait(800), snap('inserted'),
      go(0), wait(800), snap('on the new cue'),
      go(0), wait(800), snap('next (G)'),
      {'op': 'deleteCue', 'pb': 0, 'cue': 2}, wait(800), snap('current deleted'),
      go(0), wait(800), snap('go after delete'),
      go(1), wait(800), snap('pb2 on'),
      {'op': 'swap', 'pb': 0, 'with': 1}, wait(800), snap('swapped'),
      go(0), wait(800), snap('go slot 1 after swap'),
      go(1), wait(800), snap('go slot 2 after swap'),
      relAll, wait(800),
      {'op': 'edit', 'value': true}, wait(300),
      {'op': 'select', 'slots': [0]}, wait(300),
      {'op': 'prog', 'values': {'In': 255, 'W': 255}}, wait(300),
      // the LPU records only into a cue that exists: INSERT it first
      {'op': 'insertCue', 'pb': 2, 'at': 1}, wait(300),
      {'op': 'record', 'pb': 2, 'cue': 1}, wait(500),
      {'op': 'progClear'}, {'op': 'edit', 'value': false}, wait(800),
      go(2), wait(800), snap('pb3 c1'),
      go(2), wait(800), snap('pb3 recorded c2'),
      relAll, wait(800),
    ],
  ),
  LpdTest(
    'memory_reset',
    'Run as the first thing after a power cycle. Playbacks 41-43 '
        'remember 80 % / 100 % / 100 % from the "open" test (2026-10-27). Each gets '
        'a cue In 50 % red, fade 3 s: a jump to 204 / 255 / 255 first = the memory '
        'survived the power cycle; a fade from 0 = it was reset.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      for (final p in [40, 41, 42]) pb(p, 'mem ${p + 1}', [cue({0: {'In': 0.5, 'R': 1}}, fadeMs: 3000)]),
    ]),
    [
      for (final p in [40, 41, 42]) ...[go(p), wait(250), snap('pb${p + 1} +0.25 s'), wait(3750), rel(p), wait(4000)],
    ],
  ),
  LpdTest(
    'random_long',
    '8 fixtures (P10), In 100 %, phase spread, speed 50 %: pb1 intensity Random, '
        'pb2 colour Random, pb3 Full Twinkle (90 s each), pb4 intensity Random at '
        'speed 100 % (60 s): how often a random event comes and what it does.',
    Show(fixtures: row(8, p10), playbacks: [
      pb(0, 'int random', [cue(all(8, {'In': 1}), fx: fxAll(8, 0, 'Random'))]),
      pb(1, 'col random', [cue(all(8, {'In': 1}), fx: fxAll(8, 2, 'Random'))]),
      pb(2, 'twinkle', [cue(all(8, {'In': 1}), fx: fxAll(8, 2, 'Full Twinkle'))]),
      pb(3, 'int random 100', [cue(all(8, {'In': 1}), fx: fxAll(8, 0, 'Random', speed: 100))]),
    ]),
    [relAll, wait(1000), ...run(0, 90000), ...run(1, 90000), ...run(2, 90000), ...run(3, 60000)],
  ),
  LpdTest(
    'colour_mix',
    'F1 P10, F2 probe (27 ch) at 21. Two normal playbacks set the same '
        'attributes to different values: pb1 red 80 % green 20 % pan 25 % gobo 80 %, '
        'pb2 red 30 % green 60 % pan 75 % gobo 30 % (both In 50 %). HTP or LTP for '
        'colour, wheels, position? Then pb3 background with red 50 %.',
    Show(fixtures: [fix(0, 1, p10), probe(1, 21)], playbacks: [
      pb(0, 'a', [cue(all(2, {'In': 0.5, 'R': 0.8, 'G': 0.2, 'Pan': 0.25, 'Go': 0.8, 'Col': 0.8}))]),
      pb(1, 'b', [cue(all(2, {'In': 0.5, 'R': 0.3, 'G': 0.6, 'Pan': 0.75, 'Go': 0.3, 'Col': 0.3}))]),
      pb(2, 'bg', [cue(all(2, {'In': 0.4, 'R': 0.5}))], background: true),
    ]),
    [
      relAll, wait(1000),
      go(0), wait(800), snap('a'), go(1), wait(800), snap('a then b'), rel(1), wait(800), snap('b released'),
      rel(0), wait(800),
      go(1), wait(800), go(0), wait(800), snap('b then a'), relAll, wait(800),
      go(2), wait(800), go(0), wait(800), snap('bg then a'), go(1), wait(800), snap('bg a b'), relAll, wait(800),
      go(0), wait(800), go(2), wait(800), snap('a then bg'), relAll, wait(800),
      rel(2), wait(800),
    ],
  ),
  LpdTest(
    'codes',
    'Idle and cue values of the function codes the library does not use: one '
        'fixture with codes 14-1F, 20, 34-3F, 40, 7F, 80, 81, FF (40 channels) at '
        'DMX 1; pb1 sets every record attribute to a different value.',
    Show(fixtures: [
      fix(0, 1, [for (final c in [for (var c = 0x14; c <= 0x20; c++) c, for (var c = 0x34; c <= 0x40; c++) c, 0x7F, 0x80, 0x81, 0xFF]) c.toRadixString(16).padLeft(2, '0')].join().toUpperCase()),
    ], playbacks: [
      pb(0, 'values', [cueWith({0: distinctValues()})]),
    ]),
    [relAll, wait(1500), snap('idle'), go(0), wait(1500), snap('cue'), rel(0), wait(1000), snap('released')],
  ),
  // all 64 fixtures ---------------------------------------------------------------------------------
  LpdTest(
    'all64',
    '64 fixtures P8 (In, pan, tilt, R, G, B, A, W) at 1, 9 ... 505: all 512 '
        'channels. pb1: per fixture i In (i+1)/64, R i*4, G 255-i*4, pan i/63, tilt '
        '1-i/63. pb2 intensity Sinus, pb3 Rainbow, pb4 Circle, each phase spread '
        'over the 64.',
    Show(fixtures: row(64, p8), playbacks: [
      pb(0, 'values', [
        cue({
          for (var i = 0; i < 64; i++)
            i: {
              'In': (i + 1) / 64,
              'R': i * 4 / 255,
              'G': (255 - i * 4) / 255,
              'Pan': i / 63,
              'Tilt': 1 - i / 63,
            }
        })
      ]),
      pb(1, 'sinus', [cue(all(64, {'In': 1}), fx: fxAll(64, 0, 'Sinus'))]),
      pb(2, 'rainbow', [cue(all(64, {'In': 1}), fx: fxAll(64, 2, 'Rainbow'))]),
      pb(3, 'circle', [cue(all(64, {'In': 1}), fx: fxAll(64, 1, 'Circle'))]),
    ]),
    [relAll, wait(1000), ...run(0, 2000), for (var p = 1; p < 4; p++) ...run(p, 10000)],
  ),
  LpdTest(
    'knob_follow',
    'F1 P10. The speed knob on follow cues (2026-10-29: it scales fade + '
        'delay until the next cue, not the DMX fade). pb1 R / G / B follow, '
        'delay 2 s, fade 0: knob 0, +0.5, -0.5, +1, -1 (stands), 0 while it '
        'runs. pb2 the same with fade 2 s, delay 0: knob +1 (the fades are cut '
        'short), then 0.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [
      pb(0, 'delay', [
        for (final c in ['R', 'G', 'B']) cue({0: {'In': 1, c: 1}}, label: c, delayMs: 2000, follow: true)
      ]),
      pb(1, 'fade', [
        for (final c in ['R', 'G', 'B']) cue({0: {'In': 1, c: 1}}, label: c, fadeMs: 2000, follow: true)
      ]),
    ]),
    [
      relAll, speed(0, 0), speed(1, 0), wait(800),
      go(0), wait(4500),
      speed(0, 0.5), wait(2000),
      speed(0, -0.5), wait(10000),
      speed(0, 1.0), wait(2000),
      speed(0, -1.0), wait(4000),
      speed(0, 0), wait(4500),
      relAll, wait(800),
      speed(1, 1.0), wait(300), go(1), wait(3000),
      speed(1, 0), wait(5000),
      relAll, speed(0, 0), speed(1, 0), wait(800),
    ],
  ),
  LpdTest(
    'release_go',
    'F1 P10. GO while a playback releases (2026-10-29: the LPU goes on with '
        'the next cue, our box started cue 1). pb1 R / G / B, fade 2 s, Loop: '
        'GO (R), release, GO halfway -> ?; GO to B, release, GO halfway -> ?; '
        'release, wait until released, GO -> R.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [pb(0, 'rgb', _rgb(fadeMs: 2000))]),
    [
      relAll, wait(800),
      go(0), wait(2500), snap('R'),
      rel(0), wait(1000), snap('R releasing'),
      go(0), wait(2500), snap('GO while releasing R'),
      go(0), wait(2500), snap('next'),
      rel(0), wait(1000),
      go(0), wait(2500), snap('GO while releasing that'),
      rel(0), wait(3000), snap('released'),
      go(0), wait(2500), snap('GO after the release'),
      relAll, wait(2500),
    ],
  ),
  LpdTest(
    'pb_props',
    'Six P10, each lit by one playback. Exclusive: pb1, pb2 (same row), pb9 '
        '(next row), pb64 (last row) exclusive, pb3 not: does one release the '
        'others, also over rows ("banks")? Repeat Off: pb4 two follow cues, '
        'delay 0.5 s: released at the end or staying?',
    Show(fixtures: [for (var i = 0; i < 6; i++) fix(i, 1 + 10 * i, p10)], playbacks: [
      pb(0, 'ex1', [cue({0: {'In': 1, 'R': 1}})], exclusive: true),
      pb(1, 'ex2', [cue({1: {'In': 1, 'R': 1}})], exclusive: true),
      pb(2, 'plain', [cue({4: {'In': 1, 'R': 1}})]),
      pb(3, 'off', [cue({5: {'In': 1, 'R': 1}}, delayMs: 500, follow: true), cue({5: {'In': 1, 'G': 1}}, delayMs: 500, follow: true)], repeat: 'Off'),
      pb(7, 'ex8', [cue({1: {'In': 1, 'G': 1}})], exclusive: true),
      pb(8, 'ex9', [cue({2: {'In': 1, 'R': 1}})], exclusive: true),
      pb(15, 'ex16', [cue({3: {'In': 1, 'G': 1}})], exclusive: true),
      pb(63, 'ex64', [cue({3: {'In': 1, 'R': 1}})], exclusive: true),
    ]),
    [
      relAll, wait(800),
      go(0), wait(500), snap('pb1'),
      go(1), wait(500), snap('pb2 same row'),
      go(8), wait(500), snap('pb9 next row'),
      go(63), wait(500), snap('pb64 last row'),
      go(2), wait(500), snap('pb3 not exclusive'),
      relAll, wait(800),
      go(3), wait(3000), snap('Off, 3 s later'),
      go(3), wait(1500), snap('Off, GO again'),
      relAll, wait(800),
      go(0), wait(500), go(7), wait(500), snap('pb1 then pb8'),
      go(8), wait(500), go(15), wait(500), snap('pb9 then pb16'),
      relAll, wait(800),
    ],
  ),
  LpdTest(
    'flash_solo',
    'Flash and Solo side by side, with pb1 (F1 red, pan) and pb2 (F2, on cue 2 '
        'green) running. pb3 Flash / pb4 Solo: F3 / F4 R G B, held twice. pb5 / '
        'pb6: on F1, white In 50 %. pb7 / pb8: GO on pb9 (F5) / pb10 (F6) during '
        'the hold. pb11 / pb12: fade 1 s. pb13 / pb14: fader 30 %.',
    () {
      final rgb = (int f, {int fadeMs = 0}) =>
          [for (final c in ['R', 'G', 'B']) cue({f: {'In': 1, c: 1}}, label: c, fadeMs: fadeMs)];
      return Show(fixtures: [for (var i = 0; i < 6; i++) fix(i, 1 + 10 * i, p10)], playbacks: [
        pb(0, 'run1', [cue({0: {'In': 1, 'R': 1, 'Pan': 0.25}})]),
        pb(1, 'run2', rgb(1)),
        pb(2, 'flash', rgb(2), goMode: 'Flash'),
        pb(3, 'solo', rgb(3), goMode: 'Solo'),
        pb(4, 'flash F1', [cue({0: {'In': 0.5, 'W': 1}})], goMode: 'Flash'),
        pb(5, 'solo F1', [cue({0: {'In': 0.5, 'W': 1}})], goMode: 'Solo'),
        pb(6, 'flash+', [cue({2: {'In': 1, 'W': 1}})], goMode: 'Flash'),
        pb(7, 'solo+', [cue({3: {'In': 1, 'W': 1}})], goMode: 'Solo'),
        pb(8, 'late1', [cue({4: {'In': 1, 'R': 1}})]),
        pb(9, 'late2', [cue({5: {'In': 1, 'R': 1}})]),
        pb(10, 'flash fade', rgb(4, fadeMs: 1000), goMode: 'Flash'),
        pb(11, 'solo fade', rgb(5, fadeMs: 1000), goMode: 'Solo'),
        pb(12, 'flash 30', [cue({4: {'In': 1, 'B': 1}})], goMode: 'Flash', intensity: 0.3),
        pb(13, 'solo 30', [cue({5: {'In': 1, 'B': 1}})], goMode: 'Solo', intensity: 0.3),
      ]);
    }(),
    [
      relAll, wait(800),
      go(0), wait(500), go(1), wait(300), go(1), wait(500), snap('running'),
      btn('goDown', 2), wait(800), snap('Flash held'), btn('goUp', 2), wait(800), snap('Flash let go'),
      btn('goDown', 2), wait(800), snap('Flash held again'), btn('goUp', 2), wait(800),
      btn('goDown', 3), wait(800), snap('Solo held'), btn('goUp', 3), wait(800), snap('Solo let go'),
      btn('goDown', 3), wait(800), snap('Solo held again'), btn('goUp', 3), wait(800),
      btn('goDown', 4), wait(800), snap('Flash on F1'), btn('goUp', 4), wait(800), snap('after Flash on F1'),
      btn('goDown', 5), wait(800), snap('Solo on F1'), btn('goUp', 5), wait(800), snap('after Solo on F1'),
      btn('goDown', 6), wait(500), go(8), wait(500), snap('GO pb9 in Flash'), btn('goUp', 6), wait(800),
      snap('after that Flash'), rel(8), wait(500),
      btn('goDown', 7), wait(500), go(9), wait(500), snap('GO pb10 in Solo'), btn('goUp', 7), wait(800),
      snap('after that Solo'), rel(9), wait(500),
      btn('goDown', 10), wait(500), snap('Flash fade 0.5 s'), wait(1000), snap('Flash fade 1.5 s'), btn('goUp', 10),
      wait(500), snap('Flash let go 0.5 s'), wait(1000), snap('Flash let go 1.5 s'),
      btn('goDown', 11), wait(500), snap('Solo fade 0.5 s'), wait(1000), snap('Solo fade 1.5 s'), btn('goUp', 11),
      wait(500), snap('Solo let go 0.5 s'), wait(1000), snap('Solo let go 1.5 s'),
      btn('goDown', 12), wait(800), snap('Flash fader 30'), btn('goUp', 12), wait(800),
      btn('goDown', 13), wait(800), snap('Solo fader 30'), btn('goUp', 13), wait(800),
      relAll, wait(2500),
    ],
  ),
  LpdTest(
    'go_hold',
    'F1 P10. Go mode: does a cue start when GO is pressed or when it is let go, '
        'and after how long a hold not at all (2026-10-28: GO held 1 s did '
        'nothing)? pb1 R / G / B (Loop, fade 0): GO held 1 s, quick GO, then GO '
        'held 0.1 / 0.2 / 0.3 / 0.4 / 0.5 / 0.7 s on the running playback.',
    Show(fixtures: [fix(0, 1, p10)], playbacks: [pb(0, 'go', _rgb())]),
    [
      relAll, wait(800),
      btn('goDown', 0), wait(1000), snap('held 1 s'), btn('goUp', 0), wait(1000), snap('let go'),
      go(0), wait(1000), snap('quick GO'),
      for (final ms in [100, 200, 300, 400, 500, 700, 800, 900, 1000, 1500]) ...[
        btn('goDown', 0), wait(ms ~/ 2), snap('${ms}ms down'), wait(ms - ms ~/ 2), btn('goUp', 0), wait(800),
        snap('${ms}ms up'),
      ],
      relAll, wait(800),
    ],
  ),
];

/// Every record attribute of the probe at [v] (pan / tilt too unless given).
Map<String, double> _every(double v, {double? pan}) => {
      for (final a in kAttrRecordOffset.keys) a: v,
      if (pan != null) 'Pan': pan,
    };

List<ShowCue> _rgb({int fadeMs = 0, bool follow = false}) => [
      for (final (i, c) in ['R', 'G', 'B'].indexed)
        cue({0: {'In': 1, c: 1}}, label: c, fadeMs: fadeMs, follow: follow && i < 2),
    ];
