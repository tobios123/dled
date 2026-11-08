// dmx_capture.dart -- receive the LPU's DMX output (Art-Net / sACN) and
// record it.
//
// The LPU sends all 512 channels 40 times a second on both: Art-Net ArtDmx to
// UDP 6454 (universe 16 on the wire by default) and sACN / E1.31 to the
// multicast group 239.255.0.U, port 5568. One source is recorded.
//
// Recording (JSONL, one object per line, t = ms since the start):
//   {"t":0,"src":"artnet","uni":16,"full":[...512 values]}   the first frame
//   {"t":25.1,"d":{"20":128,"21":0}}                         channels that changed (1-based)
//   {"t":30.0,"mark":"go pb1"}                               a step of the test
//   {"t":1000.2,"beat":40}                                   frames received in the last second
// Unchanged frames are counted, not written.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum DmxSource { artnet, sacn }

class DmxCapture {
  final DmxSource source;
  final String lpuIp;
  final List<RawDatagramSocket> _sockets = [];
  final Stopwatch clock = Stopwatch();
  IOSink? _out;

  /// The latest frame (channel 1 = index 0); all zero before the first.
  final Uint8List dmx = Uint8List(512);
  int frames = 0, _beatFrames = 0;
  int? universe;
  bool _first = true;
  Timer? _beat;
  final _changes = StreamController<Map<int, int>>.broadcast();
  final _firstFrame = Completer<void>();

  /// Channels (1-based) that changed in a frame, with their new values.
  Stream<Map<int, int>> get changes => _changes.stream;

  /// Completes when the first frame came in.
  Future<void> get started => _firstFrame.future;

  DmxCapture(this.lpuIp, {this.source = DmxSource.artnet});

  /// Listen; with [record] every frame that changes goes to that file.
  Future<void> start({File? record, int sacnUniverse = 1}) async {
    clock.start();
    if (record != null) {
      record.parent.createSync(recursive: true);
      _out = record.openWrite();
    }
    if (source == DmxSource.artnet) {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 6454, reuseAddress: true);
      s.broadcastEnabled = true;
      _sockets.add(s);
      s.listen((e) => _read(s, e, _artnet));
    } else {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5568, reuseAddress: true);
      // join on the interface that is on the LPU's network (Wi-Fi and
      // Ethernet both present: the default interface may be the wrong one)
      s.joinMulticast(InternetAddress('239.255.${sacnUniverse >> 8}.${sacnUniverse & 0xff}'), await _iface());
      _sockets.add(s);
      s.listen((e) => _read(s, e, _sacn));
    }
    _beat = Timer.periodic(const Duration(seconds: 1), (_) {
      _write({'t': _now(), 'beat': _beatFrames});
      _beatFrames = 0;
    });
  }

  Future<NetworkInterface?> _iface() async {
    final net = lpuIp.substring(0, lpuIp.lastIndexOf('.') + 1);
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (i.addresses.any((a) => a.address.startsWith(net))) return i;
    }
    return null;
  }

  double _now() => (clock.elapsedMicroseconds / 100).round() / 10;

  void _read(RawDatagramSocket s, RawSocketEvent e, void Function(Uint8List) parse) {
    if (e != RawSocketEvent.read) return;
    Datagram? dg;
    while ((dg = s.receive()) != null) {
      if (dg!.address.address == lpuIp) parse(dg.data);
    }
  }

  void _artnet(Uint8List p) {
    if (p.length < 18 || ascii.decode(p.sublist(0, 7), allowInvalid: true) != 'Art-Net') return;
    if ((p[8] | p[9] << 8) != 0x5000) return; // ArtDmx only
    if (!_fresh(p[12])) return;
    final len = p[16] << 8 | p[17];
    _frame(p[14] | p[15] << 8, Uint8List.sublistView(p, 18, 18 + len));
  }

  void _sacn(Uint8List p) {
    if (p.length < 126 || p[125] != 0) return; // start code 0 = DMX
    if (!_fresh(p[111])) return;
    _frame(p[113] << 8 | p[114], Uint8List.sublistView(p, 126));
  }

  int? _lastSeq;
  int _lastSeqAt = 0;
  final _seqClock = Stopwatch()..start();

  /// A frame newer than the last one by its sequence number (0 = the sender
  /// does not count). With Wi-Fi and Ethernet on the same network every
  /// broadcast arrives twice, the Wi-Fi copy later: without this the late
  /// copies land between newer frames (seen 2026-10-28).
  /// After 0.5 s without a frame any number counts (the sender restarted).
  bool _fresh(int seq) {
    if (seq == 0) return true;
    final last = _lastSeq, now = _seqClock.elapsedMilliseconds;
    final ahead = last == null || now - _lastSeqAt > 500 ? 1 : (seq - last) & 0xff;
    if (ahead == 0 || ahead >= 128) return false;
    _lastSeq = seq;
    _lastSeqAt = now;
    return true;
  }

  void _frame(int uni, Uint8List data) {
    universe ??= uni;
    if (uni != universe) return;
    frames++;
    _beatFrames++;
    final t = _now();
    if (_first) {
      _first = false;
      dmx.setRange(0, data.length, data);
      _write({'t': t, 'src': source.name, 'uni': uni, 'full': data.toList()});
      _changes.add({for (var i = 0; i < data.length; i++) i + 1: data[i]});
      _firstFrame.complete();
      return;
    }
    final d = <int, int>{};
    for (var i = 0; i < data.length && i < 512; i++) {
      if (dmx[i] != data[i]) {
        dmx[i] = data[i];
        d[i + 1] = data[i];
      }
    }
    if (d.isNotEmpty) {
      _write({'t': t, 'd': d.map((k, v) => MapEntry('$k', v))});
      _changes.add(d);
    }
  }

  /// A notification from the device, at this moment.
  void note(String what) => _write({'t': _now(), 'note': what});

  /// A step of the test, at this moment.
  void mark(String what, [Map<String, Object?> extra = const {}]) =>
      _write({'t': _now(), 'mark': what, ...extra});

  void _write(Map<String, Object?> o) => _out?.writeln(jsonEncode(o));

  Future<void> stop() async {
    _beat?.cancel();
    for (final s in _sockets) {
      s.close();
    }
    await _changes.close();
    await _out?.flush();
    await _out?.close();
  }
}
