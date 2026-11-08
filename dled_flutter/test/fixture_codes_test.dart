// fixture_codes_test.dart
// The shared function-code tables, checked against a show saved by the real
// reference app (analysis/tests/data/app_saved_channels.show): in playback 6
// "missing channel" each cue sets exactly one fader to full on a SilverStar
// PLUTO 200 (fixture slot 24 = block 1, record 8).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:dled/core/fixture_codes.dart';
import 'package:dled/services/show_loader.dart';

const _appShow = '../analysis/tests/data/app_saved_channels.show';

void main() {
  group('fixture_codes tables', () {
    test('every attr with a record slot lies in 12-49 and slots do not overlap', () {
      final offsets = kAttrRecordOffset.values.toList()..sort();
      expect(offsets.first, greaterThanOrEqualTo(12));
      expect(offsets.last, lessThanOrEqualTo(48));
      expect(offsets.toSet().length, offsets.length);
    });

    test('fine channels use the low byte of their coarse attr', () {
      expect(attrForCode(0x22), 'Pan');
      expect(attrForCode(0x23), 'Tilt');
      expect(isFineCode(0x22), isTrue);
      expect(isFineCode(0x02), isFalse);
      // u16 little-endian: coarse = the high byte at offset + 1
      expect(recordByteForCode(0x02), 13);
      expect(recordByteForCode(0x22), 12);
      expect(recordByteForCode(0x03), 15);
      expect(recordByteForCode(0x23), 14);
      expect(recordByteForCode(0x01), 17);
      expect(recordByteForCode(0x21), 16); // intensity fine
    });

    // Measured on the LPU (lpd/recordings/static_2026-10-27_21-25-48.txt):
    // one record with a different value in every byte, and its DMX output.
    test('record -> DMX as the LPU outputs it', () {
      final rec = List<int>.filled(50, 0);
      final attrs = kAttrRecordOffset.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      for (var k = 0; k < attrs.length; k++) {
        rec[attrs[k].value] = 10 + 12 * k; // the byte at the offset = the low byte
        rec[attrs[k].value + 1] = 3 + 11 * k; // offset + 1 = the high byte
      }
      const measured = {
        0x01: 25, 0x21: 34, 0x02: 131, 0x22: 9, 0x03: 142, 0x23: 21, 0x04: 47, 0x24: 58,
        0x05: 58, 0x06: 69, 0x07: 80, 0x08: 91, 0x09: 36, 0x0A: 102, 0x0B: 113, 0x0C: 124,
        0x0D: 135, 0x0E: 146, 0x0F: 157, 0x10: 168, 0x11: 179, 0x12: 190,
      };
      measured.forEach((code, dmx) =>
          expect(recordDmxForCode(rec, 0, code), dmx, reason: code.toRadixString(16)));
      expect(recordDmx(rec, 0, 'Custom2') >> 8, 201); // code 13 = custom 2
      expect(recordDmxForCode(rec, 0, 0x14), isNull); // pan/tilt speed: no slot (DMX 0)
    });

    test('pan / tilt are signed around the centre', () {
      final rec = List<int>.filled(50, 0);
      expect(recordDmx(rec, 0, 'Pan'), 32767); // nothing stored = centre (DMX 127 / 255)
      setRecordDmx(rec, 0, 'Pan', 65535);
      expect(rec.sublist(12, 14), [0xff, 0x7f]); // the reference app's full right
      setRecordDmx(rec, 0, 'Pan', 0);
      expect(rec.sublist(12, 14), [0x01, 0x80]); // the reference app's full left
      expect(recordDmx(rec, 0, 'Pan'), 0);
      setRecordDmx(rec, 0, 'Tilt', 32767);
      expect(rec.sublist(14, 16), [0, 0]);
      setRecordDmx(rec, 0, 'R', 0x1234);
      expect(rec.sublist(20, 22), [0x34, 0x12]);
      expect(recordDmx(rec, 0, 'R'), 0x1234);
    });

    test('codes without a record slot', () {
      expect(recordByteForCode(0x13), isNull); // UV
      expect(recordByteForCode(0x14), isNull); // pan/tilt speed
      expect(recordByteForCode(0x80), isNull); // generic
    });

    test('no code points into the FX slots (bytes 0-11)', () {
      for (final code in [...kCodeToAttr.keys, 0x22, 0x23]) {
        final b = recordByteForCode(code);
        if (b != null) expect(b, greaterThanOrEqualTo(12), reason: 'code $code');
      }
    });
  });

  group('app-saved show: one fader per cue', () {
    final file = File(_appShow);

    test('each "missing channel" cue sets exactly its fader', () {
      final doc = XmlDocument.parse(file.readAsStringSync());
      final pb = doc.findAllElements('playback')
          .firstWhere((p) => p.getAttribute('index') == '5');
      const want = {
        'custum 2 on': 'Custom2', 'custem 1 on': 'Custom', 'zoom': 'Zoom',
        'iris': 'Iris', 'rotation': 'Rota', 'frost': 'Frost', 'focus': 'Focus',
        'prism': 'Prism', 'gobo': 'Go', 'color wheel': 'Col',
      };
      final cues = pb.findAllElements('cue').toList();
      for (final cue in cues.skip(1)) {
        final label = cue.getAttribute('label')!;
        final blocks = cue.findAllElements('block').toList();
        final raw = Uint8List.fromList(
            base64Decode(blocks[1].innerText.replaceAll(RegExp(r'\s+'), '')));
        final rec = raw.sublist(8 * 50, 9 * 50);
        final set = <String>[
          for (final e in kAttrRecordOffset.entries)
            if (rec[e.value] != 0 || rec[e.value + 1] != 0) e.key,
        ];
        expect(set, [want[label]], reason: label);
      }
    }, skip: file.existsSync() ? false : 'sample show not found');

    test('ShowLoader decodes the PLUTO zoom cue on its zoom channel', () {
      final show = ShowLoader.loadFromString(file.readAsStringSync())!;
      final pb = show.playbacks.firstWhere((p) => p.index == 5);
      final zoomCue = pb.cues.firstWhere((c) => c.label == 'zoom');
      // Fixture slot 24 (PLUTO 200): zoom = code 0x11.
      expect(zoomCue.channels['24:${0x11}'], 255);
      expect(zoomCue.channels['24:${0x0F}'] ?? 0, 0, reason: 'focus stays 0');
    }, skip: file.existsSync() ? false : 'sample show not found');
  });
}
