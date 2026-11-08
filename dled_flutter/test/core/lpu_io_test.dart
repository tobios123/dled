// Download / upload / actions against the Python emulator, cross-checked with
// the Python tools: the Dart download must write the same .show as Python's.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/show_file.dart';

import 'emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';
const _channels = 'test/core_data/shows/app_channels.show';
const _flags = 'test/core_data/shows/app_flags.show';

void main() {
  final port = 28000 + pid % 1000;
  Emulator? emu;
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('dled_io_');
    emu = await Emulator.start(port, show: _m400);
  });
  tearDownAll(() {
    emu?.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<void> withClient(Future<void> Function(LpuClient c) body) async {
    if (emu == null) {
      markTestSkipped('python / emulator not available');
      return;
    }
    final c = await LpuClient.connect('127.0.0.1', port: port);
    try {
      await body(c);
    } finally {
      await c.close();
    }
  }

  // Tests run in order and share the emulator's show.

  test('download gives the show the emulator holds', () => withClient((c) async {
        final r = await download(c);
        expect(compareShows(parseShow(File(_m400).readAsStringSync()), r.show), isEmpty);
        expect(r.info.alias, 'EMU');
        expect(r.info.firmware, '1.29');
      }));

  test('Dart and Python downloads write byte-identical .show files', () => withClient((c) async {
        final pyPath = '${tmp.path}/python.show';
        if (!await pythonDownloadTo(port, pyPath)) {
          markTestSkipped('python download failed');
          return;
        }
        final dart = writeShow((await download(c)).show);
        expect(dart, File(pyPath).readAsStringSync());
      }));

  test('upload replaces the show; Dart and Python read it back the same', () => withClient((c) async {
        final show = parseShow(File(_channels).readAsStringSync());
        await upload(c, show);
        expect(compareShows(show, (await download(c)).show), isEmpty);
        final pyPath = '${tmp.path}/after_upload.show';
        expect(await pythonDownloadTo(port, pyPath), isTrue);
        expect(compareShows(show, parseShow(File(pyPath).readAsStringSync())), isEmpty);
      }));

  test('names and patch flags go up and come back', () => withClient((c) async {
        final show = parseShow(File(_flags).readAsStringSync());
        await upload(c, show);
        final back = (await download(c)).show;
        expect(compareShows(show, back), isEmpty);
        expect([back.fixture(0)!.name, back.fixture(0)!.invertPan, back.fixture(3)!.virtualDimmer],
            ['fixt 1', true, true]);
      }));

  test('GO, release and release all change the playback state', () => withClient((c) async {
        await upload(c, parseShow(File(_m400).readAsStringSync()));
        Future<int?> active(int pb) async =>
            playbackState((await c.read(0x29, 0x30, i1: pb)).body).activeCue;
        expect(await active(0), isNull);
        await go(c, 0);
        expect(await active(0), 0);
        await go(c, 0);
        expect(await active(0), 1);
        await release(c, 0);
        expect(await active(0), isNull);
        await go(c, 0);
        await go(c, 1);
        await releaseAll(c);
        expect([await active(0), await active(1)], [null, null]);
      }));

  test('device settings', () => withClient((c) async {
        await setAlias(c, 'from dart');
        await setArtNet(c, enabled: true, universe: 5);
        await setSacn(c, enabled: true, universe: 7);
        final i = await readDevice(c, Show());
        expect([i.alias, i.artNetEnabled, i.artNetUniverse, i.artNetUniverseRaw, i.sacnEnabled, i.sacnUniverse],
            ['from dart', true, 5, 80, true, 7]);
      }));

  test('compareShows reports real differences', () {
    final a = parseShow(File(_flags).readAsStringSync());
    final b = parseShow(File(_flags).readAsStringSync());
    b.fixtures.first.name = 'other';
    b.fixtures.removeLast();
    expect(compareShows(a, b), ["fixture 1: name 'fixt 1' != 'other'", 'fixture 4: missing on LPU']);
  });
}
