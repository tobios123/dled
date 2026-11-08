// real_lpu_two_clients_check.dart -- does the LPU answer late when a second
// client from the same IP address is connected? Measures 300 reads one at a
// time, alone and then with an idle second client (only its keepalives),
// both straight from this PC.
//
//   dart run tool/real_lpu_two_clients_check.dart [lpu-ip]

import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';

Future<String> measure(LpuClient c) async {
  final t = <int>[];
  for (var i = 0; i < 300; i++) {
    final sw = Stopwatch()..start();
    await c.read(objPlayback, 0x30, i1: i % 8);
    t.add(sw.elapsedMicroseconds);
  }
  t.sort();
  String ms(int us) => (us / 1000).toStringAsFixed(1);
  return 'median ${ms(t[150])} ms, max ${ms(t.last)} ms, over 100 ms: ${t.where((x) => x > 100000).length}, '
      'resends ${c.resends}';
}

Future<void> main(List<String> args) async {
  final lpu = args.isNotEmpty ? args[0] : '192.168.1.12';
  final a = await LpuClient.connect(lpu);
  print('alone:             ${await measure(a)}');
  await a.close();
  final idle = await LpuClient.connect(lpu); // keepalives only
  final b = await LpuClient.connect(lpu);
  print('with a 2nd client: ${await measure(b)}');
  await b.close();
  await idle.close();
  final c = await LpuClient.connect(lpu);
  print('alone again:       ${await measure(c)}');
  await c.close();
  exit(0);
}
