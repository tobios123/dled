// .show export: import -> app storage (JSON) -> export must give the same
// show back; edited and new cues are encoded from their values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/lpu_io.dart' show compareShows;
import 'package:dled/core/show_file.dart' as core;
import 'package:dled/models/show_model.dart';
import 'package:dled/services/show_exporter.dart';
import 'package:dled/services/show_loader.dart';

const _shows = ['m400', 'fx_options', 'playback_menu', 'cue_fx', 'app_flags', 'app_channels', 'lpu_download'];

/// Import [xml] into a model, then pass it through the JSON the app saves.
({List<Cuelist> cuelists, List<FixturePatch> fixtures, Map<String, String> device}) importAndStore(String xml) {
  final model = ShowModel();
  ShowLoader.loadFromString(xml)!.applyToModel(model);
  return (
    cuelists: [for (final c in model.cuelists) Cuelist.fromJson(jsonDecode(jsonEncode(c.toJson())))],
    fixtures: [for (final f in model.fixtures) FixturePatch.fromJson(jsonDecode(jsonEncode(f.toJson())))],
    device: model.deviceInfo,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  for (final name in _shows) {
    test('$name: import -> store -> export gives the same show', () {
      final xml = File('test/core_data/shows/$name.show').readAsStringSync();
      final stored = importAndStore(xml);
      final exported = showFromModel(cuelists: stored.cuelists, fixtures: stored.fixtures, device: stored.device);
      final back = core.parseShow(core.writeShow(exported));
      expect(compareShows(core.parseShow(xml), back), isEmpty);
      expect(back.device['firmware_version'], core.parseShow(xml).device['firmware_version']);
    });
  }

  test('a playback fader at 0 stays 0 (found on the real LPU, v1.0)', () {
    final show = core.parseShow(File('test/core_data/shows/m400.show').readAsStringSync());
    show.playbacks[1].intensity = 0;
    show.playbacks[2].intensity = 0.4;
    final stored = importAndStore(core.writeShow(show));
    final back = showFromModel(cuelists: stored.cuelists, fixtures: stored.fixtures);
    expect(compareShows(show, back), isEmpty);
    expect(back.playbacks[1].intensity, 0);
    // A playback made in the app (fader never touched) still goes out at full.
    final fresh = Cuelist(id: 1, label: 'new');
    expect(showFromModel(cuelists: [fresh], fixtures: []).playbacks.single.intensity, 1.0);
  });

  test('an edited cue is encoded from its values', () {
    final stored = importAndStore(File('test/core_data/shows/app_channels.show').readAsStringSync());
    // playback 6 "missing channel", cue "zoom": PLUTO 200 in slot 24
    final cue = stored.cuelists[5].cues.firstWhere((c) => c.label == 'zoom');
    cue.channels['24:Zoom'] = 0.5;
    cue.channels['24:Focus'] = 1.0;
    final back = core.parseShow(core.writeShow(
        showFromModel(cuelists: stored.cuelists, fixtures: stored.fixtures)));
    final rec = back.playback(5)!.cues.firstWhere((c) => c.label == 'zoom').record(24);
    expect(rec.attrs, {'zoom': 32768, 'focus': 0xffff});
    // other cues are still the original bytes
    final orig = core.parseShow(File('test/core_data/shows/app_channels.show').readAsStringSync());
    expect(back.playback(5)!.cues.firstWhere((c) => c.label == 'iris').block(1),
        orig.playback(5)!.cues.firstWhere((c) => c.label == 'iris').block(1));
  });

  test('a show made in the app exports correctly', () {
    final fixtures = [
      FixturePatch(id: 1, slot: 0, address: 1, manufacturer: 'Showtec', model: 'Compact Par 18 Tri',
          mode: '6-Ch', profile: '010405060C80', label: 'front', invertPan: true),
    ];
    final cl = Cuelist(id: 1, label: 'red');
    cl.cues.add(Cue(number: 1, label: 'r', fadeIn: 1.5, condition: CueCondition.follow,
        channels: {'0:R': 1.0, '0:In': 0.5},
        fxIntensity: CueFxSlot(waveform: 'Sinus', size: 50, speed: -1, phase: 16)));
    final back = core.parseShow(core.writeShow(showFromModel(cuelists: [cl], fixtures: fixtures)));
    final f = back.fixture(0)!;
    expect([f.name, f.profile, f.invertPan, f.address], ['front', '010405060C80', true, 1]);
    final p = back.playback(0)!;
    expect([p.label, p.intensity, p.speed], ['red', 1.0, 0.0]);
    final c = p.cues.single;
    expect([c.label, c.fadeMs, c.follow], ['r', 1500, true]);
    final r = c.record(0);
    expect([r.rgbaw[0], r.intensity], [0xffff, 32768]);
    expect(r.fxIntensity.toList(), [1, 127, 255, 41]); // 50 % = 0x7f, as the app writes it
    expect(core.fxSpeedPercent(r.fxIntensity.speed), -1);
  });

  test('FX speed percent -> byte -> percent', () {
    for (var p = -100; p <= 100; p++) {
      expect(core.fxSpeedPercent(fxSpeedByte(p.toDouble())), p, reason: '$p %');
    }
  });

  test('fixtures without a stored profile get it from personalities.xml', () async {
    final profiles = await loadPersonalityProfiles();
    // the example fixture: in the public library and in a local one
    final f = FixturePatch(id: 1, slot: 3, address: 10, manufacturer: 'Generic', model: 'RGBW Par', mode: '8 ch');
    final back = showFromModel(cuelists: [], fixtures: [f], profiles: profiles);
    expect(back.fixture(3)!.profile, '01040506080C8012');
  });
}
