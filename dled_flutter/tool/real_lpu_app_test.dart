// v1.0 regression on a REAL LPU through the app's own code (ShowModel +
// VnService + LiveSync, the path the screens use), with this PC as the phone:
//   flutter test tool/real_lpu_app_test.dart --timeout 5m
//   (LPU_IP=<ip> to choose the LPU; default 192.168.1.12)
// A second client looks at the LPU to check every result.
// The LPU's show is backed up to lpu_backups/ first; at the end it is sent
// back through the app's OPEN path (uploadShowToLpu: release all, backup,
// upload, verify) and faders / knobs / device settings are set back.
// Not part of the normal test run (tool/ is not test/).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/show_file.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/live_sync.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/services/vn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final ip = Platform.environment['LPU_IP'] ?? '192.168.1.12';
  late ShowModel model;
  late LpuClient lpu; // "looks at the LPU"
  late Show backup;
  late LpuInfo device;
  final faders = <int, double>{}, knobs = <int, double>{};
  final lost = <String>[]; // ConnectionLost reasons (there must be none)

  // Playbacks of the show on the LPU used below (0-based), chosen in setUpAll.
  late int multi; // >= 3 cues
  late int single; // for FLASH
  late List<int> others; // two more for RELEASE ALL
  late int empty; // an empty slot

  Future<PlaybackStatus> state(int pb) async => playbackState((await lpu.read(objPlayback, 0x30, i1: pb)).body);
  Future<String> label(int pb) async => await lpu.readValue(objPlayback, 0x05, i1: pb) as String;
  int id(int pb) => model.cuelists[pb].id;

  Future<void> until(FutureOr<bool> Function() ok, String what, {int seconds = 10}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!await ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException(what);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    lpu = await LpuClient.connect(ip);
    final d = await download(lpu);
    backup = d.show;
    device = d.info;
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    final path = '../lpu_backups/before_v1_regression_$stamp.show';
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(writeShow(backup));
    // ignore: avoid_print
    print('backup: $path (${backup.fixtures.length} fixtures, ${backup.playbacks.length} playbacks)');

    final used = [for (final p in backup.playbacks) p.index];
    multi = backup.playbacks.firstWhere((p) => p.cues.length >= 3).index;
    single = backup.playbacks.firstWhere((p) => p.index != multi).index;
    others = used.where((i) => i != multi && i != single).take(2).toList();
    empty = [for (var i = 63; i >= 0; i--) if (!used.contains(i)) i].first;
    for (final p in [multi, ...others]) {
      faders[p] = await lpu.readValue(objPlayback, 0x17, i1: p) as double;
      knobs[p] = await lpu.readValue(objPlayback, 0x15, i1: p) as double;
    }

    model = ShowModel();
    model.vnService.onLiveEvent = (e) {
      if (e is ConnectionLost) lost.add(e.reason);
      LiveSync.apply(model, e, deviceIp: ip);
    };
    model.networkDevices.add(NetworkDevice(ipAddress: ip, shortName: device.alias));
    await model.vnService.connect(
        VnDevice(label: 'LPU-1', ip: ip, port: vnPort, version: '?', lastSeen: DateTime.now()));
    model.releaseAll();
    await until(() async {
      for (final p in backup.playbacks) {
        if ((await state(p.index)).activeCue != null) return false;
      }
      return true;
    }, 'all released at the start');
  });

  tearDownAll(() async {
    // Safety net if a test failed half-way: device settings, faders / knobs back.
    final now = await readDevice(lpu, Show());
    if (now.alias != device.alias) await setAlias(lpu, device.alias);
    if (now.artNetEnabled != device.artNetEnabled) await setArtNet(lpu, enabled: device.artNetEnabled);
    if (now.sacnEnabled != device.sacnEnabled) await setSacn(lpu, enabled: device.sacnEnabled);
    for (final p in faders.keys) {
      await lpu.write(objPlayback, tFloat, 0x18, i1: p, body: encFloat(faders[p]!));
      await lpu.write(objPlayback, tFloat, 0x16, i1: p, body: encFloat(knobs[p]!));
    }
    model.vnService.disconnect();
    await lpu.close();
  });

  test('connect: the app holds the LPU show', () {
    expect(model.liveConnected, isTrue);
    for (final p in backup.playbacks) {
      expect(model.cuelists[p.index].label, p.label, reason: 'label pb${p.index + 1}');
      expect(model.cuelists[p.index].cues.length, p.cues.length, reason: 'cues pb${p.index + 1}');
    }
    expect(model.fixtures.length, backup.fixtures.length);
  });

  test('GO steps through cues; the app follows', () async {
    model.goCuelist(id(multi));
    await until(() => model.cuelists[multi].currentCueIndex == 0 &&
        model.cuelists[multi].state == PlaybackState.playing, 'app: cue 1 playing');
    expect((await state(multi)).activeCue, 0);
    model.goCuelist(id(multi));
    await until(() => model.cuelists[multi].currentCueIndex == 1, 'app: cue 2');
    expect((await state(multi)).activeCue, 1);
  });

  test('GO from someone else: the app follows', () async {
    await go(lpu, multi);
    await until(() => model.cuelists[multi].currentCueIndex == 2, 'app follows the other client');
  });

  test('RELEASE', () async {
    model.releaseCuelist(id(multi));
    await until(() => model.cuelists[multi].state == PlaybackState.released, 'app: released');
    await until(() async => (await state(multi)).activeCue == null, 'LPU: released');
  });

  test('FLASH runs while held, releases on let-go', () async {
    model.flashPress(id(single));
    await until(() => model.cuelists[single].state == PlaybackState.playing, 'app: flash playing');
    expect((await state(single)).activeCue, 0);
    await Future.delayed(const Duration(seconds: 1));
    model.flashRelease(id(single));
    await until(() => model.cuelists[single].state == PlaybackState.released, 'app: flash released');
    await until(() async => (await state(single)).activeCue == null, 'LPU: flash released');
  });

  test('RELEASE ALL', () async {
    for (final p in others) {
      model.goCuelist(id(p));
    }
    await until(() => others.every((p) => model.cuelists[p].state == PlaybackState.playing), 'app: both playing');
    model.releaseAll();
    await until(() => others.every((p) => model.cuelists[p].state == PlaybackState.released), 'app: both released');
    for (final p in others) {
      await until(() async => (await state(p)).activeCue == null, 'LPU: pb${p + 1} released');
    }
  });

  test('fader drag ends at the last value; knob; fader from elsewhere', () async {
    final p = multi;
    for (var i = 0; i <= 50; i++) {
      model.setPlaybackLevel(p, i / 50 * 0.6);
    }
    await until(() async => ((await lpu.readValue(objPlayback, 0x17, i1: p) as double) - 0.6).abs() < 1e-6,
        'LPU fader 0.6');
    await Future.delayed(const Duration(milliseconds: 300));
    expect(model.cuelists[p].liveLevel, closeTo(0.6, 1e-6));
    model.setPlaybackSpeed(p, -0.5);
    await until(() async => ((await lpu.readValue(objPlayback, 0x15, i1: p) as double) + 0.5).abs() < 1e-6,
        'LPU knob -0.5');
    await Future.delayed(const Duration(milliseconds: 600)); // past the own-move hold
    await lpu.write(objPlayback, tFloat, 0x18, i1: p, body: encFloat(0.2));
    await until(() => (model.cuelists[p].liveLevel - 0.2).abs() < 1e-6, 'app follows fader from elsewhere');
    // back to how it was
    model.setPlaybackLevel(p, faders[p]!);
    model.setPlaybackSpeed(p, knobs[p]!);
    await until(() async => ((await lpu.readValue(objPlayback, 0x17, i1: p) as double) - faders[p]!).abs() < 1e-6,
        'fader restored');
  });

  test('editing: rename, properties, swap, add / remove cues, record', () async {
    final p = multi, q = others.first;
    model.renameCuelist(id(p), 'V1 CHECK');
    await until(() async => await label(p) == 'V1 CHECK', 'label');
    model.setCuelistProps(id(p), goMode: GoMode.toggle, repeatMode: RepeatMode.bounce, exclusive: true);
    await until(() async {
      final b = (await lpu.read(objPlayback, 0x30, i1: p)).body;
      return b[0] >> 4 == 1 && b[1] >> 4 == 1 && b[0] & 2 != 0;
    }, 'properties');

    final la = await label(p), lb = await label(q);
    model.swapCuelists(p, q);
    await until(() async => await label(p) == lb && await label(q) == la, 'swap');
    model.swapCuelists(p, q);
    await until(() async => await label(p) == la, 'swap back');

    final before = (await state(p)).cues;
    model.addCue(p);
    await until(() async => (await state(p)).cues == before + 1, 'cue added');
    model.addCue(empty);
    await until(() async => (await state(empty)).cues == 1, 'first cue of an empty playback');

    final cue = model.cuelists[p].cues[1];
    cue.fadeIn = 2.5;
    cue.delay = 1.0;
    cue.condition = CueCondition.follow;
    model.cueChanged(p, 1);
    await until(() async => await lpu.readValue(objCue, 0x29, i1: p, i2: 1) == 2500, 'fade 2.5 s');
    expect(await lpu.readValue(objCue, 0x2b, i1: p, i2: 1), 1000);
    expect(await lpu.readValue(objCue, 0x27, i1: p, i2: 1), 1);

    model.removeCues(p, [before]);
    await until(() async => (await state(p)).cues == before, 'cue removed');
    model.removeCues(empty, [0]);
    await until(() async => (await state(empty)).cues == 0, 'empty again');
  });

  test('device settings: Art-Net, sACN, name - and back', () async {
    model.setDeviceArtNet(ip, !device.artNetEnabled);
    model.setDeviceSacn(ip, !device.sacnEnabled);
    model.renameDevice(ip, 'V1 CHECK');
    await until(() async {
      final now = await readDevice(lpu, Show());
      return now.artNetEnabled != device.artNetEnabled && now.sacnEnabled != device.sacnEnabled &&
          now.alias == 'V1 CHECK';
    }, 'device settings on the LPU');
    model.setDeviceArtNet(ip, device.artNetEnabled);
    model.setDeviceSacn(ip, device.sacnEnabled);
    model.renameDevice(ip, device.alias);
    await until(() async {
      final now = await readDevice(lpu, Show());
      return now.artNetEnabled == device.artNetEnabled && now.sacnEnabled == device.sacnEnabled &&
          now.alias == device.alias && now.artNetUniverseRaw == device.artNetUniverseRaw;
    }, 'device settings back');
  });

  test('OPEN sends the backed-up show back (release, backup, upload, verify)', () async {
    model.goCuelist(id(multi)); // something running, as in real use
    await until(() async => (await state(multi)).activeCue != null, 'running before upload');
    ShowLoader.loadFromString(writeShow(backup))!.applyToModel(model);
    final msg = await model.uploadShowToLpu();
    expect(msg, startsWith('Sent to the LPU and verified'), reason: msg);
    final now = (await download(lpu)).show;
    expect(compareShows(backup, now), isEmpty);
    // nothing stuck, no impossible active cue (state 0 = no cues: byte means nothing)
    for (var p = 0; p < 64; p++) {
      final s = await state(p);
      expect(s.state == 4 || (s.state != 0 && s.activeCue != null && s.activeCue! >= s.cues), isFalse,
          reason: 'pb${p + 1}: $s');
    }
    for (final p in backup.playbacks) {
      expect(model.cuelists[p.index].label, p.label);
    }
  });

  test('the connection was never reported lost', () {
    expect(lost, isEmpty);
    expect(model.liveConnected, isTrue);
  });
}
