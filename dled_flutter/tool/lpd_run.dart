// Run an LPD test on the real LPU and record its DMX:
//   dart run tool/lpd_run.dart TEST [--ip IP] [--sacn] [--no-backup] [--no-upload] [--port N]
//                        [--lpu-port N] [--rec-dir DIR] [--recorded-show]
//   dart run tool/lpd_run.dart --list
// 1. backs up the LPU's show to lpu_backups/ (the test replaces it),
// 2. uploads the test's show (tool/lpd/tests.dart) and checks the patch,
// 3. runs the steps while recording Art-Net (or sACN),
// 4. writes lpd/tests/TEST.show + TEST.steps.json (the test as data),
//    lpd/recordings/TEST_<time>.jsonl (every DMX change, with the steps as
//    marks) and TEST_<time>.txt (per fixture channel: the DMX value at each
//    snap).
// The LPU keeps the test show afterwards; restore with lpu-show-upload.
// Against the LPD-1 (milestone 4): --lpu-port for its VN port (the PC build
// on 26945), --rec-dir lpd/box_recordings so its recordings stay apart, and
// --recorded-show uploads lpd/tests/TEST.show as it is (the show the LPU's
// recording was made with; the encoder may have changed since, e.g. FX speed
// +100 % 128 -> 127) instead of writing it again.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dled/core/cue_codec.dart';
import 'package:dled/core/fixture_codes.dart' show attrForCode;
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/show_file.dart';

import 'lpd/dmx_capture.dart';
import 'lpd/tests.dart';

final root = File(Platform.script.toFilePath()).parent.parent.parent.path;

String stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}_${two(n.hour)}-${two(n.minute)}-${two(n.second)}';
}

Future<void> main(List<String> args) async {
  var ip = '192.168.1.12';
  var source = DmxSource.artnet;
  var backup = true, doUpload = true;
  var localPort = 0; // --port: send from this UDP port (the reference app uses 16945)
  var lpuPort = vnPort; // --lpu-port: the device's VN port
  var recDir = 'lpd/recordings';
  var recordedShow = false;
  String? name;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--ip':
        ip = args[++i];
      case '--sacn':
        source = DmxSource.sacn;
      case '--no-backup':
        backup = false;
      case '--no-upload':
        doUpload = false;
      case '--port':
        localPort = int.parse(args[++i]);
      case '--lpu-port':
        lpuPort = int.parse(args[++i]);
      case '--rec-dir':
        recDir = args[++i];
      case '--recorded-show':
        recordedShow = true;
      case '--list':
        for (final t in lpdTests) {
          stdout.writeln('${t.name.padRight(12)} ${t.about}');
        }
        return;
      default:
        name = args[i];
    }
  }
  final test = lpdTests.where((t) => t.name == name).firstOrNull;
  if (test == null) {
    stderr.writeln('which test? ${lpdTests.map((t) => t.name).join(', ')}');
    exit(2);
  }
  final when = stamp();

  // the test as data
  final tests = Directory('$root/lpd/tests')..createSync(recursive: true);
  final showFile = File('${tests.path}/${test.name}.show');
  final Show show;
  if (recordedShow) {
    show = parseShow(showFile.readAsStringSync());
  } else {
    show = test.show;
    showFile.writeAsStringSync(writeShow(show));
  }
  File('${tests.path}/${test.name}.steps.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'about': test.about, 'steps': test.steps}));

  final c = await LpuClient.connect(ip, port: lpuPort, localPort: localPort);
  if (doUpload) {
    if (backup) {
      stdout.writeln('backing up the LPU\'s show ...');
      final b = await download(c);
      final f = File('$root/lpu_backups/lpu_${ip}_$when.show')..parent.createSync(recursive: true);
      f.writeAsStringSync(writeShow(b.show));
      stdout.writeln('  ${f.path}');
    }
    stdout.writeln('uploading the test show ...');
    await upload(c, show);
    for (final f in show.fixtures) {
      final got = await readFixture(c, f.index);
      final ok = got != null && got.profile == f.profile && got.address == f.address;
      stdout.writeln('  fixture ${f.index + 1}: ${ok ? 'OK' : 'DIFFERS: ${got?.definition} @${got?.address}'}');
    }
  }

  await cleanUp(c);
  // The LPU sometimes keeps every playback in "releasing" after a show
  // replace (FINDINGS 20.13): GO then does nothing until a power cycle.
  await releaseAll(c);
  await Future.delayed(const Duration(seconds: 1));
  for (final p in test.show.playbacks) {
    if (playbackState((await c.read(objPlayback, 0x30, i1: p.index)).body).state == 4) {
      stderr.writeln('playback ${p.index + 1} is stuck in "releasing" (FINDINGS 20.13): '
          'power-cycle the LPU, then run again with --no-upload');
      await c.close();
      exit(1);
    }
  }

  final rec = File('$root/$recDir/${test.name}_$when.jsonl')..parent.createSync(recursive: true);
  final cap = DmxCapture(ip, source: source);
  await cap.start(record: rec);
  await cap.started.timeout(const Duration(seconds: 5),
      onTimeout: () => throw StateError('no ${source.name} from $ip in 5 s (tool/lpd_output.dart)'));
  // the device's notifications go into the recording too ("note": op type
  // prop i1 i2 body as hex), to compare the box's with the LPU's
  final notes = c.notifications.listen((f) => cap.note(
      '${f.op.toRadixString(16).padLeft(2, '0')} ${(f.type & 0x7f).toRadixString(16).padLeft(2, '0')} '
      '${f.prop.toRadixString(16).padLeft(2, '0')} ${f.i1} ${f.i2} '
      '${f.body.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'));
  final snaps = <String, List<int>>{};
  try {
    for (final s in test.steps) {
      await runStep(c, cap, s, snaps);
    }
  } finally {
    await cleanUp(c);
  }
  await notes.cancel();
  await cap.stop();
  await c.close();

  final report = File('${rec.path.substring(0, rec.path.length - 6)}.txt');
  report.writeAsStringSync(makeReport(test, snaps, source, cap.universe, when));
  stdout.writeln(report.readAsStringSync());
  stdout.writeln('recording: ${rec.path}\nreport:    ${report.path}');
  exit(0);
}

