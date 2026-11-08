// v0.6 control: the app's GO / FLASH / RELEASE / RELEASE ALL / fader / knob
// reach the LPU (the Python emulator), checked on the LPU itself through a
// second client, and the app shows what the LPU reports back.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/live_sync.dart';
import 'package:dled/services/vn_service.dart';

import 'core/emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final port = 32000 + pid % 1000;
  Emulator? emu;
  late ShowModel model;
  LpuClient? lpu; // "looks at the LPU" - a second client

  setUpAll(() async {
    emu = await Emulator.start(port, show: _m400);
    if (emu == null) return;
    model = ShowModel();
    model.vnService.onLiveEvent = (e) => LiveSync.apply(model, e, deviceIp: '127.0.0.1');
    await model.vnService.connect(
        VnDevice(label: 'LPU-1', ip: '127.0.0.1', port: port, version: '1.29', lastSeen: DateTime.now()));
    lpu = await LpuClient.connect('127.0.0.1', port: port);
  });
  tearDownAll(() async {
    await lpu?.close();
    if (emu != null) model.vnService.disconnect();
    emu?.stop();
  });

  Future<void> until(bool Function() ok, [String what = 'condition']) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException(what);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<int?> activeOnLpu(int pb) async => playbackState((await lpu!.read(objPlayback, 0x30, i1: pb)).body).activeCue;
  bool skip() {
    if (emu == null) markTestSkipped('python / emulator not available');
    return emu == null;
  }

  int id(int pb) => model.cuelists[pb].id;

  test('GO twice steps through the cues on the LPU', () async {
    if (skip()) return;
    model.goCuelist(id(0));
    await until(() => model.cuelists[0].currentCueIndex == 0 && model.cuelists[0].state == PlaybackState.playing);
    expect(await activeOnLpu(0), 0);
    model.goCuelist(id(0));
    await until(() => model.cuelists[0].currentCueIndex == 1, 'cue 2');
    expect(await activeOnLpu(0), 1);
  });

  test('RELEASE releases on the LPU', () async {
    if (skip()) return;
    model.releaseCuelist(id(0));
    await until(() => model.cuelists[0].state == PlaybackState.released);
    expect(await activeOnLpu(0), isNull);
  });

  test('FLASH runs while held and releases on let-go', () async {
    if (skip()) return;
    model.flashPress(id(8));
    await until(() => model.cuelists[8].state == PlaybackState.playing);
    expect(await activeOnLpu(8), 0);
    model.flashRelease(id(8));
    await until(() => model.cuelists[8].state == PlaybackState.released);
    expect(await activeOnLpu(8), isNull);
  });

  test('RELEASE ALL releases everything with one command', () async {
    if (skip()) return;
    model.goCuelist(id(1));
    model.goCuelist(id(2));
    await until(() => model.cuelists[1].state == PlaybackState.playing && model.cuelists[2].state == PlaybackState.playing);
    model.releaseAll();
    await until(() => model.cuelists[1].state == PlaybackState.released && model.cuelists[2].state == PlaybackState.released);
    expect([await activeOnLpu(1), await activeOnLpu(2)], [null, null]);
  });

  test('a fast fader drag ends on the LPU at the last value, without jumping back', () async {
    if (skip()) return;
    for (var i = 0; i <= 50; i++) {
      model.setPlaybackLevel(3, i / 50 * 0.6); // 0 -> 0.6 in 51 steps, no waiting
    }
    expect(model.cuelists[3].liveLevel, closeTo(0.6, 1e-9)); // the slider shows it at once
    final end = DateTime.now().add(const Duration(seconds: 5));
    double onLpu = -1;
    while (DateTime.now().isBefore(end)) {
      onLpu = await lpu!.readValue(objPlayback, 0x17, i1: 3) as double;
      if ((onLpu - 0.6).abs() < 1e-6) break;
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(onLpu, closeTo(0.6, 1e-6));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(model.cuelists[3].liveLevel, closeTo(0.6, 1e-6)); // own echoes did not move it back
  });

  test('the knob sets the speed on the LPU', () async {
    if (skip()) return;
    model.setPlaybackSpeed(3, -0.5);
    final end = DateTime.now().add(const Duration(seconds: 5));
    double onLpu = 0;
    while (DateTime.now().isBefore(end)) {
      onLpu = await lpu!.readValue(objPlayback, 0x15, i1: 3) as double;
      if ((onLpu + 0.5).abs() < 1e-6) break;
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(onLpu, closeTo(-0.5, 1e-6));
  });

  test('a fader moved elsewhere later still moves the app fader', () async {
    if (skip()) return;
    await Future.delayed(const Duration(milliseconds: 600)); // past the own-move hold
    await lpu!.write(objPlayback, tFloat, 0x18, i1: 3, body: encFloat(0.2));
    await until(() => (model.cuelists[3].liveLevel - 0.2).abs() < 1e-6, 'fader from elsewhere');
  });
}
