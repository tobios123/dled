// real_box_flash_check.dart -- two pages' worth of LPU connections through
// the DLED bridge, one of them holds FLASH on a playback; reports whether both
// stay connected and the box keeps answering.
//
//   dart run tool/real_box_flash_check.dart [box-ip] [lpu-ip] [playback 1-64] [seconds]

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'box_messages.dart';
import 'package:dled/core/frame.dart' show vnPort;
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/lpu_session.dart';

/// A local UDP port that relays to the LPU through the box's WebSocket.
class BoxRelay {
  final WebSocket ws;
  final RawDatagramSocket local;
  int up = 0, down = 0;
  BoxRelay._(this.ws, this.local);

  static Future<BoxRelay> open(String box, List<int> lpuIp) async {
    final r = BoxRelay._(await WebSocket.connect('ws://$box/vn'),
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    InternetAddress? addr;
    int? port;
    r.local.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = r.local.receive();
      if (d == null) return;
      addr = d.address;
      port = d.port;
      r.ws.add(Uint8List(7 + d.data.length)
        ..[0] = 1
        ..setRange(1, 5, lpuIp)
        ..[5] = vnPort >> 8
        ..[6] = vnPort & 0xff
        ..setRange(7, 7 + d.data.length, d.data));
      r.up++;
    });
    r.ws.listen((m) {
      if (m is! List<int> || addr == null) return;
      for (final d in boxDatagrams(m)) {
        sendLocal(r.local, d, addr!, port!);
        r.down++;
      }
    }, onDone: () => print('  WebSocket closed by the box'));
    return r;
  }
}

Future<String> boxAnswers(String box) async {
  final sw = Stopwatch()..start();
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final rq = await c.getUrl(Uri.parse('http://$box/api/shows'));
    final rs = await rq.close().timeout(const Duration(seconds: 3));
    await rs.drain<void>();
    c.close();
    return 'http ${rs.statusCode} in ${sw.elapsedMilliseconds} ms';
  } catch (e) {
    return 'http FAILED ($e)';
  }
}

Future<void> main(List<String> args) async {
  final box = args.isNotEmpty ? args[0] : '192.168.1.102';
  final lpu = args.length > 1 ? args[1] : '192.168.1.12';
  final pb = (args.length > 2 ? int.parse(args[2]) : 5) - 1;
  final secs = args.length > 3 ? int.parse(args[3]) : 8;
  final ip = lpu.split('.').map(int.parse).toList();

  final sessions = <LpuSession>[];
  final relays = <BoxRelay>[];
  final active = [0, 0];
  for (var i = 0; i < 2; i++) {
    final r = await BoxRelay.open(box, ip);
    final s = await LpuSession.connect('127.0.0.1', port: r.local.port);
    final n = i;
    s.events.listen((e) {
      if (e is ActiveCue) active[n]++;
      if (e is ConnectionLost) print('  page ${n + 1}: CONNECTION LOST ($e)');
    });
    relays.add(r);
    sessions.add(s);
    print('page ${i + 1} connected');
  }
  print('before: ${await boxAnswers(box)}');
  await sessions[0].flash(pb, true);
  print('page 1 holds FLASH on playback ${pb + 1}');
  for (var t = 1; t <= secs; t++) {
    await Future.delayed(const Duration(seconds: 1));
    print('${t}s: active-cue msgs page1 ${active[0]} page2 ${active[1]}; '
        'resends ${sessions[0].client.resends} / ${sessions[1].client.resends}; '
        'datagrams up/down ${relays[0].up}/${relays[0].down}, ${relays[1].up}/${relays[1].down}; '
        '${await boxAnswers(box)}');
  }
  try {
    await sessions[0].flash(pb, false).timeout(const Duration(seconds: 5));
    print('FLASH let go');
  } catch (e) {
    print('letting go of FLASH FAILED: $e');
  }
  await Future.delayed(const Duration(seconds: 2));
  print('after: ${await boxAnswers(box)}');
  for (final s in sessions) {
    await s.close();
  }
  exit(0);
}
