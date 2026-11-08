// ShowLoader on the core (v0.4): names, flags, speed default and the kept
// source show, checked with app-saved files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/show_file.dart' as core;
import 'package:dled/models/show_model.dart';
import 'package:dled/services/show_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ParsedShow load(String name) =>
      ShowLoader.loadFromString(File('test/core_data/shows/$name.show').readAsStringSync())!;

  test('fixture names and patch flags reach the model', () {
    final model = ShowModel();
    load('app_flags').applyToModel(model);
    final f = {for (final p in model.fixtures) p.slot: p};
    expect([f[0]!.label, f[0]!.invertPan, f[0]!.invertTilt], ['fixt 1', true, false]);
    expect([f[1]!.label, f[1]!.invertTilt], ['fixt 2', true]);
    expect([f[2]!.label, f[2]!.swapPanTilt], ['', true]); // no name: tile shows the number
    expect(f[3]!.virtualDimmer, isTrue);
  });

  test('playback speed absent in the file means 0 (normal), like the LPU', () {
    final pb = load('m400').playbacks;
    expect(pb.where((p) => p.speed == 0).length, greaterThan(0));
    expect(pb.firstWhere((p) => p.index == 15).speed, closeTo(0.5, 1e-9)); // speed="0.5"
  });

  test('follow cues stay follow, everything else is halt', () {
    final pb = load('app_channels').playbacks.firstWhere((p) => p.index == 5);
    expect(pb.cues.every((c) => c.condition == CueCondition.follow), isTrue);
  });

  test('values come from the record like the core reads them', () {
    final parsed = load('app_channels');
    final src = parsed.source!;
    final pluto = src.playback(5)!.cues.firstWhere((c) => c.label == 'zoom');
    expect(pluto.record(24).attrs, {'zoom': 0xffff});
    final cue = parsed.playbacks.firstWhere((p) => p.index == 5).cues.firstWhere((c) => c.label == 'zoom');
    expect(cue.channels['24:${0x11}'], 255);
  });

  test('the source show writes back byte-identical to the Python writer', () {
    final parsed = load('m400');
    expect(core.writeShow(parsed.source!), File('test/core_data/shows/m400.saved.show').readAsStringSync());
  });
}
