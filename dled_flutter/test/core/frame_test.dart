// Frame codec against real captured LPU traffic, parsed by the Python
// reference (test/core_data/frames.json, made by analysis/scripts/make_dart_goldens.py).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';

Uint8List _hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final frames = (jsonDecode(File('test/core_data/frames.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('captures hold a useful mix of frames', () {
    expect(frames.length, greaterThan(200));
    expect(frames.map((f) => f['op']).toSet(), containsAll([objFixture, objPlayback, objCue, objGlobal]));
  });

  test('every captured frame parses like the Python reference', () {
    for (final f in frames) {
      final p = Frame.parse(_hex(f['hex'] as String))!;
      final what = f['hex'].toString().substring(0, 40);
      expect([p.op, p.type, p.prop, p.i1, p.i2, p.i3, p.mask, p.seq],
          [f['op'], f['type'], f['prop'], f['i1'], f['i2'], f['i3'], f['mask'], f['seq']],
          reason: what);
      expect(_toHex(p.body), f['body'], reason: what);
      final v = f['value'];
      if (v is String) expect(p.value(), v, reason: what);
      if (v is int) expect(p.value(), v, reason: what);
      if (v is double) expect(p.value() as double, closeTo(v, 1e-6), reason: what);
    }
  });

  test('encoding a parsed frame gives the captured bytes back', () {
    for (final f in frames) {
      final raw = _hex(f['hex'] as String);
      final p = Frame.parse(raw)!;
      // Byte 3 and 16-19 are always 0 in our encoder; compare only frames where
      // the capture has them 0 too (all known frames do).
      if (raw[3] != 0 || raw.sublist(16, 20).any((b) => b != 0)) continue;
      expect(_toHex(p.encode()), _toHex(raw.sublist(0, headerSize + p.body.length)));
    }
  });

  test('values', () {
    expect(encStr('EMU 1'), [0x45, 0x4d, 0x55, 0x20, 0x31, 0]);
    expect(decStr(Uint8List.fromList([0x41, 0x42, 0, 0x43])), 'AB');
    expect(encU32(0x00010000), [0, 0, 1, 0]);
    expect(decodeValue(tFloat, encFloat(0.5)), 0.5);
    expect(decodeValue(tBool | tNotify, encBool(true)), 1);
  });

  test('short device properties', () {
    expect(shortReadFrame(ShortProp.alias), [0, 0x11, 0, 0, 0, 0, 0, 0, 0]);
    final w = shortWriteFrame(ShortProp.aliasWrite, encStr('EMU'));
    expect(w.sublist(0, 9), [0, 0x12, 0, 0, 0, 0, 0, 0, 4]);
    expect(isShortReply(w, ShortProp.aliasWrite), isTrue);
    expect(decStr(shortValue(w)), 'EMU');
  });

  test('frame with notification bit', () {
    final f = Frame(objPlayback, tU32 | tNotify, 0x30, i1: 3, mask: 0);
    final p = Frame.parse(f.encode())!;
    expect(p.isNotification, isTrue);
    expect(p.baseType, tU32);
    expect(p.mask, 0);
  });
}
