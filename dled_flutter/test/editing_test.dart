// v0.7 editing and upload: each change is made in the app (connected to the
// Python emulator) and checked on the LPU itself through a second client.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/show_file.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/live_sync.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/services/vn_service.dart';

import 'core/emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';
const _flags = 'test/core_data/shows/app_flags.show';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final port = 33000 + pid % 1000;
  Emulator? emu;
  late ShowModel model;
  LpuClient? lpu;

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

  /// Poll until [check] holds on the LPU (async) - edits are fire-and-forget.
  Future<void> onLpu(Future<bool> Function() check, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!await check()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('LPU: $what');
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<String> label(int pb) async => await lpu!.readValue(objPlayback, 0x05, i1: pb) as String;
  Future<PlaybackStatus> state(int pb) async => playbackState((await lpu!.read(objPlayback, 0x30, i1: pb)).body);
  bool skip() {
    if (emu == null) markTestSkipped('python / emulator not available');
    return emu == null;
  }

  test('rename', () async {
    if (skip()) return;
    model.renameCuelist(model.cuelists[2].id, 'renamed here');
    await onLpu(() async => await label(2) == 'renamed here', 'label');
  });

  test('playback properties', () async {
    if (skip()) return;
    model.setCuelistProps(model.cuelists[2].id,
        goMode: GoMode.toggle, repeatMode: RepeatMode.bounce, exclusive: true);
    await onLpu(() async {
      final b = (await lpu!.read(objPlayback, 0x30, i1: 2)).body;
      return b[0] >> 4 == 1 && b[1] >> 4 == 1 && b[0] & 2 != 0;
    }, 'go mode Toggle, repeat Bounce, exclusive');
  });

  test('SWAP exchanges whole playbacks', () async {
    if (skip()) return;
    final a = model.cuelists[0].label, b = model.cuelists[10].label;
    final cuesA = model.cuelists[0].cues.length, cuesB = model.cuelists[10].cues.length;
    model.swapCuelists(0, 10);
    await onLpu(() async => await label(0) == b && await label(10) == a, 'labels swapped');
    expect([(await state(0)).cues, (await state(10)).cues], [cuesB, cuesA]);
    expect([model.cuelists[0].label, model.cuelists[0].cues.length], [b, cuesB]);
    model.swapCuelists(0, 10); // back
    await onLpu(() async => await label(0) == a, 'swapped back');
  });

  test('add cues (also to an empty playback) and remove them', () async {
    if (skip()) return;
    final before = model.cuelists[0].cues.length;
    model.addCue(0);
    model.addCue(0);
    await onLpu(() async => (await state(0)).cues == before + 2, 'two cues added');
    model.addCue(20); // playback 21 is empty
    await onLpu(() async => (await state(20)).cues == 1, 'first cue of an empty playback');
    model.removeCues(0, [before, before + 1]);
    await onLpu(() async => (await state(0)).cues == before, 'cues removed');
  });

  test('record / fade / delay / condition write the cue', () async {
    if (skip()) return;
    final cue = model.cuelists[0].cues[1];
    cue.channels['0:In'] = 0.5;
    cue.fadeIn = 2.5;
    cue.delay = 1.0;
    cue.condition = CueCondition.follow;
    model.cueChanged(0, 1);
    await onLpu(() async => await lpu!.readValue(objCue, 0x29, i1: 0, i2: 1) == 2500, 'fade 2.5 s');
    expect(await lpu!.readValue(objCue, 0x2b, i1: 0, i2: 1), 1000);
    expect(await lpu!.readValue(objCue, 0x27, i1: 0, i2: 1), 1);
    final block = (await lpu!.read(objCue, 0x46, i1: 0, i2: 1, i3: 0)).body;
    expect(decodeRecord(block, 0).intensity, 32768); // fixture 1 at 50 %
  });

  test('upload: releases first, sends and verifies', () async {
    if (skip()) return;
    await go(lpu!, 0); // something is running on the LPU
    await onLpu(() async => (await state(0)).activeCue != null, 'pb1 running');
    // Put a different show into the app, as OPEN does.
    ShowLoader.loadFromString(File(_flags).readAsStringSync())!.applyToModel(model);
    final steps = <String>[];
    final msg = await model.uploadShowToLpu(progress: steps.add);
    expect(msg, startsWith('Sent to the LPU and verified'), reason: msg);
    expect(steps.first, 'releasing all playbacks');
    final onDevice = (await download(lpu!)).show;
    expect(compareShows(parseShow(File(_flags).readAsStringSync()), onDevice), isEmpty);
    expect(onDevice.playbacks, isEmpty); // the M400 playbacks are gone
    // No backup of the previous LPU show is stored any more.
    expect(model.showFiles.where((s) => s.name.startsWith('LPU backup')), isEmpty);
    // And the app shows what the LPU now holds.
    expect(model.fixtures.map((f) => f.label).take(2), ['fixt 1', 'fixt 2']);
  });

  test('v0.8: Art-Net / sACN switches and rename change the LPU', () async {
    if (skip()) return;
    // As main.dart lists the discovered LPU.
    model.networkDevices.add(NetworkDevice(ipAddress: '127.0.0.1', shortName: 'LPU-1'));
    final before = await readDevice(lpu!, Show());
    model.setDeviceArtNet('127.0.0.1', !before.artNetEnabled);
    model.setDeviceSacn('127.0.0.1', !before.sacnEnabled);
    model.renameDevice('127.0.0.1', 'STAGE');
    await onLpu(() async {
      final now = await readDevice(lpu!, Show());
      return now.artNetEnabled != before.artNetEnabled &&
          now.sacnEnabled != before.sacnEnabled &&
          now.alias == 'STAGE';
    }, 'device settings');
    // The LPU's read-back reaches the device list.
    final d = model.networkDevices.single;
    await onLpu(() async => d.shortName == 'STAGE', 'read-back');
    expect(d.artNetEnabled, !before.artNetEnabled);
    expect(d.sacnEnabled, !before.sacnEnabled);
    expect(d.displayName, 'STAGE');
  });

  test('v0.8: device settings of an LPU that is not connected stay in the app', () async {
    if (skip()) return;
    model.networkDevices.add(NetworkDevice(ipAddress: '10.0.0.99'));
    final before = await readDevice(lpu!, Show());
    model.setDeviceArtNet('10.0.0.99', true);
    model.renameDevice('10.0.0.99', 'OTHER');
    await Future.delayed(const Duration(milliseconds: 300));
    final now = await readDevice(lpu!, Show());
    expect(now.alias, before.alias);
    expect(now.artNetEnabled, before.artNetEnabled);
    expect(model.networkDevices.last.displayName, 'OTHER');
  });
}
