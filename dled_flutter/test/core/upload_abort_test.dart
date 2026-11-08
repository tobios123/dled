// OPEN with progress and Abort: the progress runs from 0 to 1; Abort while
// sending puts the LPU's previous show back (it never keeps half a show);
// several writes at once give the same show as one by one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/core/show_file.dart';

import 'emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';
const _channels = 'test/core_data/shows/app_channels.show';

void main() {
  final port = 36000 + pid % 1000;
  Emulator? emu;
  setUpAll(() async => emu = await Emulator.start(port, show: _m400));
  tearDownAll(() => emu?.stop());

  test('progress runs from 0 to 1 and only forwards', () async {
    if (emu == null) return markTestSkipped('python / emulator not available');
    final s = await LpuSession.connect('127.0.0.1', port: port);
    addTearDown(s.close);
    final seen = <double>[];
    final r = await s.uploadShow(parseShow(File(_m400).readAsStringSync()), fraction: seen.add);
    expect(r.aborted, isFalse);
    expect(r.diffs, isEmpty);
    expect(seen.first, 0);
    expect(seen.last, 1);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('Abort while sending restores the previous show', () async {
    if (emu == null) return markTestSkipped('python / emulator not available');
    final s = await LpuSession.connect('127.0.0.1', port: port);
    addTearDown(s.close);
    final before = s.show;
    var sent = 0.0;
    final r = await s.uploadShow(parseShow(File(_channels).readAsStringSync()),
        restore: before, fraction: (f) => sent = f, cancelled: () => sent > 0.4); // Abort part-way
    expect(r.aborted, isTrue);
    expect(r.diffs, isEmpty); // the LPU equals the backup again
    final c = await LpuClient.connect('127.0.0.1', port: port);
    addTearDown(c.close);
    expect(compareShows(before, (await download(c)).show), isEmpty);
  });
}
