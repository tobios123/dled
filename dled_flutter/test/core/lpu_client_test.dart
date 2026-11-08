// LpuClient against the Python LPU emulator (analysis/scripts/lpu_emulator.py)
// on 127.0.0.1. Skipped when Python or the emulator is not available.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';

const _emulator = '../analysis/scripts/lpu_emulator.py';
const _show = 'test/core_data/shows/app_flags.show';

void main() {
  final port = 27000 + pid % 1000;
  Process? emu;
  String? skip;

  setUpAll(() async {
    if (!File(_emulator).existsSync()) {
      skip = 'emulator not found';
      return;
    }
    try {
      emu = await Process.start('python', [
        _emulator, '--port', '$port', '--bind', '127.0.0.1', '--ip', '127.0.0.1',
        '--show', _show, '--alias', 'EMU',
      ]);
    } on ProcessException {
      skip = 'python not found';
      return;
    }
    final ready = Completer<void>();
    emu!.stdout.transform(utf8.decoder).listen((s) {
      if (s.contains('LPU emulator') && !ready.isCompleted) ready.complete();
    });
    emu!.stderr.transform(utf8.decoder).listen((_) {});
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      skip = 'emulator did not start';
    }
  });

  tearDownAll(() => emu?.kill());

  Future<void> withClient(Future<void> Function(LpuClient c) body) async {
    if (skip != null) {
      markTestSkipped(skip!);
      return;
    }
    final c = await LpuClient.connect('127.0.0.1', port: port);
    try {
      await body(c);
    } finally {
      await c.close();
    }
  }

  test('short device properties', () => withClient((c) async {
        expect(decStr(await c.shortRead(ShortProp.alias)), 'EMU');
        expect(await c.shortRead(ShortProp.firmware), [1, 29]);
      }));

  test('fixture reads match the show', () => withClient((c) async {
        expect(await c.readValue(objFixture, 0x07, i1: 0),
            '"Aeson","Lumis Beam 5R","","0203222314800C0109800B800F101080"');
        expect(await c.readValue(objFixture, 0x05, i1: 0), 'fixt 1');
        expect(await c.readValue(objFixture, 0x0b, i1: 1), 17);
        expect(await c.readValue(objFixture, 0x0d, i1: 0), 1); // invert pan
      }));

  test('write waits for the echo and the value sticks', () => withClient((c) async {
        await c.write(objPlayback, tStr, 0x06, i1: 5, body: encStr('from dart'));
        expect(await c.readValue(objPlayback, 0x05, i1: 5), 'from dart');
        await c.shortWrite(ShortProp.aliasWrite, encStr('EMU 2'));
        expect(decStr(await c.shortRead(ShortProp.alias)), 'EMU 2');
      }));

  test('requests are lock-step even when fired together', () => withClient((c) async {
        final results = await Future.wait([
          for (var i = 0; i < 4; i++) c.readValue(objFixture, 0x0b, i1: i),
        ]);
        expect(results, [1, 17, 33, 49]);
      }));

  test('notifications arrive on the stream', () => withClient((c) async {
        final got = c.notifications.first.timeout(const Duration(seconds: 2));
        await c.write(objPlayback, tStr, 0x06, i1: 6, body: encStr('x'));
        final n = await got;
        expect(n.isNotification, isTrue);
      }));

  test('no answer -> LpuError after the retries', () async {
    final c = await LpuClient.connect('127.0.0.1',
        port: port + 1, timeout: const Duration(milliseconds: 50), retries: 2, keepalive: false);
    try {
      await expectLater(c.readValue(objFixture, 0x0b), throwsA(isA<LpuError>()));
    } finally {
      await c.close();
    }
  });
}
