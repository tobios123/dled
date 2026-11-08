// real_lpu_seq_check.dart -- does the LPU ignore a request whose sequence
// number it answered just before (from this IP, from another port)?
// Raw UDP from this PC: one read per case, 1 s to answer.
//
//   dart run tool/real_lpu_seq_check.dart [lpu-ip]

import 'dart:async';
import 'dart:io';

import 'package:dled/core/frame.dart';

class Port {
  final RawDatagramSocket s;
  final answers = StreamController<(double, bool)>.broadcast(); // time, only an echo
  final sw = Stopwatch()..start();
  Port(this.s) {
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = s.receive();
      final f = d == null ? null : Frame.parse(d.data);
      if (f != null && !f.isNotification && f.op == objPlayback && f.prop == 0x30) {
        answers.add((sw.elapsedMicroseconds / 1000, f.type == tNoBody));
      }
    });
  }
  static Future<Port> open() async => Port(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  Future<String> ask(String lpu, int seq) async {
    final t0 = sw.elapsedMicroseconds / 1000;
    final a = answers.stream.first.timeout(const Duration(seconds: 1), onTimeout: () => (-1.0, false));
    s.send(Frame(objPlayback, tNoBody, 0x30, seq: seq).encode(), InternetAddress(lpu), vnPort);
    final (t, echo) = await a;
    if (t < 0) return 'NO ANSWER';
    return '${echo ? 'only an ECHO' : 'answered'} in ${(t - t0).toStringAsFixed(1)} ms';
  }
}

Future<void> main(List<String> args) async {
  final lpu = args.isNotEmpty ? args[0] : '192.168.1.12';
  final a = await Port.open(), b = await Port.open(), c = await Port.open();
  print('port A, seq 0x0100:        ${await a.ask(lpu, 0x0100)}');
  print('port A, seq 0x0100 again:  ${await a.ask(lpu, 0x0100)}');
  print('port B (new), seq 0x0100:  ${await b.ask(lpu, 0x0100)}');
  print('port B, seq 0x0101:        ${await b.ask(lpu, 0x0101)}');
  print('port C (new), seq 0x0101:  ${await c.ask(lpu, 0x0101)}');
  print('port C, seq 0x0777:        ${await c.ask(lpu, 0x0777)}');
  for (var i = 0; i < 8; i++) {
    final p = await Port.open();
    print('new port ${i + 1}, seq 0x0100:   ${await p.ask(lpu, 0x0100)}');
  }
  exit(0);
}
