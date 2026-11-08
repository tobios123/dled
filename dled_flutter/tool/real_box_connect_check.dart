// real_box_connect_check.dart -- connect to the LPU through the DLED bridge
// (ESP32) the way the light page does, from the PC, and report how it went.
//
//   dart run tool/real_box_connect_check.dart [box-ip | direct] [lpu-ip] [rounds] [trace] [slow]
//
// A local UDP port stands in for the LPU: everything sent to it goes over the
// box's WebSocket (/vn) to the LPU, the answers come back the same way. So
// LpuSession.connect (show download, live follow) runs unchanged, through
// the box. Prints per round: time, requests, resends, datagrams both ways.
// "trace": for every read sent more than once, when each attempt went out
// and when answers came back (ms from the start), and the gaps in the
// datagram streams around it.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'box_messages.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_session.dart';

Future<void> main(List<String> args) async {
  final box = args.isNotEmpty ? args[0] : '192.168.1.102';
  final lpu = args.length > 1 ? args[1] : '192.168.1.12';
  final rounds = args.length > 2 ? int.parse(args[2]) : 5;
  final lpuIp = lpu.split('.').map(int.parse).toList();
  final trace = args.contains('trace');
  // like the light page (light/api.dart); "slow" keeps 600 ms to compare
  if (!args.contains('slow')) LpuClient.readFirstTimeout = const Duration(milliseconds: 200);

  // box "direct": straight UDP from this PC, like the Windows app (to compare)
  if (box == 'direct') {
    for (var r = 1; r <= rounds; r++) {
      final sw = Stopwatch()..start();
      final s = await LpuSession.connect(lpu);
      print('direct round $r: connected in ${sw.elapsedMilliseconds} ms; '
          'requests ${s.client.exchanges}, resends ${s.client.resends}');
      await s.close();
      await Future.delayed(const Duration(seconds: 1));
    }
    exit(0);
  }

  for (var r = 1; r <= rounds; r++) {
    final ws = await BoxSocket.open(box, noDelay: true);
    final local = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    InternetAddress? clientAddr;
    int? clientPort;
    var up = 0, down = 0;
    final clock = Stopwatch()..start();
    // read key (object prop [i1,i2,i3]) -> times (ms) of requests / answers
    final sent = <String, List<double>>{}, answered = <String, List<double>>{};
    String? key(Uint8List d, bool request) {
      final f = Frame.parse(d);
      if (f == null || f.isNotification || f.mask != 0xffff) return null;
      if (request != (f.type == tNoBody)) return null; // a read asks with type 1d
      return '${f.op.toRadixString(16)}/${f.prop.toRadixString(16)} [${f.i1},${f.i2},${f.i3}]';
    }
    double now() => clock.elapsedMicroseconds / 1000;
    final got = <String>[]; // what came back (shown when a round fails)
    // client -> box
    local.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = local.receive();
      if (d == null) return;
      clientAddr = d.address;
      clientPort = d.port;
      final m = Uint8List(7 + d.data.length)
        ..[0] = 1
        ..setRange(1, 5, lpuIp)
        ..[5] = vnPort >> 8
        ..[6] = vnPort & 0xff
        ..setRange(7, 7 + d.data.length, d.data);
      ws.send(m);
      up++;
      final k = key(d.data, true);
      if (k != null) (sent[k] ??= []).add(now());
    });
    // box -> client
    ws.onMessage = (m) {
      if (trace && got.length < 40) {
        // the senders: [ch][ip][port] of each datagram in the message
        final b = Uint8List.fromList(m);
        final recs = <Uint8List>[];
        if (b.isNotEmpty && b[0] != 0) {
          recs.add(b);
        } else {
          for (var at = 1; at + 2 <= b.length;) {
            final n = b[at] << 8 | b[at + 1];
            if (at + 2 + n > b.length) break;
            recs.add(Uint8List.sublistView(b, at + 2, at + 2 + n));
            at += 2 + n;
          }
        }
        for (final r in recs) {
          if (r.length >= 7 && r.length < 40) got.add('  from ${r[1]}.${r[2]}.${r[3]}.${r[4]}:${r[5] << 8 | r[6]} ch ${r[0]}');
        }
      }
      if (clientAddr == null) return;
      for (final d in boxDatagrams(m)) {
        final k = key(d, false);
        if (k != null) (answered[k] ??= []).add(now());
        if (got.length < 40) {
          final f = Frame.parse(d);
          got.add('${now().toStringAsFixed(0)}ms ${f == null ? '${d.length} bytes' : f.toString().replaceAll('Frame', '')}');
        }
        sendLocal(local, d, clientAddr!, clientPort!);
        down++;
      }
    };

    final sw = Stopwatch()..start();
    try {
      final s = await LpuSession.connect('127.0.0.1', port: local.port);
      final c = s.client;
      print('round $r: connected in ${sw.elapsedMilliseconds} ms, '
          '${s.downloaded.show.playbacks.length} playbacks, ${s.downloaded.show.fixtures.length} fixtures; '
          'requests ${c.exchanges}, resends ${c.resends}; datagrams up $up, down $down');
      await s.close();
      if (trace) print('  came back first: ${got.where((g) => !g.startsWith('  from')).take(12).join('; ')}');
      if (trace) {
        String t(List<double>? l) => l == null ? 'none' : l.map((x) => x.toStringAsFixed(1)).join(', ');
        for (final e in sent.entries.where((e) => e.value.length > 1)) {
          print('  resent ${e.key}: sent ${t(e.value)}; answers ${t(answered[e.key])}');
        }
      }
    } catch (e) {
      print('round $r: FAILED after ${sw.elapsedMilliseconds} ms: $e; datagrams up $up, down $down');
      if (trace) print('  came back: ${got.join('; ')}');
    }
    local.close();
    await ws.close();
    await Future.delayed(const Duration(seconds: 1));
  }
  exit(0);
}
