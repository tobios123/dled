// frame.dart -- VN protocol frames of the LPU-1 (UDP 16945), pure Dart.
//
// Typed property frame (analysis/FINDINGS.md 20.1), 20-byte header + body:
//    0 object   1 value type   2 property   3 0
//    4-5 index1 (fixture / playback)   6-7 index2 (cue)   8-9 index3 (block)
//    10-11 mask (ff ff)   12-13 body length   14-15 sequence   16-19 0
// All numbers little-endian. Value type | 0x80 = notification (mask 0000).
// Write id = read id + 1. The LPU echoes every write byte for byte.
//
// Short device properties (9-byte request): [00, prop, 0 x6, length, value].
//
// Mirrors analysis/lpu/protocol.py; tests compare against real captures.

import 'dart:convert';
import 'dart:typed_data';

const int vnPort = 16945;
const int headerSize = 20;

// Value types.
const int tStr = 0x00;
const int tU32 = 0x01;
const int tBool = 0x02;
const int tFloat = 0x03;
const int tBlob = 0x05;
const int tPage = 0x0a;
const int tNoBody = 0x1d;
const int tNotify = 0x80;

// Objects.
const int objDevice = 0x02;
const int objArtNet = 0x0a;
const int objSacn = 0x0b;
const int objFixture = 0x1f;
const int objAction = 0x28;
const int objPlayback = 0x29;
const int objCue = 0x2b;
const int objGlobal = 0x2c;
const int objProgrammer = 0x2d;

/// The single byte the client sends ~40 times a second while connected.
const int keepaliveByte = 0xff;

class Frame {
  final int op;
  final int type;
  final int prop;
  final int i1;
  final int i2;
  final int i3;
  final int mask;
  final int seq;
  final Uint8List body;

  Frame(this.op, this.type, this.prop,
      {this.i1 = 0, this.i2 = 0, this.i3 = 0, this.mask = 0xffff, this.seq = 0, Uint8List? body})
      : body = body ?? Uint8List(0);

  bool get isNotification => type & tNotify != 0;

  /// Value type without the notification bit.
  int get baseType => type & 0x7f;

  Uint8List encode() {
    final out = Uint8List(headerSize + body.length);
    final bd = ByteData.sublistView(out);
    out[0] = op;
    out[1] = type;
    out[2] = prop;
    bd.setUint16(4, i1 & 0xffff, Endian.little);
    bd.setUint16(6, i2 & 0xffff, Endian.little);
    bd.setUint16(8, i3 & 0xffff, Endian.little);
    bd.setUint16(10, mask & 0xffff, Endian.little);
    bd.setUint16(12, body.length, Endian.little);
    bd.setUint16(14, seq & 0xffff, Endian.little);
    out.setRange(headerSize, out.length, body);
    return out;
  }

  /// Parse a typed frame; null for short frames, keepalives and XML.
  static Frame? parse(Uint8List data) {
    if (data.length < headerSize) return null;
    final bd = ByteData.sublistView(data);
    final len = bd.getUint16(12, Endian.little);
    final end = headerSize + len > data.length ? data.length : headerSize + len;
    return Frame(data[0], data[1], data[2],
        i1: bd.getUint16(4, Endian.little),
        i2: bd.getUint16(6, Endian.little),
        i3: bd.getUint16(8, Endian.little),
        mask: bd.getUint16(10, Endian.little),
        seq: bd.getUint16(14, Endian.little),
        body: Uint8List.fromList(data.sublist(headerSize, end)));
  }

  /// Decoded body: String, int (u32 / bool), double, or the raw bytes.
  Object value() => decodeValue(type, body);

  @override
  String toString() =>
      'Frame(${_h(op)} ${_h(type)} ${_h(prop)} [$i1,$i2,$i3] mask ${mask.toRadixString(16)} '
      'seq $seq, ${body.length} bytes)';
}

String _h(int b) => b.toRadixString(16).padLeft(2, '0');

// --- values -----------------------------------------------------------------

Uint8List encStr(String s) => Uint8List.fromList([...latin1.encode(_latin1Safe(s)), 0]);

String decStr(Uint8List b) {
  final end = b.indexOf(0);
  return latin1.decode(end < 0 ? b : b.sublist(0, end));
}

Uint8List encU32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v & 0xffffffff, Endian.little);
  return out;
}

Uint8List encBool(bool v) => encU32(v ? 1 : 0);

Uint8List encFloat(double v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setFloat32(0, v, Endian.little);
  return out;
}

Object decodeValue(int type, Uint8List body) {
  final t = type & 0x7f;
  final bd = ByteData.sublistView(body);
  if (t == tStr) return decStr(body);
  if (t == tFloat && body.length >= 4) return bd.getFloat32(0, Endian.little);
  if ((t == tU32 || t == tBool) && body.length >= 4) return bd.getUint32(0, Endian.little);
  return body;
}

String _latin1Safe(String s) =>
    String.fromCharCodes(s.codeUnits.map((c) => c < 256 ? c : 0x3f)); // '?' like Python's replace

// --- short device properties ------------------------------------------------

/// Short device property ids (FINDINGS 20.x).
class ShortProp {
  static const int mac = 0x00;
  static const int ipWrite = 0x02; // 4 IP bytes + 00 00; all 0 = DHCP
  static const int subnet = 0x03;
  static const int subnetWrite = 0x04; // 4 mask bytes + 00 00; all 0 = DHCP
  static const int firmware = 0x09;
  static const int pcb = 0x0a;
  static const int alias = 0x11;
  static const int aliasWrite = 0x12;
  static const int artNetUniverse = 0x34; // UI universe x 16
  static const int artNetEnabled = 0xce;
  static const int unknownEa = 0xea;
  static const int sacnEnabled = 0xef;
  static const int sacnUniverse = 0xf0;
}

Uint8List shortReadFrame(int prop) => Uint8List.fromList([0, prop, 0, 0, 0, 0, 0, 0, 0]);

Uint8List shortWriteFrame(int prop, Uint8List value) =>
    Uint8List.fromList([0, prop, 0, 0, 0, 0, 0, 0, value.length, ...value]);

/// True when [data] is the LPU's answer to a short read of [prop].
bool isShortReply(Uint8List data, int prop) => data.length > 9 && data[0] == 0 && data[1] == prop;

/// The value bytes of a short reply.
Uint8List shortValue(Uint8List data) {
  final n = data[8];
  final end = 9 + n > data.length ? data.length : 9 + n;
  return Uint8List.fromList(data.sublist(9, end));
}
