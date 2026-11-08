// show_loader_test.dart
// Unit tests for ShowLoader.loadFromString() and ParsedShow.applyToModel().
// Tests are pure Dart (no Flutter widgets) so they run fast with `flutter test`.

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/models/show_model.dart';

// ---------------------------------------------------------------------------
// Helper: build a minimal 800-byte block with known channel values at
// fixture record 0 (Red=200, Green=150, Blue=100, Intensity=255, Shutter=128).
// Record offsets (core/fixture_codes.dart): 0x01=16, 0x04=20, 0x05=22, 0x06=24, 0x0C=34
// ---------------------------------------------------------------------------
String _buildBlock800({
  int fixtureRecord = 0,
  int red = 200,
  int green = 150,
  int blue = 100,
  int intensity = 255,
  int shutter = 128,
  // FX intensity slot (bytes 0-3 of record): waveform=1 (Sinus), size=128, speed=fxSpeed, phase=64
  bool withFx = false,
  int fxSpeed = 13, // signed int8: 13 = +10% (as in fx_rainbow_..._speed=10 capture)
}) {
  final raw = Uint8List(800);
  final base = fixtureRecord * 50;

  // Channel values (8-bit) in the high byte of each u16 at its record offset
  // (little-endian: offset + 1)
  raw[base + 17] = intensity; // 0x01 Intensity
  raw[base + 21] = red;       // 0x04 Red
  raw[base + 23] = green;     // 0x05 Green
  raw[base + 25] = blue;      // 0x06 Blue
  raw[base + 35] = shutter;   // 0x0C Shutter

  if (withFx) {
    // Intensity FX slot: bytes 0-3 of the record
    raw[base + 0] = 1;   // waveform = 1 (Sinus)
    raw[base + 1] = 128; // size
    raw[base + 2] = fxSpeed; // speed, signed int8
    raw[base + 3] = 64;  // phase
  }

  return base64Encode(raw);
}

