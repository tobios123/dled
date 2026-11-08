// real_lpu_flash_flood_check.dart -- how many messages the LPU sends while a
// playback is flashed (a cue chain with Follow and no times can loop fast).
//
//   dart run tool/real_lpu_flash_flood_check.dart [lpu-ip] [playback 1-64 ...]
//
// For each playback: hold FLASH 3 s, let go, wait 2 s; prints the datagrams
// per second the LPU sent to this client, by kind.

import 'dart:async';
import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_session.dart';

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '192.168.1.12';
  final pbs = args.length > 1 ? args.skip(1).map((s) => int.parse(s) - 1).toList() : [4, 5];
  final s = await LpuSession.connect(ip);
  final show = s.downloaded.show;
  final counts = <String, int>{};
  var total = 0;
  s.client.notifications.listen((f) {
    total++;
    final k = '${f.op.toRadixString(16)} ${f.baseType.toRadixString(16)} ${f.prop.toRadixString(16)}';
    counts[k] = (counts[k] ?? 0) + 1;
  });
  for (final pb in pbs) {
    final p = show.playbacks.where((x) => x.index == pb).firstOrNull;
    print('playback ${pb + 1} "${p?.label}": ${p?.cues.length} cues, '
        '${p?.cues.map((c) => '${c.follow ? 'F' : 'H'} ${c.fadeMs}/${c.delayMs}ms').join(', ')}');
    counts.clear();
    total = 0;
    final sw = Stopwatch()..start();
    await s.flash(pb, true);
    await Future.delayed(const Duration(seconds: 3));
    final held = total, heldMs = sw.elapsedMilliseconds;
    final byKind = Map.of(counts);
    await s.flash(pb, false);
    await Future.delayed(const Duration(seconds: 2));
    print('  held 3 s: $held notifications (${(held * 1000 / heldMs).round()}/s): $byKind');
    print('  2 s after letting go: ${total - held}');
  }
  await s.close();
  exit(0);
}
