// udp_io.dart -- UdpPort on a real UDP socket (Windows, Android, tests).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'udp.dart';

Future<UdpPort> openUdpPort([int localPort = 0]) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
  // Broadcast must be switched on, else Windows refuses the discovery sends
  // ("access denied").
  socket.broadcastEnabled = true;
  return _IoPort(socket);
}

Future<List<String>> localIps() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  return [for (final i in interfaces) for (final a in i.addresses) a.address];
}

class _IoPort implements UdpPort {
  final RawDatagramSocket _socket;
  final _packets = StreamController<UdpPacket>.broadcast();

  _IoPort(this._socket) {
    _socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = _socket.receive();
      if (dg != null) _packets.add((data: dg.data, ip: dg.address.address, port: dg.port));
    }, onDone: () => _packets.close());
  }

  @override
  void send(Uint8List data, String ip, int port) {
    try {
      _socket.send(data, InternetAddress(ip), port);
    } on SocketException {
      // lost; the caller retries
    }
  }

  @override
  Stream<UdpPacket> get packets => _packets.stream;

  @override
  void close() => _socket.close();
}
