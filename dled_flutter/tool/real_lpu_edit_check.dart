// Check the v0.7 editing frames on a real LPU, as harmlessly as possible:
//   dart run tool/real_lpu_edit_check.dart <ip> [port]
// 1. backs up the LPU's show to lpu_backups/
// 2. does every edit on two playback slots that are EMPTY on this LPU
//    (allocate, insert, write cue, label, properties, swap, delete), reading
//    each result back through a second client
// 3. empties those two slots again, uploads the backed-up show back
//    (release, backup, upload, verify) and checks the LPU equals the backup.
// Exit code 0 = every check passed.

import 'dart:io';
import 'dart:typed_data';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/core/show_file.dart';

var failures = 0;

void check(String what, bool ok, [Object? got]) {
  stdout.writeln('${ok ? 'OK  ' : 'FAIL'}  $what${ok || got == null ? '' : '  (got $got)'}');
  if (!ok) failures++;
}

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '192.168.1.12';
  final port = args.length > 1 ? int.parse(args[1]) : vnPort;
  stdout.writeln('connecting to $ip:$port (download takes a while) ...');
  final s = await LpuSession.connect(ip, port: port);
  final lpu = await LpuClient.connect(ip, port: port); // reads results back
  final backup = s.show;
  final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
  final path = '../lpu_backups/before_edit_check_$stamp.show';
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(writeShow(backup));
  stdout.writeln('backup: $path (${backup.fixtures.length} fixtures, ${backup.playbacks.length} playbacks)');

  final used = {for (final p in backup.playbacks) p.index};
  final free = [for (var i = 63; i >= 0; i--) if (!used.contains(i)) i];
  if (free.length < 2) {
    stderr.writeln('need two empty playback slots - none touched');
    exit(1);
  }
  final p = free[1], q = free[0]; // e.g. 63 and 64 (1-based) when free
  stdout.writeln('editing on empty playbacks ${p + 1} and ${q + 1}');

  Future<PlaybackStatus> st(int pb) async => playbackState((await lpu.read(objPlayback, 0x30, i1: pb)).body);
  Future<Object> val(int op, int prop, {int i1 = 0, int i2 = 0}) => lpu.readValue(op, prop, i1: i1, i2: i2);

  await s.releaseAll();
  await s.allocateCues(p, 1);
  check('allocate: playback ${p + 1} has 1 cue', (await st(p)).cues == 1, (await st(p)).cues);
  await s.insertCue(p, 1);
  check('insert: 2 cues', (await st(p)).cues == 2, (await st(p)).cues);

  final block = Uint8List(blockSize);
  block[16] = 0x80; // fixture slot 1: intensity 50 %
  final cue = ShowCue(label: 'edit check', fadeMs: 2500, delayMs: 1000, follow: true,
      blocks: [block, Uint8List(0), Uint8List(0), Uint8List(0)]);
  await s.writeCue(p, 0, cue);
  check('write cue: label', await val(objCue, 0x05, i1: p) == 'edit check');
  check('write cue: fade 2.5 s', await val(objCue, 0x29, i1: p) == 2500, await val(objCue, 0x29, i1: p));
  check('write cue: delay 1 s', await val(objCue, 0x2b, i1: p) == 1000, await val(objCue, 0x2b, i1: p));
  check('write cue: follow', await val(objCue, 0x27, i1: p) == 1);
  final back = (await lpu.read(objCue, 0x46, i1: p, i2: 0, i3: 0)).body;
  check('write cue: data block', decodeRecord(back, 0).intensity >> 8 == 0x80, decodeRecord(back, 0).intensity);

  await s.writePlaybackLabel(p, 'EDIT CHECK');
  check('playback label', await val(objPlayback, 0x05, i1: p) == 'EDIT CHECK');
  await s.writePlaybackProps(p, goMode: 'Toggle', repeat: 'Bounce', exclusive: true);
  final b = (await lpu.read(objPlayback, 0x30, i1: p)).body;
  check('properties: Toggle, Bounce, exclusive', b[0] >> 4 == 1 && b[1] >> 4 == 1 && b[0] & 2 != 0, b);

  await s.swapPlaybacks(p, q);
  check('swap: label moved to ${q + 1}', await val(objPlayback, 0x05, i1: q) == 'EDIT CHECK');
  check('swap: cues moved to ${q + 1}', (await st(q)).cues == 2 && (await st(p)).cues == 0,
      '${(await st(q)).cues}/${(await st(p)).cues}');
  await s.swapPlaybacks(p, q);
  check('swap back', await val(objPlayback, 0x05, i1: p) == 'EDIT CHECK' && (await st(p)).cues == 2);

  await s.deleteCues(p, 1, 1);
  check('delete 1 cue: 1 left', (await st(p)).cues == 1, (await st(p)).cues);
  await s.deleteCues(p, 0, 1);
  check('delete last cue: 0 left', (await st(p)).cues == 0, (await st(p)).cues);

  // Empty both slots again (29 1d 38 = delete playback, as the upload does).
  for (final x in [p, q]) {
    await lpu.write(objPlayback, tNoBody, 0x38, i1: x);
  }

  stdout.writeln('uploading the backed-up show back (release, backup, upload, verify) ...');
  final r = await s.uploadShow(backup, progress: (step) => stdout.writeln('  $step'));
  check('upload verified', r.diffs.isEmpty, r.diffs.take(5).toList());

  final now = (await download(lpu)).show;
  final diffs = compareShows(backup, now);
  check('LPU equals the backup', diffs.isEmpty, diffs.take(5).toList());
  final stuck = <int>[];
  for (final pb in now.playbacks) {
    final x = await st(pb.index);
    if (x.state == 4 || (x.activeCue != null && x.activeCue! >= x.cues)) stuck.add(pb.index + 1);
  }
  check('no playback stuck', stuck.isEmpty, stuck);

  await lpu.close();
  await s.close();
  stdout.writeln(failures == 0 ? 'ALL CHECKS PASSED' : '$failures CHECK(S) FAILED');
  exit(failures == 0 ? 0 : 1);
}
