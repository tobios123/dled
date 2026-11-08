// Notification decoding, checked with notifications from real captures.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_live.dart';

Uint8List _hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  test('real captured notifications decode to the right events', () {
    final frames = (jsonDecode(File('test/core_data/frames.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>()
        .map((f) => Frame.parse(_hex(f['hex'] as String))!)
        .where((f) => f.isNotification)
        .toList();
    expect(frames, isNotEmpty);
    final seen = <Type>{};
    for (final f in frames) {
      final e = decodeNotification(f)!;
      seen.add(e.runtimeType);
      if (f.op == objPlayback && f.prop == 0x2f) {
        final v = f.value() as int;
        expect((e as ActiveCue).cue, v == 0xff ? null : v);
        expect(e.playback, f.i1);
      }
      if (f.op == objPlayback && f.prop == 0x17) {
        expect((e as FaderLevel).level, closeTo(f.value() as double, 1e-9));
      }
      if (f.prop == 0x00 && f.baseType == tU32) {
        expect((e as Changed).object, f.op);
      }
    }
    // The captures contain at least these kinds.
    expect(seen, containsAll([ActiveCue, CuePhase, Changed, FaderLevel]));
  });

  test('synthetic pushes', () {
    LiveEvent d(int op, int type, int prop, int i1, Uint8List body) =>
        decodeNotification(Frame(op, type | tNotify, prop, i1: i1, mask: 0, body: body))!;
    expect((d(objPlayback, tU32, 0x2f, 3, encU32(0xff)) as ActiveCue).cue, isNull);
    expect((d(objPlayback, tU32, 0x2f, 3, encU32(2)) as ActiveCue).cue, 2);
    expect((d(objPlayback, tU32, 0x24, 3, encU32(4)) as CuePhase).phase, 4);
    expect((d(objPlayback, tBool, 0x50, 3, encBool(true)) as GoActive).active, isTrue);
    expect((d(objPlayback, tFloat, 0x15, 3, encFloat(-0.5)) as KnobSpeed).speed, -0.5);
    expect((d(objPlayback, tU32, 0x3d, 3, encU32(6)) as CueCount).count, 6);
    expect((d(objFixture, tU32, 0x00, 9, encU32(0x121)) as Changed).code, 0x121);
    expect(decodeNotification(Frame(objPlayback, tU32, 0x2f, i1: 1)), isNull); // a reply, not a push
    expect(playbackState(Uint8List.fromList([0x10, 0x23, 6, 0xff])).activeCue, isNull);
    expect(playbackState(Uint8List.fromList([0x10, 0x23, 6, 2])), (cues: 6, activeCue: 2, state: 3));
  });
}
