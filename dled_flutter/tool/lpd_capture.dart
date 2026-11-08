// Watch / record the LPU's DMX output:
//   dart run tool/lpd_capture.dart [ip] [--sacn] [--secs N] [--out FILE] [--ch FROM-TO]
// Prints the channels that change (within --ch, default all), and with --out
// records everything (format: tool/lpd/dmx_capture.dart). Ctrl+C or --secs
// ends it; at the end it prints the frame rate and the non-zero channels.

import 'dart:async';
import 'dart:io';

import 'lpd/dmx_capture.dart';

Future<void> main(List<String> args) async {
  var ip = '192.168.1.12';
  var source = DmxSource.artnet;
  int? secs;
  File? out;
  var from = 1, to = 512;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--sacn') {
      source = DmxSource.sacn;
    } else if (a == '--secs') {
      secs = int.parse(args[++i]);
    } else if (a == '--out') {
      out = File(args[++i]);
    } else if (a == '--ch') {
      final r = args[++i].split('-');
      from = int.parse(r[0]);
      to = int.parse(r.length > 1 ? r[1] : r[0]);
    } else {
      ip = a;
    }
  }
  final cap = DmxCapture(ip, source: source);
  await cap.start(record: out);
  stdout.writeln('listening for ${source.name} from $ip${out == null ? '' : ', recording to ${out.path}'} ...');
  cap.changes.listen((d) {
    final shown = d.entries.where((e) => e.key >= from && e.key <= to).toList();
    if (shown.isEmpty) return;
    final t = (cap.clock.elapsedMilliseconds / 1000).toStringAsFixed(3);
    stdout.writeln('$t  ${shown.take(24).map((e) => '${e.key}=${e.value}').join(' ')}'
        '${shown.length > 24 ? ' (+${shown.length - 24})' : ''}');
  });
  final done = Completer<void>();
  ProcessSignal.sigint.watch().first.then((_) => done.isCompleted ? null : done.complete());
  if (secs != null) Timer(Duration(seconds: secs), () => done.isCompleted ? null : done.complete());
  try {
    await cap.started.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    stdout.writeln('nothing received in 5 s: is Art-Net / sACN on (tool/lpd_output.dart), '
        'and is this PC on the LPU\'s network?');
  }
  await done.future;
  final s = cap.clock.elapsedMilliseconds / 1000;
  await cap.stop();
  stdout.writeln('${cap.frames} frames in ${s.toStringAsFixed(1)} s '
      '(${(cap.frames / s).toStringAsFixed(1)}/s), universe ${cap.universe}');
  final nz = [for (var i = from; i <= to; i++) if (cap.dmx[i - 1] != 0) '$i=${cap.dmx[i - 1]}'];
  stdout.writeln('non-zero now: ${nz.isEmpty ? 'none' : nz.join(' ')}');
  exit(0);
}
