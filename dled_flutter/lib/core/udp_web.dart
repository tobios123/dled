// udp_web.dart -- UdpPort in a browser: the datagrams go over one WebSocket
// to the bridge (bin/dled_bridge.dart), which sends them as real UDP.
//
// Every WebSocket message is one datagram:
//   [channel u8] [IPv4 4 bytes] [port u16 big-endian] [datagram]
// browser -> bridge: send the datagram to that address from the channel's
// UDP socket (the bridge opens one per channel); bridge -> browser: a
// datagram that arrived at that channel's socket, from that address. A
// message with address 0.0.0.0:0 and no datagram closes the channel.
// Channels are 1-255: a bridge -> browser message starting with 0 holds
// several datagrams, each as [length u16 big-endian] [datagram message]
// (the ESP32 box sends a burst of answers that way).
// The bridge is the page's own host (/vn), unless ?bridge=host:port is given.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'udp.dart';

Future<UdpPort> openUdpPort([int localPort = 0]) async => _WebPort(_Bridge.instance, _Bridge.instance._nextChannel());

Future<List<String>> localIps() async => const [];

class _Bridge {
  static final _Bridge instance = _Bridge._();
  _Bridge._();

  web.WebSocket? _ws;
  bool _open = false;
  final List<Uint8List> _queue = []; // sent before the WebSocket was open
  final Map<int, _WebPort> _ports = {};
  int _channel = 0;

  int _nextChannel() {
    for (var i = 0; i < 255; i++) {
      _channel = _channel % 255 + 1;
      if (!_ports.containsKey(_channel)) return _channel;
    }
    return _channel;
  }

  String get _url {
    final base = Uri.base;
    final given = base.queryParameters['bridge'];
    final host = given ?? (base.hasPort ? '${base.host}:${base.port}' : base.host);
    return 'ws://$host/vn';
  }

  void _connect() {
    if (_ws != null) return;
    final ws = web.WebSocket(_url)..binaryType = 'arraybuffer';
    _ws = ws;
    ws.onopen = ((web.Event _) {
      _open = true;
      for (final m in _queue) {
        ws.send(m.toJS);
      }
      _queue.clear();
    }).toJS;
    ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data == null || !data.isA<JSArrayBuffer>()) return;
      final b = (data as JSArrayBuffer).toDart.asUint8List();
      if (b.isEmpty) return;
      if (b[0] != 0) return _datagram(b);
      // several datagrams (the ESP32 box): [0] then [length u16] [datagram as above] ...
      for (var at = 1; at + 2 <= b.length;) {
        final n = b[at] << 8 | b[at + 1];
        if (at + 2 + n > b.length) break;
        _datagram(Uint8List.sublistView(b, at + 2, at + 2 + n));
        at += 2 + n;
      }
    }).toJS;
    void lost() {
      _open = false;
      _ws = null;
      // Try again in a moment while ports are in use (the LPU code's
      // retries and watchdog cover the gap).
      if (_ports.isNotEmpty) Timer(const Duration(seconds: 1), _connect);
    }

    ws.onclose = ((web.Event _) => lost()).toJS;
  }

  void _datagram(Uint8List b) {
    if (b.length < 7) return;
    _ports[b[0]]?._received((
      data: Uint8List.sublistView(b, 7),
      ip: '${b[1]}.${b[2]}.${b[3]}.${b[4]}',
      port: b[5] << 8 | b[6],
    ));
  }

  void _send(int channel, String ip, int port, Uint8List data) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return;
    final m = Uint8List(7 + data.length)
      ..[0] = channel
      ..setRange(1, 5, parts.cast<int>())
      ..[5] = port >> 8
      ..[6] = port & 0xff
      ..setRange(7, 7 + data.length, data);
    _connect();
    if (_open) {
      _ws!.send(m.toJS);
    } else {
      _queue.add(m);
    }
  }
}

class _WebPort implements UdpPort {
  final _Bridge _bridge;
  final int _channel;
  final _packets = StreamController<UdpPacket>.broadcast();

  _WebPort(this._bridge, this._channel) {
    _bridge._ports[_channel] = this;
    _bridge._connect();
  }

  void _received(UdpPacket p) => _packets.add(p);

  @override
  void send(Uint8List data, String ip, int port) => _bridge._send(_channel, ip, port, data);

  @override
  Stream<UdpPacket> get packets => _packets.stream;

  @override
  void close() {
    _bridge._send(_channel, '0.0.0.0', 0, Uint8List(0));
    _bridge._ports.remove(_channel);
    _packets.close();
  }
}
