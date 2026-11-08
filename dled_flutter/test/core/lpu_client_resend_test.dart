// LpuClient when an answer is lost: the LPU takes a request with the
// sequence number it has just answered for a repeat and only echoes it (no
// data). So a read sent again needs a new number; a write keeps its number,
// so the LPU never carries it out twice. A fake LPU on 127.0.0.1 loses the
// first answer and behaves like that.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';

void main() {
  late RawDatagramSocket lpu;
  final seqs = <int>[]; // sequence numbers of the requests the fake got
  var lose = true; // the answer to the next request is lost

  setUp(() async {
    seqs.clear();
    lose = true;
    lpu = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    int? last;
    lpu.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = lpu.receive();
      final f = d == null ? null : Frame.parse(d.data);
      if (f == null) return; // keepalive
      seqs.add(f.seq);
      final repeat = f.seq == last;
      last = f.seq;
      if (lose) {
        lose = false;
        return;
      }
      final isRead = f.type == tNoBody && f.op == objPlayback && f.prop == 0x30;
      final answer = !isRead || repeat
          ? d!.data // a write, or a repeat: the echo
          : Frame(f.op, tU32, f.prop, i1: f.i1, seq: f.seq, body: Uint8List.fromList([7, 0, 0, 0])).encode();
      lpu.send(answer, d!.address, d.port);
    });
  });
  tearDown(() => lpu.close());

  test('a read sent again gets a new sequence number and its data', () async {
    final c = await LpuClient.connect('127.0.0.1', port: lpu.port, timeout: const Duration(milliseconds: 100));
    try {
      final f = await c.read(objPlayback, 0x30, i1: 2);
      expect(f.value(), 7);
      expect(c.resends, 1);
      expect(seqs.length, 2);
      expect(seqs[1], isNot(seqs[0]));
    } finally {
      await c.close();
    }
  });

  test('a write sent again keeps its sequence number', () async {
    final c = await LpuClient.connect('127.0.0.1', port: lpu.port, timeout: const Duration(milliseconds: 100));
    try {
      await c.write(objPlayback, tStr, 0x06, i1: 2, body: encStr('x'));
      expect(c.resends, 1);
      expect(seqs, [seqs[0], seqs[0]]);
    } finally {
      await c.close();
    }
  });

  test('readFirstTimeout: the first attempt waits that long, later ones the timeout', () async {
    LpuClient.readFirstTimeout = const Duration(milliseconds: 50);
    addTearDown(() => LpuClient.readFirstTimeout = null);
    final c = await LpuClient.connect('127.0.0.1', port: lpu.port, timeout: const Duration(seconds: 2));
    try {
      final sw = Stopwatch()..start();
      await c.read(objPlayback, 0x30, i1: 2);
      expect(sw.elapsedMilliseconds, lessThan(1000)); // not the 2 s timeout
    } finally {
      await c.close();
    }
  });
}
