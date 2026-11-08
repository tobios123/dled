// The CLI end to end: real processes against the Python emulator.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/show_file.dart';

import 'emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';
const _flags = 'test/core_data/shows/app_flags.show';

void main() {
  final port = 29000 + pid % 1000;
  final dart = dartExecutable();
  Emulator? emu;
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('dled_cli_');
    if (dart != null) emu = await Emulator.start(port, show: _m400);
  });
  tearDownAll(() {
    emu?.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult?> cli(List<String> args) async {
    if (dart == null || emu == null) {
      markTestSkipped('dart / python / emulator not available');
      return null;
    }
    return Process.run(dart, ['run', 'bin/dled_cli.dart', ...args, '--port', '$port']);
  }

  const ip = ['--ip', '127.0.0.1'];

  test('download writes the same .show as the Python tool', () async {
    final path = '${tmp.path}/cli.show';
    final r = await cli(['download', ...ip, '--show', path]);
    if (r == null) return;
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final py = '${tmp.path}/py.show';
    expect(await pythonDownloadTo(port, py), isTrue);
    expect(File(path).readAsStringSync(), File(py).readAsStringSync());
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('upload without --yes is a dry run', () async {
    final r = await cli(['upload', _flags, ...ip]);
    if (r == null) return;
    expect(r.exitCode, 2);
    expect(r.stdout, contains('dry run: nothing sent'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('upload --yes backs up, uploads and verifies', () async {
    final backup = '${tmp.path}/backup.show';
    final r = await cli(['upload', _flags, ...ip, '--yes', '--backup', backup]);
    if (r == null) return;
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(r.stdout, contains('verified'));
    final was = parseShow(File(backup).readAsStringSync());
    expect(compareShows(parseShow(File(_m400).readAsStringSync()), was), isEmpty);
    // put the M400 show back for the next tests
    expect((await cli(['upload', _m400, ...ip, '--yes']))!.exitCode, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('go / release / set / info', () async {
    final r = await cli(['go', '1', ...ip]);
    if (r == null) return;
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect((await cli(['release-all', ...ip]))!.exitCode, 0);
    expect((await cli(['set', ...ip, '--alias', 'cli', '--artnet', 'on', '--artnet-universe', '3']))!.exitCode, 0);
    final info = (await cli(['info', ...ip]))!;
    expect(info.exitCode, 0);
    expect(info.stdout, contains('alias "cli"'));
    expect(info.stdout, contains('Art-Net enabled, universe 3'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('playback properties', () async {
    final r = await cli(['playback', '2', ...ip, '--gomode', 'solo', '--repeat', 'Bounce', '--exclusive', 'on']);
    if (r == null) return;
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(r.stdout, contains('go mode Solo, repeat Bounce'));
    expect(r.stdout, contains('exclusive'));
    final back = (await cli(['playback', '2', ...ip, '--gomode', 'Go', '--repeat', 'Loop', '--exclusive', 'off']))!;
    expect(back.stdout, contains('go mode Go, repeat Loop'));
    expect((await cli(['playback', '2', ...ip, '--gomode', 'fast']))!.exitCode, 64);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('usage errors exit 64', () async {
    final r = await cli(['go', '99', ...ip]);
    if (r == null) return;
    expect(r.exitCode, 64);
    expect(r.stderr, contains('playback must be 1-64'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('no LPU -> exit 1 with a clear message', () async {
    if (dart == null) return markTestSkipped('dart not available');
    final r = await Process.run(dart, ['run', 'bin/dled_cli.dart', 'info', ...ip, '--port', '${port + 1}']);
    expect(r.exitCode, 1);
    expect(r.stderr, contains('no answer from LPU'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
