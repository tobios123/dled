// udp.dart -- the one network door of the LPU code, on every platform.
//
// Windows / Android: a real UDP socket (udp_io.dart). In a browser there is
// no UDP, so the same datagrams travel over a WebSocket to the bridge
// (bin/dled_bridge.dart, later an ESP32), which sends them as UDP and sends
// the answers back (udp_web.dart). The LPU code above (lpu_client.dart,
// vn_service.dart) does not know which one it uses.

import 'dart:typed_data';

import 'udp_io.dart' if (dart.library.js_interop) 'udp_web.dart' as impl;

/// A received datagram and where it came from.
typedef UdpPacket = ({Uint8List data, String ip, int port});

/// An IPv4 address as text ("192.168.1.12"), like dart:io's InternetAddress
/// shows it (`.address`).
class HostAddress {
  final String address;
  const HostAddress(this.address);
  @override
  String toString() => address;
}

abstract class UdpPort {
  /// Send [data] to [ip]:[port] (broadcast allowed). Never throws: a refused
  /// send is a lost datagram, which the callers already retry.
  void send(Uint8List data, String ip, int port);

  /// Every datagram that arrives at this port.
  Stream<UdpPacket> get packets;

  void close();

  /// A new port on [localPort] (0: a free one), broadcast enabled. (In a
  /// browser the bridge picks the port.)
  static Future<UdpPort> open([int localPort = 0]) => impl.openUdpPort(localPort);

  /// This device's own IPv4 addresses (empty in a browser: the bridge
  /// sends broadcasts to its own networks).
  static Future<List<String>> localIps() => impl.localIps();
}
