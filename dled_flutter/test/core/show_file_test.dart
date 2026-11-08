// .show reading and writing against the Python reference
// (test/core_data/, made by analysis/scripts/make_dart_goldens.py):
// same decoded values, byte-identical written files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/show_file.dart';

const _dir = 'test/core_data/shows';

void main() {
  final records = jsonDecode(File('test/core_data/records.json').readAsStringSync())
      as Map<String, dynamic>;

  for (final name in records.keys) {
    group(name, () {
      final source = File('$_dir/$name.show').readAsStringSync();
      final saved = File('$_dir/$name.saved.show').readAsStringSync();
      final want = records[name] as Map<String, dynamic>;
      final show = parseShow(source);

      test('fixtures', () {
        final got = [
          for (final f in show.fixtures)
            {
              'index': f.index, 'address': f.address, 'manufacturer': f.manufacturer,
              'model': f.model, 'mode': f.mode, 'profile': f.profile, 'name': f.name,
              'invert_pan': f.invertPan, 'invert_tilt': f.invertTilt,
              'swap_pan_tilt': f.swapPanTilt, 'virtual_dimmer': f.virtualDimmer,
            }
        ];
        expect(got, want['fixtures']);
      });

      test('playbacks, cues and every cue record', () {
        final pbs = want['playbacks'] as List;
        expect(show.playbacks.length, pbs.length);
        for (var i = 0; i < pbs.length; i++) {
          final w = pbs[i] as Map<String, dynamic>;
          final p = show.playbacks[i];
          expect([p.index, p.label, p.goMode, p.repeat, p.background, p.exclusive],
              [w['index'], w['label'], w['gomode'], w['repeat'], w['background'], w['exclusive']]);
          expect(p.intensity, closeTo((w['intensity'] as num).toDouble(), 1e-9));
          expect(p.speed, closeTo((w['speed'] as num).toDouble(), 1e-9));
          final cues = w['cues'] as List;
          expect(p.cues.length, cues.length);
          for (var c = 0; c < cues.length; c++) {
            final wc = cues[c] as Map<String, dynamic>;
            final cue = p.cues[c];
            final where = 'pb${p.index + 1} cue${c + 1}';
            expect([cue.label, cue.fadeMs, cue.delayMs, cue.follow],
                [wc['label'], wc['fade_ms'], wc['delay_ms'], wc['follow']], reason: where);
            final recs = wc['records'] as Map<String, dynamic>;
            for (var g = 0; g < 64; g++) {
              final r = cue.record(g);
              final wr = recs['$g'] as Map<String, dynamic>?;
              if (wr == null) {
                expect(r.empty, isTrue, reason: '$where fixture ${g + 1}');
                continue;
              }
              expect({
                'fx_intensity': r.fxIntensity.toList(), 'fx_position': r.fxPosition.toList(),
                'fx_colour': r.fxColour.toList(), 'pan': r.pan, 'tilt': r.tilt,
                'intensity': r.intensity, 'rgbaw': r.rgbaw, 'attrs': r.attrs, 'other': {},
              }, wr, reason: '$where fixture ${g + 1}');
            }
          }
        }
      });

      test('written file is byte-identical to the Python writer', () {
        expect(writeShow(show), saved);
      });

      test('reading the written file and writing again changes nothing', () {
        expect(writeShow(parseShow(saved)), saved);
      });
    });
  }

  group('helpers', () {
    test('cue times', () {
      expect(parseTimeMs('00-00-01-50'), 1500);
      expect(parseTimeMs('01-05'), 1050);
      expect(parseTimeMs(null), 0);
      expect(formatTimeMs(3723450), '01-02-03-45');
    });

    test('FX speed byte', () {
      expect(fxSpeedPercent(0), 0);
      expect(fxSpeedPercent(255), -1);
      expect(fxSpeedPercent(129), -100);
      expect(fxSpeedPercent(128), 100);
      expect(fxSpeedPercent(13), 10);
    });

    test('Python %g float format', () {
      for (final e in {0.9751: '0.9751', 0.5: '0.5', -0.4: '-0.4', 1.0: '1', 100.0: '100',
            0.123456789: '0.123457', 1234567.0: '1.23457e+06', 0.00001: '1e-05'}.entries) {
        expect(formatG(e.key), e.value, reason: '${e.key}');
      }
    });

    test('unknown attributes and sections are kept', () {
      const xml = '<show application="DLED" version="1.19.0" readonly="true"><fixtures>'
          '<fixture index="0" address="1" manufacturer="A" model="B" profile="01" personality="3:7" />'
          '</fixtures><playbacks><playback index="0" level="0.5"><cues><cue label="x" mystery="1">'
          '<blocks><block /><block /><block /><block /></blocks></cue></cues></playback>'
          '</playbacks><buttons><button index="2" /></buttons></show>';
      final out = writeShow(parseShow(xml));
      for (final piece in ['readonly="true"', 'personality="3:7"', 'level="0.5"', 'mystery="1"',
          '<button index="2" />']) {
        expect(out, contains(piece));
      }
    });
  });
}
