// v1.1 automatic connecting: a lost LPU is reconnected, the trying stops
// after the window and starts again on request (OPTIONS), and with several
// LPUs the remembered / the show's / the only one is chosen.
// LPUs are Python emulators; discovery replies are fed in with deviceSeen()
// (the emulators listen on test ports, not on the broadcast port 16945).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/live_sync.dart';
import 'package:dled/services/vn_service.dart';

import 'core/emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';

VnDevice lpu(String ip, int port) =>
    VnDevice(label: 'LPU-1', ip: ip, port: port, version: '1.29', lastSeen: DateTime.now());

void main() {
  final port = 34000 + pid % 1000;
  LpuSession.watchdogInterval = const Duration(milliseconds: 500);

  Future<void> until(bool Function() ok, String what, {int seconds = 10}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException(what);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  VnService service(List<LiveEvent> events) => VnService()
    ..retryInterval = const Duration(milliseconds: 300)
    ..onLiveEvent = events.add;

  test('the chosen LPU is remembered across app starts; the show gives its LPU', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final first = ShowModel();
    first.vnService.onPreferredChanged!('192.168.1.12'); // what connect() does on a user choice
    await Future.delayed(const Duration(milliseconds: 50));
    final next = ShowModel(); // app started again
    await Future.delayed(const Duration(milliseconds: 50));
    expect(next.vnService.preferredIp, '192.168.1.12');
    next.deviceInfo = {'ip': '192.168.1.20'};
    expect(next.vnService.showDeviceIp!(), '192.168.1.20');
  });

  group('choosing an LPU', () {
    final a = lpu('10.0.0.1', 1), b = lpu('10.0.0.2', 1);
    test('the one the user chose last wins', () {
      expect(VnService.chooseAuto([a, b], preferredIp: '10.0.0.2', showIp: '10.0.0.1'), b);
    });
    test('else the one the open show came from', () {
      expect(VnService.chooseAuto([a, b], showIp: '10.0.0.2'), b);
      expect(VnService.chooseAuto([a, b], preferredIp: '10.0.0.9', showIp: '10.0.0.1'), a);
    });
    test('else the only one', () {
      expect(VnService.chooseAuto([a]), a);
      expect(VnService.chooseAuto([a], preferredIp: '10.0.0.9'), a);
    });
    test('before discovery settled only the best possible choice', () {
      // the remembered one may still answer: not the show's one yet
      expect(VnService.chooseAuto([a], preferredIp: '10.0.0.2', showIp: '10.0.0.1', settled: false), isNull);
      // nothing remembered: the show's one is the best possible
      expect(VnService.chooseAuto([a], showIp: '10.0.0.1', settled: false), a);
      // "the only one" needs all answers
      expect(VnService.chooseAuto([a], settled: false), isNull);
    });
    test('an LPU at a link-local 169.254 address is only reachable from 169.254', () {
      expect(VnService.reachable('169.254.10.7', ['192.168.1.171']), isFalse);
      expect(VnService.reachable('169.254.10.7', ['192.168.1.171', '169.254.3.3']), isTrue);
      expect(VnService.reachable('192.168.1.12', ['192.168.1.171']), isTrue);
    });
    test('several and no match: none (the user chooses)', () {
      expect(VnService.chooseAuto([a, b]), isNull);
      expect(VnService.chooseAuto([a, b], preferredIp: '10.0.0.9'), isNull);
      expect(VnService.chooseAuto([]), isNull);
    });
  });

  test('a lost LPU is noticed without any action and reconnected when it is back', () async {
    var emu = await Emulator.start(port, show: _m400);
    if (emu == null) return markTestSkipped('python / emulator not available');
    final events = <LiveEvent>[];
    final vn = service(events);
    addTearDown(() {
      vn.stop();
      emu?.stop();
    });
    await vn.connect(lpu('127.0.0.1', port));
    expect(vn.isConnected, isTrue);

    emu.stop(); // power off / network gone; nobody presses anything
    await until(() => events.any((e) => e is ConnectionLost), 'ConnectionLost from the watchdog');
    expect(vn.isConnected, isFalse);
    expect(vn.isAutoConnecting, isTrue);

    emu = await Emulator.start(port, show: _m400); // power back on
    final downloads = events.whereType<ShowDownloaded>().length;
    await until(() => vn.isConnected, 'reconnected', seconds: 20);
    expect(events.whereType<ShowDownloaded>().length, downloads + 1); // the LPU's show again
    expect(vn.isAutoConnecting, isFalse);
  });

  test('the trying stops after the window; OPTIONS starts it again', () async {
    var emu = await Emulator.start(port + 1, show: _m400);
    if (emu == null) return markTestSkipped('python / emulator not available');
    final events = <LiveEvent>[];
    var ended = 0;
    final vn = service(events)
      ..autoConnectWindow = const Duration(seconds: 2)
      ..onAutoConnectEnded = () => ended++;
    addTearDown(() {
      vn.stop();
      emu?.stop();
    });
    await vn.connect(lpu('127.0.0.1', port + 1));
    emu.stop();
    await until(() => events.any((e) => e is ConnectionLost), 'lost');
    await until(() => !vn.isAutoConnecting, 'gave up after the window');
    expect(ended, 1);

    emu = await Emulator.start(port + 1, show: _m400);
    await Future.delayed(const Duration(seconds: 2));
    expect(vn.isConnected, isFalse); // no more trying on its own

    vn.startAutoConnect(); // what opening OPTIONS does
    vn.deviceSeen(lpu('127.0.0.1', port + 1)); // its discovery reply
    await until(() => vn.isConnected, 'connected again after OPTIONS');
  });

  test('a user disconnect is not undone', () async {
    final emu = await Emulator.start(port + 2, show: _m400);
    if (emu == null) return markTestSkipped('python / emulator not available');
    final vn = service([]);
    addTearDown(() {
      vn.stop();
      emu.stop();
    });
    await vn.connect(lpu('127.0.0.1', port + 2));
    vn.disconnect();
    vn.deviceSeen(lpu('127.0.0.1', port + 2));
    await Future.delayed(const Duration(seconds: 1));
    expect([vn.isConnected, vn.isConnecting, vn.isAutoConnecting], [false, false, false]);
  });

  test('deselecting in OPTIONS disconnects, forgets the LPU and stays offline', () async {
    final emu = await Emulator.start(port + 5, show: _m400);
    if (emu == null) return markTestSkipped('python / emulator not available');
    SharedPreferences.setMockInitialValues({});
    final m = ShowModel();
    m.vnService
      ..retryInterval = const Duration(milliseconds: 300)
      ..onLiveEvent = (e) => LiveSync.apply(m, e, deviceIp: '127.0.0.1');
    addTearDown(() {
      m.vnService.stop();
      emu.stop();
    });
    m.networkDevices.add(NetworkDevice(ipAddress: '127.0.0.1'));
    await m.vnService.connect(lpu('127.0.0.1', port + 5)); // the user selects it
    expect([m.liveConnected, m.vnService.preferredIp], [true, '127.0.0.1']);
    expect(m.cuelists[0].cues, isNotEmpty);

    m.deselectLpu();
    expect([m.liveConnected, m.vnService.isConnected, m.vnService.preferredIp], [false, false, null]);
    expect(m.cuelists.every((c) => c.cues.isEmpty && c.label.isEmpty), isTrue); // emptied
    expect(m.networkDevices, hasLength(1)); // the list stays
    await Future.delayed(const Duration(milliseconds: 50));
    expect((await SharedPreferences.getInstance()).getString('lpu_ip'), isNull);

    // it is still on the network, but no automatic connect after a deselect
    m.vnService.startAutoConnect(); // what opening OPTIONS does
    m.vnService.deviceSeen(lpu('127.0.0.1', port + 5));
    await Future.delayed(const Duration(seconds: 3));
    expect(m.vnService.isConnected, isFalse);

    await m.vnService.connect(lpu('127.0.0.1', port + 5)); // selected again
    expect(m.liveConnected, isTrue);
  });

  group('several LPUs on the network', () {
    Emulator? one, two;
    setUpAll(() async {
      one = await Emulator.start(port + 3, show: _m400);
      two = await Emulator.start(port + 4, show: _m400, ip: '127.0.0.2');
    });
    tearDownAll(() {
      one?.stop();
      two?.stop();
    });
    bool skip() {
      if (one == null || two == null) markTestSkipped('emulators not available (127.0.0.2?)');
      return one == null || two == null;
    }

    VnService started(String? preferred, String? showIp, {bool both = true}) {
      final vn = service([])
        ..preferredIp = preferred
        ..showDeviceIp = () => showIp;
      vn.startAutoConnect();
      // The first answer arrives; the second a moment later (real discovery).
      vn.deviceSeen(lpu('127.0.0.1', port + 3));
      if (both) Future.delayed(const Duration(milliseconds: 500), () => vn.deviceSeen(lpu('127.0.0.2', port + 4)));
      addTearDown(vn.stop);
      return vn;
    }

    test('nothing remembered, no show match: no automatic connect', () async {
      if (skip()) return;
      final vn = started(null, null);
      await Future.delayed(const Duration(seconds: 3)); // past discoverySettle
      expect([vn.isConnected, vn.isConnecting], [false, false]);
    });

    test('only one LPU answers: connected once discovery settled', () async {
      if (skip()) return;
      final vn = started(null, null, both: false);
      await until(() => vn.isConnected, 'connected');
      expect(vn.connected!.ip, '127.0.0.1');
    });

    test('an unreachable 169.254 LPU does not count: the other is the only one', () async {
      if (skip()) return;
      final vn = service([]);
      addTearDown(vn.stop);
      vn.startAutoConnect();
      vn.deviceSeen(lpu('169.254.20.1', port + 3)); // link-local, this PC is not on 169.254
      vn.deviceSeen(lpu('127.0.0.1', port + 3));
      await until(() => vn.isConnected, 'connected');
      expect(vn.connected!.ip, '127.0.0.1');
    });

    test('the remembered one is connected', () async {
      if (skip()) return;
      final vn = started('127.0.0.2', '127.0.0.1');
      await until(() => vn.isConnected, 'connected');
      expect(vn.connected!.ip, '127.0.0.2');
    });

    test("the open show's one is connected", () async {
      if (skip()) return;
      final vn = started(null, '127.0.0.2');
      await until(() => vn.isConnected, 'connected');
      expect(vn.connected!.ip, '127.0.0.2');
    });

    test('choosing one in OPTIONS remembers it', () async {
      if (skip()) return;
      String? saved;
      final vn = started(null, null)..onPreferredChanged = (ip) => saved = ip;
      await Future.delayed(const Duration(milliseconds: 700)); // both listed
      await vn.connect(lpu('127.0.0.2', port + 4)); // the user taps it
      expect([vn.connected!.ip, vn.preferredIp, saved], ['127.0.0.2', '127.0.0.2', '127.0.0.2']);
    });
  });
}
