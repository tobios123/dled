// Shared rules of the light page and the app: free DMX addresses for
// PERSONALITY (core/patch.dart) and cue records (core/cue_codec.dart).

import 'package:dled/core/cue_codec.dart';
import 'package:dled/core/patch.dart';
import 'package:dled/core/show_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('freeAddress', () {
    test('the first channels that fit', () {
      final used = [(start: 1, count: 6), (start: 7, count: 6), (start: 20, count: 10)];
      expect(freeAddress(used, 4), 13);
      expect(freeAddress(used, 8), 30); // 13..19 is only 7 channels
      expect(freeAddress(used, 1, from: 20), 30);
    });

    test('nothing patched: from the start', () {
      expect(freeAddress(const [], 10), 1);
      expect(freeAddress(const [], 10, from: 100), 100);
    });

    test('nothing fits: the start address', () {
      expect(freeAddress([(start: 1, count: 512)], 4, from: 5), 5);
    });
  });

  group('cue codec', () {
    test('a cue is read back as it was encoded', () {
      const circle = (waveform: 'Circle', size: 40.0, speed: 25.0, phase: 0.0);
      final blocks = encodeCueBlocks({'8:In': 200 / 255, '8:Pan': 1.0, '20:R': 0.5}, {8, 20, 40},
          [noFx, circle, noFx], const []);
      final d = decodeCue(ShowCue(blocks: blocks));
      expect(d.slots, {8, 20, 40});
      expect((d.channels['8:In']! * 255).round(), 200);
      expect(d.channels['8:Pan'], closeTo(1.0, 1 / 65535)); // full right is stored ff 7f
      expect((d.channels['20:R']! * 255).round(), 128);
      expect(d.fx[0].waveform, 'None');
      expect(d.fx[1].waveform, 'Circle');
      expect(d.fx[1].size.round(), 40);
      expect(d.fx[1].speed.round(), 25);
      expect(blocks[3], isEmpty); // slots 48-63: nothing
    });

    test('records are little-endian, pan / tilt signed; a centred pan is not in the cue', () {
      final blocks = encodeCueBlocks({'3:In': 1.0, '3:R': 0x1234 / 65535, '3:Pan': 0.0, '3:Tilt': 32767 / 65535},
          const {}, [noFx, noFx, noFx], const []);
      final b = blocks[0], base = 3 * recordSize;
      expect(b.sublist(base + 16, base + 18), [0xff, 0xff]);
      expect(b.sublist(base + 20, base + 22), [0x34, 0x12]);
      expect(b.sublist(base + 12, base + 14), [0x01, 0x80]); // full left
      expect(b.sublist(base + 14, base + 16), [0, 0]); // tilt at the centre
      final d = decodeCue(ShowCue(blocks: blocks));
      expect(d.channels['3:Pan'], 0.0);
      expect(d.channels.containsKey('3:Tilt'), isFalse);
    });

    test('a pure-FX cue puts its FX on every patched fixture', () {
      const rainbow = (waveform: 'Rainbow', size: 50.0, speed: -100.0, phase: 0.0);
      final d = decodeCue(ShowCue(blocks: encodeCueBlocks(const {}, const {}, [noFx, noFx, rainbow], [0, 1, 2])));
      expect(d.slots, {0, 1, 2});
      expect(d.fx[2].waveform, 'Rainbow');
      expect(d.fx[2].speed.round(), -100);
    });

    test('FX bytes: +100 % speed is 127; 128 (the reference app) reads as +100 %', () {
      expect(fxBytes('intensity', (waveform: 'Sinus', size: 100, speed: 100, phase: 100)), [1, 255, 127, 255]);
      expect(fxFromBytes('intensity', [1, 255, 128, 255]).speed, 100);
    });
  });
}