// ---------------------------------------------------------------------------
// Helper: build a minimal valid .show XML string
// ---------------------------------------------------------------------------
String _buildShowXml({
  String version = '1.19.0',
  bool withSystem = false,
  List<Map<String, String>> fixtures = const [],
  List<Map<String, dynamic>> playbacks = const [],
}) {
  final buf = StringBuffer();
  buf.write('<show version="$version">');

  if (withSystem) {
    buf.write('<system><device>'
        '<type>DialogLPU-1</type>'
        '<firmware_version>2.0.0</firmware_version>'
        '<ip>192.168.1.10</ip>'
        '</device></system>');
  }

  for (final f in fixtures) {
    buf.write('<fixture');
    f.forEach((k, v) { buf.write(' $k="$v"'); });
    buf.write('/>');
  }

  for (final pb in playbacks) {
    buf.write('<playback'
        ' index="${pb['index']}"'
        ' label="${pb['label']}"'
        ' intensity="${pb['intensity'] ?? 1}"'
        ' gomode="${pb['gomode'] ?? 'go'}"'
        ' repeat="${pb['repeat'] ?? 'loop'}"'
        ' speed="${pb['speed'] ?? 1.0}">');

    for (final cue in (pb['cues'] as List<Map<String, dynamic>>? ?? [])) {
      buf.write('<cue'
          ' label="${cue['label'] ?? ''}"'
          ' fade="${cue['fade'] ?? '00-00-00-00'}"'
          ' delay="${cue['delay'] ?? '00-00-00-00'}"'
          ' condition="${cue['condition'] ?? 'halt'}">');
      if (cue['block'] != null) {
        buf.write('<block>${cue['block']}</block>');
      }
      buf.write('</cue>');
    }

    buf.write('</playback>');
  }

  buf.write('</show>');
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  group('ShowLoader.loadFromString', () {
    test('returns null for invalid XML', () {
      final result = ShowLoader.loadFromString('not xml at all');
      expect(result, isNull);
    });

    test('parses minimal show with no fixtures or playbacks', () {
      final xml = _buildShowXml(version: '1.19.0');
      final show = ShowLoader.loadFromString(xml);
      expect(show, isNotNull);
      expect(show!.appVersion, equals('1.19.0'));
      expect(show.fixtures, isEmpty);
      expect(show.playbacks, isEmpty);
    });

    test('parses system device block', () {
      final xml = _buildShowXml(withSystem: true);
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.deviceType, equals('DialogLPU-1'));
      expect(show.firmwareVersion, equals('2.0.0'));
      expect(show.deviceIp, equals('192.168.1.10'));
    });

    test('parses fixture attributes', () {
      final xml = _buildShowXml(fixtures: [
        {
          'index': '0',
          'address': '1',
          'universe': '0',
          'manufacturer': 'Stairville',
          'model': 'M400',
          'mode': '6ch',
          'class': 'Led',
          'profile': '010405060C80', // In, R, G, B, Sh, Custom
        }
      ]);
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.fixtures.length, equals(1));
      final f = show.fixtures.first;
      expect(f.index, equals(0));
      expect(f.address, equals(1));
      expect(f.universe, equals(0));
      expect(f.manufacturer, equals('Stairville'));
      expect(f.model, equals('M400'));
      expect(f.mode, equals('6ch'));
      expect(f.fixtureClass, equals('Led'));
      // Profile '010405060C80' => [0x01, 0x04, 0x05, 0x06, 0x0C, 0x80]
      expect(f.functionCodes, equals([0x01, 0x04, 0x05, 0x06, 0x0C, 0x80]));
      expect(f.channelCount, equals(6));
    });

    test('parses multiple fixtures', () {
      final xml = _buildShowXml(fixtures: [
        {'index': '0', 'address': '1',  'universe': '0', 'manufacturer': 'A', 'model': 'M1', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        {'index': '1', 'address': '4',  'universe': '0', 'manufacturer': 'B', 'model': 'M2', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        {'index': '8', 'address': '10', 'universe': '0', 'manufacturer': 'C', 'model': 'M3', 'mode': '6ch', 'class': 'Yoke spot', 'profile': '010203'},
      ]);
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.fixtures.length, equals(3));
      expect(show.fixtures[0].index, equals(0));
      expect(show.fixtures[1].index, equals(1));
      expect(show.fixtures[2].index, equals(8));
      expect(show.fixtures[2].fixtureClass, equals('Yoke spot'));
    });

    test('parses playback attributes and cue count', () {
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '6ch', 'class': 'Led', 'profile': '010405060C80'},
        ],
        playbacks: [
          {
            'index': 0,
            'label': 'fx color',
            'intensity': 1.0,
            'gomode': 'go',
            'repeat': 'loop',
            'speed': 1.0,
            'cues': <Map<String, dynamic>>[
              {'label': 'cue1', 'fade': '00-00-01-00', 'delay': '00-00-00-00', 'condition': 'halt', 'block': _buildBlock800()},
              {'label': 'cue2', 'fade': '00-00-02-50', 'delay': '00-00-00-00', 'condition': 'halt', 'block': _buildBlock800()},
            ],
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.playbacks.length, equals(1));
      final pb = show.playbacks.first;
      expect(pb.index, equals(0));
      expect(pb.label, equals('fx color'));
      expect(pb.intensity, equals(1.0));
      expect(pb.goMode, equals(GoMode.go));
      expect(pb.repeatMode, equals(RepeatMode.loop));
      expect(pb.speed, equals(1.0));
      expect(pb.cues.length, equals(2));
    });

    test('parses fade time correctly (HH-MM-SS-FF format)', () {
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {
            'index': 0, 'label': 'test', 'cues': <Map<String, dynamic>>[
              // 00-00-02-50 = 2 seconds + 50/100 = 2.5 seconds
              {'label': 'c', 'fade': '00-00-02-50', 'delay': '00-00-01-00', 'block': _buildBlock800()},
            ]
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final cue = show.playbacks.first.cues.first;
      expect(cue.fadeSeconds, closeTo(2.5, 0.001));
      expect(cue.delaySeconds, closeTo(1.0, 0.001));
    });

    test('decodes channel values from 800-byte block', () {
      final block = _buildBlock800(red: 200, green: 150, blue: 100, intensity: 255, shutter: 128);
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '6ch', 'class': 'Led', 'profile': '010405060C80'},
        ],
        playbacks: [
          {
            'index': 0, 'label': 'pb', 'cues': <Map<String, dynamic>>[
              {'label': 'c1', 'block': block},
            ]
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final cue = show.playbacks.first.cues.first;
      // Keys are 'fixtureIndex:fnCode'
      expect(cue.channels['0:${0x04}'], equals(200), reason: 'Red = 200');
      expect(cue.channels['0:${0x05}'], equals(150), reason: 'Green = 150');
      expect(cue.channels['0:${0x06}'], equals(100), reason: 'Blue = 100');
      expect(cue.channels['0:${0x01}'], equals(255), reason: 'Intensity = 255');
      expect(cue.channels['0:${0x0C}'], equals(128), reason: 'Shutter = 128');
    });

    test('decodes FX intensity slot from 800-byte block', () {
      final block = _buildBlock800(withFx: true);
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '6ch', 'class': 'Led', 'profile': '010405060C80'},
        ],
        playbacks: [
          {
            'index': 0, 'label': 'fx', 'cues': <Map<String, dynamic>>[
              {'label': 'c1', 'block': block},
            ]
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final cue = show.playbacks.first.cues.first;
      expect(cue.fxIntensity, isNotNull);
      expect(cue.fxIntensity!.waveform, equals('Sinus'));
      // size: 128/255*100 ~ 50.2
      expect(cue.fxIntensity!.size, closeTo(50.2, 1.0));
      // speed: byte 13 = +10% (signed int8, ~1.27 per %)
      expect(cue.fxIntensity!.speed, closeTo(10.0, 1.0));
      // phase: 64/255*100 ~ 25.1
      expect(cue.fxIntensity!.phase, closeTo(25.1, 1.0));
    });

    test('FX speed byte is signed (UI-verified edge values)', () {
      // byte -> app slider %: 0 = 0, 255 = -1, 129 = -100, 128 = +100 (wraps)
      const cases = {0: 0.0, 13: 10.0, 127: 100.0, 128: 100.0, 129: -100.0, 255: -1.0};
      cases.forEach((byte, pct) {
        expect(fxSpeedPercent(byte), closeTo(pct, 1.0), reason: 'byte $byte');
      });
    });

    test('parses multiple playbacks at different indices', () {
      final block = _buildBlock800();
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {'index': 0, 'label': 'Playback A', 'cues': <Map<String, dynamic>>[{'label': 'c1', 'block': block}]},
          {'index': 1, 'label': 'Playback B', 'cues': <Map<String, dynamic>>[{'label': 'c1', 'block': block}, {'label': 'c2', 'block': block}]},
          {'index': 8, 'label': 'Playback C', 'cues': <Map<String, dynamic>>[{'label': 'c1', 'block': block}]},
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.playbacks.length, equals(3));
      expect(show.playbacks[0].index, equals(0));
      expect(show.playbacks[0].label, equals('Playback A'));
      expect(show.playbacks[0].cues.length, equals(1));
      expect(show.playbacks[1].index, equals(1));
      expect(show.playbacks[1].label, equals('Playback B'));
      expect(show.playbacks[1].cues.length, equals(2));
      expect(show.playbacks[2].index, equals(8));
      expect(show.playbacks[2].label, equals('Playback C'));
    });

    test('cue with empty block produces empty channels map', () {
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {'index': 0, 'label': 'pb', 'cues': <Map<String, dynamic>>[
            {'label': 'empty'},
          ]},
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.playbacks.first.cues.first.channels, isEmpty);
    });

    test('repeat and gomode enums are parsed correctly', () {
      final xml = _buildShowXml(playbacks: [
        {'index': 0, 'label': 'a', 'gomode': 'toggle', 'repeat': 'bounce', 'cues': <Map<String, dynamic>>[]},
        {'index': 1, 'label': 'b', 'gomode': 'flash',  'repeat': 'random', 'cues': <Map<String, dynamic>>[]},
        {'index': 2, 'label': 'c', 'gomode': 'solo',   'repeat': 'off',    'cues': <Map<String, dynamic>>[]},
      ]);
      final show = ShowLoader.loadFromString(xml)!;
      expect(show.playbacks[0].goMode,     equals(GoMode.toggle));
      expect(show.playbacks[0].repeatMode, equals(RepeatMode.bounce));
      expect(show.playbacks[1].goMode,     equals(GoMode.flash));
      expect(show.playbacks[1].repeatMode, equals(RepeatMode.random));
      expect(show.playbacks[2].goMode,     equals(GoMode.solo));
      expect(show.playbacks[2].repeatMode, equals(RepeatMode.off));
    });
  });

  // ---------------------------------------------------------------------------
  group('ParsedShow.applyToModel', () {
    ShowModel makeModel() {
      // ShowModel constructor calls _initDemoData() which adds 64 cuelists.
      // We can create it directly; SharedPreferences calls are async and don't
      // block the sync applyToModel call.
      return ShowModel();
    }

    test('populates 64 cuelist slots', () {
      final xml = _buildShowXml();
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      expect(model.cuelists.length, equals(64));
    });

    test('sets cuelist label, goMode and repeatMode from playback', () {
      final block = _buildBlock800();
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {
            'index': 3,
            'label': 'RGB show',
            'intensity': 0.8,
            'gomode': 'toggle',
            'repeat': 'bounce',
            'speed': 2.0,
            'cues': <Map<String, dynamic>>[
              {'label': 'Step 1', 'block': block},
              {'label': 'Step 2', 'block': block},
            ]
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);

      final cl = model.cuelists[3];
      expect(cl.label, equals('RGB show'));
      expect(cl.level, closeTo(0.8, 0.001));
      expect(cl.goMode, equals(GoMode.toggle));
      expect(cl.repeatMode, equals(RepeatMode.bounce));
      expect(cl.speed, closeTo(2.0, 0.001));
      expect(cl.cues.length, equals(2));
    });

    test('translates fn-code channel keys to attr string keys in cue', () {
      final block = _buildBlock800(red: 200, green: 150, blue: 100, intensity: 255);
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '5ch', 'class': 'Led', 'profile': '0104050601'},
        ],
        playbacks: [
          {
            'index': 0, 'label': 'rgb', 'cues': <Map<String, dynamic>>[
              {'label': 'c', 'block': block},
            ]
          }
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      final cue = model.cuelists[0].cues.first;
      // After translation: '0:R', '0:G', '0:B', '0:In'  values normalised 0-1
      expect(cue.channels.containsKey('0:R'),  isTrue);
      expect(cue.channels.containsKey('0:G'),  isTrue);
      expect(cue.channels.containsKey('0:B'),  isTrue);
      expect(cue.channels.containsKey('0:In'), isTrue);
      expect(cue.channels['0:R'],  closeTo(200 / 255.0, 0.001));
      expect(cue.channels['0:G'],  closeTo(150 / 255.0, 0.001));
      expect(cue.channels['0:B'],  closeTo(100 / 255.0, 0.001));
      expect(cue.channels['0:In'], closeTo(1.0, 0.001));
    });

    test('populates fixture list from fixtures', () {
      final xml = _buildShowXml(fixtures: [
        {'index': '0', 'address': '1',  'universe': '0', 'manufacturer': 'Robe', 'model': 'Spiider', 'mode': '39ch', 'class': 'Yoke spot', 'profile': '010203'},
        {'index': '1', 'address': '40', 'universe': '0', 'manufacturer': 'Robe', 'model': 'Spiider', 'mode': '39ch', 'class': 'Yoke spot', 'profile': '010203'},
      ]);
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      expect(model.fixtures.length, equals(2));
      expect(model.fixtures[0].slot, equals(0));
      expect(model.fixtures[0].manufacturer, equals('Robe'));
      expect(model.fixtures[0].model, equals('Spiider'));
      expect(model.fixtures[0].address, equals(1));
      expect(model.fixtures[1].slot, equals(1));
      expect(model.fixtures[1].address, equals(40));
    });

    test('populates liveFixtureMap', () {
      final xml = _buildShowXml(fixtures: [
        {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        {'index': '5', 'address': '4', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
      ]);
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      final map = model.liveFixtureMap as Map<int, ShowFixture>;
      expect(map.containsKey(0), isTrue);
      expect(map.containsKey(5), isTrue);
      expect(map[0]!.manufacturer, equals('X'));
    });

    test('sets isRecorded=true on loaded cues', () {
      final block = _buildBlock800();
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {'index': 0, 'label': 'pb', 'cues': <Map<String, dynamic>>[{'label': 'c1', 'block': block}]},
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      expect(model.cuelists[0].cues.first.isRecorded, isTrue);
    });

    test('cue label falls back to "Cue N" when empty', () {
      final block = _buildBlock800();
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'X', 'model': 'Y', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {'index': 0, 'label': 'pb', 'cues': <Map<String, dynamic>>[
            {'label': '', 'block': block},
          ]},
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      show.applyToModel(model);
      expect(model.cuelists[0].cues.first.label, equals('Cue 1'));
    });

    test('showModified is false after applyToModel', () {
      final xml = _buildShowXml();
      final show = ShowLoader.loadFromString(xml)!;
      final model = makeModel();
      model.showModified = true;
      show.applyToModel(model);
      expect(model.showModified, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('ShowModel round-trip', () {
    test('parse -> applyToModel -> saveShow -> loadShow preserves cuelists and fixtures', () async {
      final block = _buildBlock800(red: 200, green: 150, blue: 100, intensity: 255);
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'Robe', 'model': 'Spiider', 'mode': '6ch', 'class': 'Led', 'profile': '010405060C80'},
          {'index': '1', 'address': '7', 'universe': '0', 'manufacturer': 'Stairville', 'model': 'M400', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {
            'index': 0,
            'label': 'RGB show',
            'intensity': 1.0,
            'gomode': 'go',
            'repeat': 'loop',
            'speed': 1.5,
            'cues': <Map<String, dynamic>>[
              {'label': 'Cue A', 'fade': '00-00-01-50', 'delay': '00-00-00-00', 'condition': 'halt', 'block': block},
              {'label': 'Cue B', 'fade': '00-00-02-00', 'delay': '00-00-00-00', 'condition': 'halt', 'block': block},
            ],
          },
          {
            'index': 5,
            'label': 'Bounce show',
            'intensity': 0.75,
            'gomode': 'toggle',
            'repeat': 'bounce',
            'speed': 2.0,
            'cues': <Map<String, dynamic>>[
              {'label': 'Step 1', 'block': block},
            ],
          },
        ],
      );

      // --- parse and apply ---
      final parsed = ShowLoader.loadFromString(xml)!;
      final model = ShowModel();
      parsed.applyToModel(model);

      // Snapshot values before round-trip
      final cl0Before = model.cuelists[0];
      expect(cl0Before.label, equals('RGB show'));
      expect(cl0Before.cues.length, equals(2));
      expect(cl0Before.cues[0].label, equals('Cue A'));
      expect(cl0Before.cues[1].label, equals('Cue B'));
      expect(cl0Before.goMode, equals(GoMode.go));
      expect(cl0Before.repeatMode, equals(RepeatMode.loop));
      expect(cl0Before.speed, closeTo(1.5, 0.001));

      final cl5Before = model.cuelists[5];
      expect(cl5Before.label, equals('Bounce show'));
      expect(cl5Before.goMode, equals(GoMode.toggle));
      expect(cl5Before.repeatMode, equals(RepeatMode.bounce));

      expect(model.fixtures.length, equals(2));
      expect(model.fixtures[0].manufacturer, equals('Robe'));
      expect(model.fixtures[1].manufacturer, equals('Stairville'));

      // --- save ---
      final saved = await model.saveShow('round_trip_test');
      expect(saved, isTrue);

      // --- reload into a fresh model ---
      final model2 = ShowModel();
      await model2.loadShow('round_trip_test');

      // Verify cuelists
      expect(model2.cuelists.length, equals(64));
      final cl0 = model2.cuelists[0];
      expect(cl0.label, equals('RGB show'));
      expect(cl0.cues.length, equals(2));
      expect(cl0.cues[0].label, equals('Cue A'));
      expect(cl0.cues[1].label, equals('Cue B'));
      expect(cl0.cues[0].isRecorded, isTrue);
      expect(cl0.goMode, equals(GoMode.go));
      expect(cl0.repeatMode, equals(RepeatMode.loop));
      expect(cl0.speed, closeTo(1.5, 0.001));

      final cl5 = model2.cuelists[5];
      expect(cl5.label, equals('Bounce show'));
      expect(cl5.cues.length, equals(1));
      expect(cl5.goMode, equals(GoMode.toggle));
      expect(cl5.repeatMode, equals(RepeatMode.bounce));
      expect(cl5.speed, closeTo(2.0, 0.001));

      // Verify fixtures
      expect(model2.fixtures.length, equals(2));
      expect(model2.fixtures[0].manufacturer, equals('Robe'));
      expect(model2.fixtures[0].model, equals('Spiider'));
      expect(model2.fixtures[0].address, equals(1));
      expect(model2.fixtures[1].manufacturer, equals('Stairville'));
      expect(model2.fixtures[1].address, equals(7));

      // Verify channel data survived round-trip (0:R, 0:G, 0:B, 0:In)
      final cue0 = cl0.cues[0];
      expect(cue0.channels.containsKey('0:R'),  isTrue);
      expect(cue0.channels['0:R'],  closeTo(200 / 255.0, 0.001));
      expect(cue0.channels['0:G'],  closeTo(150 / 255.0, 0.001));
      expect(cue0.channels['0:B'],  closeTo(100 / 255.0, 0.001));
      expect(cue0.channels['0:In'], closeTo(1.0, 0.001));

      // Show name is preserved
      expect(model2.showFileName, equals('round_trip_test'));
      expect(model2.showModified, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('ShowLoader.decodeBlock800', () {
    test('returns empty map for undersized raw data', () {
      final result = ShowLoader.decodeBlock800(Uint8List(10), {});
      expect(result, isEmpty);
    });

    test('returns empty map when fixtureMap is empty', () {
      final result = ShowLoader.decodeBlock800(Uint8List(800), {});
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('decodeBlock800 via show (integration)', () {
    test('multi-fixture block decoded correctly', () {
      // Two fixtures: index 0 (RGB) and index 1 (RGB)
      final raw = Uint8List(800);
      // Record 0: R=200, G=150, B=100 (high bytes, little-endian u16)
      raw[0 * 50 + 21] = 200; // 0x04 Red
      raw[0 * 50 + 23] = 150; // 0x05 Green
      raw[0 * 50 + 25] = 100; // 0x06 Blue
      // Record 1: R=10, G=20, B=30
      raw[1 * 50 + 21] = 10;
      raw[1 * 50 + 23] = 20;
      raw[1 * 50 + 25] = 30;

      final block = base64Encode(raw);
      final xml = _buildShowXml(
        fixtures: [
          {'index': '0', 'address': '1', 'universe': '0', 'manufacturer': 'A', 'model': 'M', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
          {'index': '1', 'address': '4', 'universe': '0', 'manufacturer': 'A', 'model': 'M', 'mode': '3ch', 'class': 'Led', 'profile': '040506'},
        ],
        playbacks: [
          {'index': 0, 'label': 'pb', 'cues': <Map<String, dynamic>>[{'label': 'c', 'block': block}]},
        ],
      );
      final show = ShowLoader.loadFromString(xml)!;
      final cue = show.playbacks.first.cues.first;
      expect(cue.channels['0:${0x04}'], equals(200));
      expect(cue.channels['0:${0x05}'], equals(150));
      expect(cue.channels['0:${0x06}'], equals(100));
      expect(cue.channels['1:${0x04}'], equals(10));
      expect(cue.channels['1:${0x05}'], equals(20));
      expect(cue.channels['1:${0x06}'], equals(30));
    });
  });
}
