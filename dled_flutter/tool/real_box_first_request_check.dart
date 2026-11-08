// real_box_first_request_check.dart -- is the first datagram on a new box
// channel answered? Opens a fresh WebSocket per round, sends one read
// (playback 1 state) on a new channel and waits up to 1 s; then a second
// one on the same channel.
//
//   dart run tool/real_box_first_request_check.dart [box-ip] [lpu-ip] [rounds]

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'box_messages.dart';
import 'package:dled/core/frame.dart';

Future<void> main(List<String> args) async {
  final box = args.isNotEmpty ? args[0] : '192.168.1.102';
  final lpu = args.length > 1 ? args[1] : '192.168.1.12';
  final rounds = args.length > 2 ? int.parse(args[2]) : 5;
  final ip = lpu.split('.').map(int.parse).toList();
  Uint8List msg(int seq, {int channel = 1}) {
    final d = Frame(objPlayback, tNoBody, 0x30, seq: seq).encode();
    return Uint8List(7 + d.length)
      ..[0] = channel
      ..setRange(1, 5, ip)
      ..[5] = vnPort >> 8
      ..[6] = vnPort & 0xff
      ..setRange(7, 7 + d.length, d);
  }

  for (var r = 1; r <= rounds; r++) {
    final ws = await BoxSocket.open(box, noDelay: true);
    final answers = StreamController<double>.broadcast();
    final sw = Stopwatch()..start();
    ws.onMessage = (m) {
      for (final d in boxDatagrams(m)) {
        final f = Frame.parse(d);
        if (f != null && f.op == objPlayback && f.prop == 0x30 && !f.isNotification) {
          answers.add(sw.elapsedMicroseconds / 1000);
        }
      }
    };
    Future<String> ask(int seq, {int channel = 1}) async {
      final t0 = sw.elapsedMicroseconds / 1000;
      final a = answers.stream.first.timeout(const Duration(seconds: 1), onTimeout: () => -1);
      ws.send(msg(seq, channel: channel));
      final t = await a;
      return t < 0 ? 'NO ANSWER' : 'answered in ${(t - t0).toStringAsFixed(1)} ms';
    }

    final first = await ask(1);
    final second = await ask(2);
    print('round $r: first request on a new channel: $first; second: $second');
    if (r == rounds) {
      // one WebSocket, a new channel each time; then 20 on one channel
      for (var ch = 2; ch <= 6; ch++) {
        print('  same WebSocket, new channel $ch: ${await ask(ch * 10, channel: ch)}, then ${await ask(ch * 10 + 1, channel: ch)}');
      }
      final res = <String>[];
      for (var i = 0; i < 20; i++) {
        res.add(await ask(100 + i, channel: 6));
      }
      print('  20 more on channel 6: ${res.where((x) => x == 'NO ANSWER').length} without answer, '
          'slowest ${res.where((x) => x != 'NO ANSWER').map((x) => double.parse(x.split(' ')[2])).fold(0.0, (a, b) => a > b ? a : b)} ms');
    }
    await ws.close();
    await Future.delayed(const Duration(milliseconds: 500));
  }
  exit(0);
}