/// Programmer cleared (CLEAR works only with EDIT open), EDIT closed (while
/// it is open GO does nothing and the playbacks show "releasing"),
/// everything released.
Future<void> cleanUp(LpuClient c) async {
  await c.write(objGlobal, tBool, 0x35, body: encBool(false));
  await c.write(objGlobal, tNoBody, 0x38);
  await c.write(objGlobal, tBool, 0x35, body: encBool(true));
  await releaseAll(c);
}

/// One step; a write the LPU does not answer is marked in the recording
/// ("failed") and the test goes on.
Future<void> runStep(LpuClient c, DmxCapture cap, Step s, Map<String, List<int>> snaps) async {
  final op = s['op'] as String, pb = s['pb'] as int?;
  cap.mark(op, {...s}..remove('op'));
  try {
    switch (op) {
      case 'releaseAll':
        await releaseAll(c);
      case 'go':
        await go(c, pb!);
      case 'release':
        await release(c, pb!);
      case 'flash':
        await flash(c, pb!, hold: Duration(milliseconds: s['ms'] as int? ?? 500));
      case 'intensity':
        await setPlayback(c, pb!, intensity: (s['value'] as num).toDouble());
      case 'speed':
        await setPlayback(c, pb!, speed: (s['value'] as num).toDouble());
      case 'goDown' || 'goUp' || 'flashDown' || 'flashUp':
        // a button held: GO 0x22 / FLASH 0x23 down (true) or up (false)
        await c.write(objPlayback, tBool, op.startsWith('go') ? 0x22 : 0x23,
            i1: pb!, body: encBool(op.endsWith('Down')));
      case 'edit':
        // the EDIT page open (true) / closed: 2c 02 35 = 0 / 1 (as the reference app)
        await c.write(objGlobal, tBool, 0x35, body: encBool(!(s['value'] as bool)));
      case 'select':
        final mask = Uint8List(8);
        for (final slot in (s['slots'] as List).cast<int>()) {
          mask[slot >> 3] |= 1 << (slot & 7);
        }
        await c.write(objGlobal, tBlob, 0x3c, body: mask);
      case 'prog':
        // programmer sliders 0-255 ('In', 'R' ... 'Pan' / 'Tilt' 0-255, 128 = centre)
        final v = (s['values'] as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
        for (final w in sliderWrites(v, v['Pan'] ?? 127.5, v['Tilt'] ?? 127.5, v.keys)) {
          await c.write(objProgrammer, w.type, 0x33, i1: w.attr, body: w.body);
        }
      case 'progFx':
        final fx = s['fx'] as List; // [generator, waveform, size, speed, phase]
        final w = fxWrite(fx[0] as String, (
          waveform: fx[1] as String,
          size: (fx[2] as num).toDouble(),
          speed: (fx[3] as num).toDouble(),
          phase: (fx[4] as num).toDouble()
        ));
        await c.write(objProgrammer, w.type, 0x33, i1: w.attr, body: w.body);
      case 'progClear':
        await c.write(objGlobal, tNoBody, 0x38);
      case 'load':
        await c.write(objGlobal, tU32, 0x3f, body: encU32(pb!)); // the edited playback (DMX_ENGINE.md 12)
        await c.write(objGlobal, tNoBody, 0x36, i1: pb, i2: s['cue'] as int);
      // live edits, as the app sends them (lpu_session.dart)
      case 'record':
        await c.write(objGlobal, tU32, 0x3f, body: encU32(pb!));
        await c.write(objGlobal, tNoBody, 0x37, i1: pb, i2: s['cue'] as int);
      case 'swap':
        await c.write(objAction, tNoBody, 0x49, i1: pb!, i2: s['with'] as int);
      case 'insertCue':
        await c.write(objPlayback, tU32, 0x03, i1: pb!, body: encU32(s['at'] as int));
      case 'deleteCue':
        await c.write(objPlayback, tNoBody, 0x04, i1: pb!, i2: s['cue'] as int, i3: 1);
      case 'cueFade':
        await c.write(objCue, tU32, 0x2a, i1: pb!, i2: s['cue'] as int, body: encU32(s['ms'] as int));
      case 'wait':
        await Future.delayed(Duration(milliseconds: s['ms'] as int));
      case 'snap':
        snaps[s['name'] as String] = List.of(cap.dmx);
      default:
        throw ArgumentError('unknown step $op');
    }
    stdout.writeln('  ${jsonEncode(s)}');
  } on LpuError catch (e) {
    cap.mark('failed', {'step': op, 'error': '$e'});
    stdout.writeln('  ${jsonEncode(s)}  FAILED: $e');
  }
}

/// Per fixture channel: code, name, the DMX value the first cue should give
/// at full (expectedDmx), and the DMX value at every snap; then channels
/// outside every fixture that were not 0.
String makeReport(LpdTest test, Map<String, List<int>> snaps, DmxSource source, int? uni, String when) {
  final out = StringBuffer()
    ..writeln('LPD test "${test.name}", $when, ${source.name} universe $uni')
    ..writeln(test.about)
    ..writeln();
  final names = snaps.keys.toList();
  final used = <int>{};
  final cue = test.show.playbacks.isEmpty || test.show.playbacks.first.cues.isEmpty
      ? null
      : test.show.playbacks.first.cues.first;
  for (final f in test.show.fixtures) {
    out.writeln('Fixture ${f.index + 1} "${f.name}" at DMX ${f.address} (${f.model}, ${f.mode})');
    out.writeln('${'ch'.padLeft(4)}  code  ${'channel'.padRight(16)} ${'cue'.padLeft(5)}  '
        '${names.map((n) => n.padLeft(10)).join()}');
    final codes = f.codes;
    for (var i = 0; i < codes.length; i++) {
      final ch = f.address + i;
      used.add(ch);
      final code = codes[i];
      final label = probeChannels.where((p) => p.$1 == code).map((p) => p.$2).firstOrNull ?? attrForCode(code) ?? '?';
      final want = cue == null ? null : expectedDmx(cue.record(f.index).raw, code);
      final inCue = want == null ? '' : '$want';
      out.writeln('${'$ch'.padLeft(4)}  ${code.toRadixString(16).padLeft(2, '0')}    ${label.padRight(16)} '
          '${inCue.padLeft(5)}  ${names.map((n) => '${snaps[n]![ch - 1]}'.padLeft(10)).join()}');
    }
    out.writeln();
  }
  final other = <String>[];
  for (var ch = 1; ch <= 512; ch++) {
    if (used.contains(ch)) continue;
    final vals = names.map((n) => snaps[n]![ch - 1]).toList();
    if (vals.any((v) => v != 0)) other.add('$ch: ${vals.join(' / ')}');
  }
  out.writeln('Other channels not 0 (${names.join(' / ')}): ${other.isEmpty ? 'none' : ''}');
  for (final o in other) {
    out.writeln('  $o');
  }
  return out.toString();
}
