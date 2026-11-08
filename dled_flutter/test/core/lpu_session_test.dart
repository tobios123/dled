// Live session against the Python emulator, while a second client ("someone
// else", like a second reference app or the CLI) changes things on the LPU.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/core/show_file.dart';

import 'emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';

void main() {
  final port = 30000 + pid % 1000;
  Emulator? emu;
  LpuSession? session;
  LpuClient? other;
  final events = <LiveEvent>[];

  setUpAll(() async {
    emu = await Emulator.start(port, show: _m400);
    if (emu == null) return;
    session = await LpuSession.connect('127.0.0.1', port: port);
    session!.events.listen(events.add);
    other = await LpuClient.connect('127.0.0.1', port: port);
  });
  tearDownAll(() async {
    await other?.close();
    await session?.close();
    emu?.stop();
  });

  /// Wait until an event matching [test] arrived (from now on).
  Future<T> next<T extends LiveEvent>([bool Function(T)? test]) async {
    final start = events.length;
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      for (final e in events.skip(start)) {
        if (e is T && (test == null || test(e))) return e;
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('no $T');
  }

  bool skip() {
    if (session == null) markTestSkipped('python / emulator not available');
    return session == null;
  }

  test('connect downloads the whole show and the live state', () {
    if (skip()) return;
    expect(compareShows(parseShow(File(_m400).readAsStringSync()), session!.show), isEmpty);
    expect(session!.info.alias, 'EMU');
    expect(session!.states.values.every((s) => s.activeCue == null), isTrue);
  });

  test('GO by someone else: active cue and phase arrive', () async {
    if (skip()) return;
    final cue = next<ActiveCue>((e) => e.playback == 0);
    await go(other!, 0);
    expect((await cue).cue, 0);
    final rel = next<ActiveCue>((e) => e.playback == 0);
    await release(other!, 0);
    expect((await rel).cue, isNull);
  });

  test('fader moved by someone else', () async {
    if (skip()) return;
    final lvl = next<FaderLevel>((e) => e.playback == 2);
    await other!.write(objPlayback, tFloat, 0x18, i1: 2, body: encFloat(0.25));
    expect((await lvl).level, closeTo(0.25, 1e-6));
  });

  test('playback label changed by someone else: read back', () async {
    if (skip()) return;
    final upd = next<PlaybackUpdated>((e) => e.index == 1 && e.playback?.label == 'renamed');
    await other!.write(objPlayback, tStr, 0x06, i1: 1, body: encStr('renamed'));
    final e = await upd;
    expect(e.playback!.cues.length, session!.show.playback(1)!.cues.length);
  });

  test('fixture renamed by someone else: read back', () async {
    if (skip()) return;
    final upd = next<FixtureUpdated>((e) => e.slot == 0);
    await other!.write(objFixture, tStr, 0x06, i1: 0, body: encStr('front left'));
    expect((await upd).fixture!.name, 'front left');
  });

  test('alias changed by someone else: device read back', () async {
    if (skip()) return;
    final upd = next<DeviceUpdated>();
    await setAlias(other!, 'EMU 3');
    expect((await upd).info.alias, 'EMU 3');
  });

  test('following alone never writes', () async {
    if (skip()) return;
    // Everything the session sent so far was a read, a short read or a keepalive.
    expect(session!.client.writesSent, 0);
  });

  test('fast fader moves are bundled: the newest value wins', () async {
    if (skip()) return;
    for (var i = 1; i <= 100; i++) {
      session!.setFader(6, i / 100);
    }
    final end = DateTime.now().add(const Duration(seconds: 5));
    double v = 0;
    while (DateTime.now().isBefore(end)) {
      v = await other!.readValue(objPlayback, 0x17, i1: 6) as double;
      if ((v - 1.0).abs() < 1e-6) break;
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(v, closeTo(1.0, 1e-6));
    expect(session!.client.writesSent, lessThan(100)); // not one write per move
  });

  test('GO through the session, the result comes back as live events', () async {
    if (skip()) return;
    final cue = next<ActiveCue>((e) => e.playback == 3);
    await session!.go(3);
    expect((await cue).cue, 0);
    final rel = next<ActiveCue>((e) => e.playback == 3);
    await session!.releaseAll();
    expect((await rel).cue, isNull);
  });

  test('deleting cues: no read-back of the deleted cues, no false connection loss', () async {
    if (skip()) return;
    // Found on the real LPU (v1.0): the deleted cues are announced as changed
    // but reads of them get no answer - each cost 2.4 s and a ConnectionLost.
    final from = events.length;
    final pb = session!.show.playbacks.firstWhere((p) => p.cues.length >= 3).index;
    final n = (await other!.read(objPlayback, 0x30, i1: pb)).body[2];
    await session!.deleteCues(pb, n - 2, 2);
    final upd = await next<PlaybackUpdated>((e) => e.index == pb);
    expect(upd.playback!.cues.length, n - 2);
    final t = Stopwatch()..start();
    await session!.writeDeviceSettings(); // queued after every read-back
    expect(t.elapsedMilliseconds, lessThan(1500));
    final later = events.skip(from);
    expect(later.whereType<ConnectionLost>(), isEmpty);
    expect(later.whereType<CueUpdated>().where((e) => e.playback == pb && e.cueIndex >= n - 2), isEmpty);
  });

  test('one edit read back once, not once per announcement', () async {
    if (skip()) return;
    final from = events.length;
    await session!.writePlaybackLabel(4, 'once');
    await next<PlaybackUpdated>((e) => e.index == 4 && e.playback?.label == 'once');
    await session!.writeDeviceSettings(); // let the queue drain
    expect(events.skip(from).whereType<PlaybackUpdated>().where((e) => e.index == 4).length, 1);
  });
}
