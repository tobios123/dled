// The app following a connected LPU (read-only, v0.5): VnService connects to
// the Python emulator, LiveSync puts what it reports into the model, and a
// second client plays "someone else".

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
  final port = 31000 + pid % 1000;
  Emulator? emu;
  late ShowModel model;
  LpuClient? other;

  setUpAll(() async {
    emu = await Emulator.start(port, show: _m400);
    if (emu == null) return;
    model = ShowModel();
    final vn = model.vnService;
    vn.onLiveEvent = (e) => LiveSync.apply(model, e, deviceIp: '127.0.0.1');
    vn.onConnectionChanged = (d) {
      if (d == null) model.liveConnected = false;
    };
    await vn.connect(VnDevice(label: 'LPU-1', ip: '127.0.0.1', port: port, version: '1.29', lastSeen: DateTime.now()));
    other = await LpuClient.connect('127.0.0.1', port: port);
  });
  tearDownAll(() async {
    await other?.close();
    if (emu != null) model.vnService.disconnect();
    emu?.stop();
  });

  Future<void> until(bool Function() ok) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('model did not follow');
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  bool skip() {
    if (emu == null) markTestSkipped('python / emulator not available');
    return emu == null;
  }

  test('connecting loads the LPU show into the app', () {
    if (skip()) return;
    expect(model.vnService.isConnected, isTrue);
    expect(model.liveConnected, isTrue);
    expect(model.cuelists[0].label, 'Basic col');
    expect(model.cuelists[0].cues.length, 6);
    expect(model.fixtures.length, 9);
  });

  test('GO / release by someone else show up in the playback state', () async {
    if (skip()) return;
    await go(other!, 0);
    await until(() => model.cuelists[0].state == PlaybackState.playing);
    expect(model.cuelists[0].currentCueIndex, 0);
    await go(other!, 0);
    await until(() => model.cuelists[0].currentCueIndex == 1);
    await release(other!, 0);
    await until(() => model.cuelists[0].state == PlaybackState.released);
  });

  test('a fader moved elsewhere moves the app fader', () async {
    if (skip()) return;
    await other!.write(objPlayback, tFloat, 0x18, i1: 4, body: encFloat(0.4));
    await until(() => (model.cuelists[4].liveLevel - 0.4).abs() < 1e-6);
  });

  test('renames elsewhere reach the app', () async {
    if (skip()) return;
    await other!.write(objPlayback, tStr, 0x06, i1: 2, body: encStr('from elsewhere'));
    await until(() => model.cuelists[2].label == 'from elsewhere');
    await other!.write(objFixture, tStr, 0x06, i1: 1, body: encStr('spot 2'));
    await until(() => model.fixtures.any((f) => f.slot == 1 && f.label == 'spot 2'));
  });

  test('connected: GO in the app plays on the LPU, the state comes back from it', () async {
    if (skip()) return;
    model.goCuelist(model.cuelists[5].id);
    await until(() => model.cuelists[5].state == PlaybackState.playing);
    final st = playbackState((await other!.read(objPlayback, 0x30, i1: 5)).body);
    expect(st.activeCue, 0);
    model.releaseCuelist(model.cuelists[5].id);
    await until(() => model.cuelists[5].state == PlaybackState.released);
  });

  test('disconnect: back to offline mode', () async {
    if (skip()) return;
    model.vnService.disconnect();
    expect(model.liveConnected, isFalse);
    model.goCuelist(model.cuelists[5].id); // local logic runs again
    expect(model.cuelists[5].state, PlaybackState.playing);
    // reconnect for tearDownAll symmetry
    await model.vnService.connect(
        VnDevice(label: 'LPU-1', ip: '127.0.0.1', port: port, version: '1.29', lastSeen: DateTime.now()));
  });
}
