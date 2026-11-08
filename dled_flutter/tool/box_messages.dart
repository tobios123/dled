// box_messages.dart -- the datagrams in one WebSocket message from the DLED
// box (for the real_box_* tools), and a WebSocket client that sends without
// delay like a browser (dart:io's WebSocket leaves Nagle on): one datagram [channel] [IPv4] [port]
// [data], or, starting with 0, several as [length u16] [datagram] each
// (lib/core/udp_web.dart reads them the same way).

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The datagrams' UDP data (without channel / address) in message [m].
List<Uint8List> boxDatagrams(List<int> m) {
  final b = m is Uint8List ? m : Uint8List.fromList(m);
  if (b.isEmpty) return const [];
  if (b[0] != 0) return b.length < 7 ? const [] : [Uint8List.sublistView(b, 7)];
  final out = <Uint8List>[];
  for (var at = 1; at + 2 <= b.length;) {
    final n = b[at] << 8 | b[at + 1];
    if (at + 2 + n > b.length || n < 7) break;
    out.add(Uint8List.sublistView(b, at + 2 + 7, at + 2 + n));
    at += 2 + n;
  }
  return out;
}

/// Pass [d] on over local UDP; a burst can find the socket busy (send gives
/// 0), so it is tried again a few times instead of being lost.
void sendLocal(RawDatagramSocket s, Uint8List d, InternetAddress to, int port) {
  for (var i = 0; i < 200 && s.send(d, to, port) == 0; i++) {}
}

/// A minimal WebSocket client (binary messages only) on a plain socket.
class BoxSocket {
  final Socket _s;
  final _rnd = Random();
  final _in = BytesBuilder();
  void Function(Uint8List message)? onMessage;
  BoxSocket._(this._s);

  static Future<BoxSocket> open(String box, {required bool noDelay}) async {
    final s = await Socket.connect(box, 80);
    s.setOption(SocketOption.tcpNoDelay, noDelay);
    final b = BoxSocket._(s);
    final upgraded = Completer<void>();
    var header = true;
    s.listen((d) {
      b._in.add(d);
      if (header) {
        final all = b._in.toBytes();
        final end = String.fromCharCodes(all).indexOf('\r\n\r\n');
        if (end < 0) return;
        header = false;
        b._in.clear();
        b._in.add(all.sublist(end + 4));
        upgraded.complete();
      }
      b._frames();
    });
    s.write('GET /vn HTTP/1.1\r\nHost: $box\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    await upgraded.future;
    return b;
  }

  // server frames: unmasked; length 7 bits, or 126 + u16
  void _frames() {
    var buf = _in.toBytes();
    var at = 0;
    while (buf.length - at >= 2) {
      var len = buf[at + 1] & 0x7f, head = 2;
      if (len == 126) {
        if (buf.length - at < 4) break;
        len = buf[at + 2] << 8 | buf[at + 3];
        head = 4;
      }
      if (buf.length - at < head + len) break;
      if (buf[at] & 0x0f == 2) onMessage?.call(Uint8List.sublistView(buf, at + head, at + head + len));
      at += head + len;
    }
    _in.clear();
    _in.add(buf.sublist(at));
  }

  // client frames: masked
  void send(Uint8List m) {
    final mask = List.generate(4, (_) => _rnd.nextInt(256));
    final head = m.length < 126 ? [0x82, 0x80 | m.length] : [0x82, 0x80 | 126, m.length >> 8, m.length & 0xff];
    _s.add([...head, ...mask, for (var i = 0; i < m.length; i++) m[i] ^ mask[i % 4]]);
  }

  Future<void> close() => _s.close();
}
