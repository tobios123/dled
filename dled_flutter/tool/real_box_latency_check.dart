// real_box_latency_check.dart -- where the time goes through the DLED bridge:
// round trip of one read at a time, and of 16 reads at once (the read
// window of a show download), direct and through the box.
//
//   dart run tool/real_box_latency_check.dart [box-ip] [lpu-ip] [nagle]
//
// The box is reached with a minimal WebSocket client on a plain socket with
// TCP_NODELAY, like a browser (dart:io's WebSocket leaves Nagle on, which
// holds back small messages); "nagle" leaves it on to compare.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'box_messages.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';

Future<void> measure(String what, LpuClient c) async {
  await c.read(objPlayback, 0x30, i1: 0); // warm up
  final one = <int>[];
  for (var i = 0; i < 50; i++) {
    final sw = Stopwatch()..start();
    await c.read(objPlayback, 0x30, i1: i % 8);
    one.add(sw.elapsedMicroseconds);
  }
  one.sort();
  final windows = <int>[];
  for (var r = 0; r < 10; r++) {
    final sw = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < 16; i++) c.read(objPlayback, 0x30, i1: i % 8)]);
    windows.add(sw.elapsedMicroseconds);
  }
  windows.sort();
  String ms(num us) => (us / 1000).toStringAsFixed(1);
  print('$what one read: median ${ms(one[25])} ms (min ${ms(one.first)}, max ${ms(one.last)}); '
      '16 at once: median ${ms(windows[5])} ms (min ${ms(windows.first)}, max ${ms(windows.last)}); '
      'resends ${c.resends}');
}

Future<void> main(List<String> args) async {
  final box = args.isNotEmpty ? args[0] : '192.168.1.102';
  final lpu = args.length > 1 ? args[1] : '192.168.1.12';
  final ip = lpu.split('.').map(int.parse).toList();

  final direct = await LpuClient.connect(lpu);
  await measure('direct :', direct);
  await direct.close();

  final ws = await BoxSocket.open(box, noDelay: !args.contains('nagle'));
  final local = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  InternetAddress? addr;
  int? port;
  local.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = local.receive();
    if (d == null) return;
    addr = d.address;
    port = d.port;
    ws.send(Uint8List(7 + d.data.length)
      ..[0] = 1
      ..setRange(1, 5, ip)
      ..[5] = vnPort >> 8
      ..[6] = vnPort & 0xff
      ..setRange(7, 7 + d.data.length, d.data));
  });
  ws.onMessage = (m) {
    if (addr == null) return;
    for (final d in boxDatagrams(m)) {
      sendLocal(local, d, addr!, port!);
    }
  };
  final viaBox = await LpuClient.connect('127.0.0.1', port: local.port);
  await measure('box    :', viaBox);
  await viaBox.close();
  await ws.close();
  exit(0);
}
