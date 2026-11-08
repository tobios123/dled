// lpu_client.dart -- VN client for the LPU-1. Its datagrams go through
// UdpPort (udp.dart): real UDP, or in a browser the WebSocket bridge.
//
// Writes are lock-step (the reference app does the same): each waits for the
// LPU's byte-for-byte echo before the next write, so their order holds.
// writeAll() is the exception for writes whose order does not matter (a show
// upload): up to [LpuClient.writeWindow] wait for their echo at once (one
// echo takes ~40 ms, a show upload is ~570 writes: 24 s one by one).
// Reads may overlap: up to [LpuClient.readWindow] are in flight at once,
// because one answer takes ~20 ms on Wi-Fi and a show download is ~700 reads
// (17 s one by one). The LPU drops answers when requests arrive back to back,
// so sends are paced [LpuClient.sendGap] apart (0.5 ms: no loss in 48 bursts
// of 32, FINDINGS 20.16). A read waits for the writes requested before it.
// Only read indexes the caller knows exist - open-ended reads past the end of
// the show have wedged the LPU firmware before.
// While open, a keepalive byte 0xff goes out every 25 ms.
//
// analysis/lpu/protocol.py LpuClient is the lock-step original.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'frame.dart';
import 'udp.dart';

class LpuError implements Exception {
  final String message;
  LpuError(this.message);
  @override
  String toString() => 'LpuError: $message';
}

class LpuClient {
  final HostAddress address;
  final int port;
  final Duration timeout;
  final int retries;

  /// Reads in flight at once, and the least time between two sends.
  static int readWindow = 16;
  static int writeWindow = 16;
  static Duration sendGap = const Duration(microseconds: 500);

  /// How long a read waits before it is sent again the first time (later
  /// attempts wait [timeout]); null = [timeout]. A read can safely be sent
  /// twice (the LPU just answers twice), so the light page, whose answers
  /// come through the ESP32 box and are now and then lost or late, asks
  /// again sooner (a lost answer cost 600 ms). Writes always wait [timeout]:
  /// some (adding a cue) must not happen twice.
  static Duration? readFirstTimeout;

  final UdpPort _socket;
  final List<_Pending> _pending = []; // requests waiting for their answer
  final Set<Future<void>> _inFlight = {};
  int _readsInFlight = 0;
  final Queue<Completer<void>> _readWaiters = Queue();
  final Stopwatch _clock = Stopwatch()..start();
  // long ago (not -1 << 30: in a browser << gives an unsigned 32-bit
  // number, +3.2e9, and the pacing loop then waited 53 minutes)
  int _lastSendUs = -1000000000;
  Timer? _keepalive;
  Future<void> _lock = Future.value(); // the writes, one after the other
  int _seq = 0x0100;
  bool _closed = false;

  /// Number of writes (typed and short) sent; lets read-only code prove it is.
  int writesSent = 0;

  /// When the LPU last sent anything (answer, echo or notification).
  DateTime lastHeard = DateTime.now();

  /// Requests made, and how many of them had to be sent again (no answer
  /// within [timeout]) - shows how lossy / slow the link to the LPU is.
  int exchanges = 0, resends = 0;

  /// Notifications (type | 0x80) and other unsolicited frames from the LPU.
  final StreamController<Frame> _notifications = StreamController.broadcast();
  Stream<Frame> get notifications => _notifications.stream;

  LpuClient._(this.address, this.port, this.timeout, this.retries, this._socket);

  static Future<LpuClient> connect(String ip,
      {int port = vnPort,
      Duration timeout = const Duration(milliseconds: 600),
      int retries = 4,
      bool keepalive = true,
      int localPort = 0}) async {
    final socket = await UdpPort.open(localPort);
    final c = LpuClient._(HostAddress(ip), port, timeout, retries, socket);
    socket.packets.listen(c._onPacket);
    if (keepalive) {
      c._keepalive = Timer.periodic(const Duration(milliseconds: 25),
          (_) => c._send(Uint8List.fromList([keepaliveByte])));
    }
    return c;
  }

  void _onPacket(UdpPacket dg) {
    // (packets arrive one event later; one may come after close())
    if (_closed || dg.ip != address.address) return;
    lastHeard = DateTime.now();
    final f = Frame.parse(dg.data);
    if (f != null && f.isNotification) _notifications.add(f);
    for (final p in _pending) {
      if (!p.done.isCompleted && p.match(dg.data)) {
        p.done.complete(dg.data);
        break;
      }
    }
  }

  /// Send a request, at least [sendGap] after the previous one. A busy wait:
  /// timers are far too coarse (1-15 ms) and the gap is tiny.
  void _sendPaced(Uint8List data) {
    final gap = sendGap.inMicroseconds;
    while (_clock.elapsedMicroseconds - _lastSendUs < gap) {}
    _lastSendUs = _clock.elapsedMicroseconds;
    _send(data);
  }

  void _send(Uint8List data) {
    if (_closed) return;
    // a lost send shows up as a timeout of the exchange that is waiting
    _socket.send(data, address.address, port);
  }

  int _nextSeq() {
    final s = _seq;
    _seq = (_seq + 1) & 0xffff;
    return s;
  }

  /// Writes one at a time: queue behind the previous write.
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then((_) {}, onError: (_) {});
    return _tracked(result);
  }

  Future<T> _tracked<T>(Future<T> f) {
    final done = f.then((_) {}, onError: (_) {});
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
    return f;
  }

  /// Send [frame] until an answer that [match]es arrives (or give up). An
  /// answer to an earlier attempt counts too.
  Future<Uint8List> _attempts(Uint8List frame, bool Function(Uint8List) match, String what,
      {Duration? first, Uint8List Function()? again}) async {
    if (_closed) throw LpuError('client closed');
    exchanges++;
    final p = _Pending(match);
    _pending.add(p);
    try {
      for (var attempt = 0; attempt < retries; attempt++) {
        if (_closed) throw LpuError('client closed');
        if (attempt > 0) {
          resends++;
          if (again != null) frame = again();
        }
        _sendPaced(frame);
        try {
          return await p.done.future.timeout(attempt == 0 ? first ?? timeout : timeout);
        } on TimeoutException {
          // send it again
        }
      }
      throw LpuError('no answer from LPU ${address.address} for $what');
    } finally {
      _pending.remove(p);
    }
  }

  Future<Uint8List> _write(Uint8List frame, String what) =>
      _locked(() => _attempts(frame, (d) => _same(d, frame), what));

  /// A read: after the writes requested before it, then in the read window.
  Future<Uint8List> _read(Uint8List frame, bool Function(Uint8List) match, String what,
          {Uint8List Function()? again}) =>
      _tracked(() async {
        await _lock;
        while (_readsInFlight >= readWindow) {
          if (_closed) throw LpuError('client closed');
          final w = Completer<void>();
          _readWaiters.add(w);
          await w.future;
        }
        _readsInFlight++;
        try {
          return await _attempts(frame, match, what, first: readFirstTimeout, again: again);
        } finally {
          _readsInFlight--;
          if (_readWaiters.isNotEmpty) _readWaiters.removeFirst().complete();
        }
      }());

  // --- typed frames -----------------------------------------------------------

  /// Read one property -> the reply frame (value type + body).
  Future<Frame> read(int op, int prop, {int i1 = 0, int i2 = 0, int i3 = 0}) async {
    Uint8List make() => Frame(op, tNoBody, prop, i1: i1, i2: i2, i3: i3, seq: _nextSeq()).encode();
    // a read sent again gets a new sequence number: the LPU takes a request
    // with the number it has just answered for a repeat and only confirms it
    // (an echo, no data), so when that one answer was lost (the ESP32 box
    // loses some of a burst) the read never got its data
    final d = await _read(make(), (d) {
      final p = Frame.parse(d);
      return p != null &&
          p.op == op &&
          p.prop == prop &&
          p.type != tNoBody &&
          !p.isNotification &&
          p.i1 == i1 &&
          p.i2 == i2 &&
          p.i3 == i3 &&
          p.mask == 0xffff;
    }, 'read ${_h(op)}/${_h(prop)} [$i1,$i2,$i3]', again: make);
    return Frame.parse(d)!;
  }

  Future<Object> readValue(int op, int prop, {int i1 = 0, int i2 = 0, int i3 = 0}) async =>
      (await read(op, prop, i1: i1, i2: i2, i3: i3)).value();

  /// Send one write (or a delete / action with type 0x1d) and wait for the echo.
  Future<void> write(int op, int type, int prop,
      {int i1 = 0, int i2 = 0, int i3 = 0, Uint8List? body}) async {
    final frame =
        Frame(op, type, prop, i1: i1, i2: i2, i3: i3, seq: _nextSeq(), body: body).encode();
    writesSent++;
    await _write(frame, 'write ${_h(op)} ${_h(type)} ${_h(prop)} [$i1,$i2,$i3]');
  }

  /// Send [writes] (different properties: their order does not matter) with
  /// up to [writeWindow] waiting for their echo at once, as one unit in the
  /// order of the writes. [onEach] after every echo; when [cancelled] turns
  /// true no further writes are sent (the ones in flight still finish).
  Future<void> writeAll(List<VnWrite> writes, {void Function()? onEach, bool Function()? cancelled}) =>
      _locked(() async {
        final frames = [
          for (final w in writes)
            Frame(w.op, w.type, w.prop, i1: w.i1, i2: w.i2, i3: w.i3, seq: _nextSeq(), body: w.body).encode()
        ];
        var next = 0;
        var failed = false;
        Future<void> worker() async {
          while (next < frames.length && !failed && !(cancelled?.call() ?? false)) {
            final f = frames[next++];
            writesSent++;
            try {
              await _attempts(f, (d) => _same(d, f), 'write ${next - 1} of ${frames.length}');
            } catch (_) {
              failed = true;
              rethrow;
            }
            onEach?.call();
          }
        }

        await Future.wait([for (var i = 0; i < writeWindow; i++) worker()]);
      });

  // --- short device properties ----------------------------------------------

  Future<Uint8List> shortRead(int prop) async {
    final d = await _read(shortReadFrame(prop), (d) => isShortReply(d, prop),
        'device property 0x${_h(prop)}');
    return shortValue(d);
  }

  /// Write a short device property (e.g. alias 0x12) and wait for the echo.
  Future<void> shortWrite(int prop, Uint8List value) async {
    final frame = shortWriteFrame(prop, value);
    writesSent++;
    await _write(frame, 'device property write 0x${_h(prop)}');
  }

  /// Close; requests still waiting for an answer fail at once (LpuError).
  Future<void> close() async {
    _keepalive?.cancel();
    _closed = true;
    for (final p in _pending) {
      if (!p.done.isCompleted) p.done.completeError(LpuError('client closed'));
    }
    while (_readWaiters.isNotEmpty) {
      _readWaiters.removeFirst().complete();
    }
    await Future.wait(_inFlight.toList());
    _socket.close();
    await _notifications.close();
  }
}

/// One write for [LpuClient.writeAll].
typedef VnWrite = ({int op, int type, int prop, int i1, int i2, int i3, Uint8List? body});

class _Pending {
  final bool Function(Uint8List) match;
  final Completer<Uint8List> done = Completer();
  _Pending(this.match);
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _h(int b) => b.toRadixString(16).padLeft(2, '0');

/// Broadcast "visual_identify" and collect the XML replies for [timeout].
/// Returns ip -> (label, firmware).
Future<Map<String, ({String label, String firmware})>> discover(
    {Duration timeout = const Duration(seconds: 4), int port = vnPort}) async {
  final socket = await UdpPort.open();
  final found = <String, ({String label, String firmware})>{};
  final sub = socket.packets.listen((dg) {
    if (dg.data.isEmpty || dg.data[0] != 0x3c) return; // '<'
    final xml = String.fromCharCodes(dg.data.where((b) => b != 0));
    String? tag(String t) => RegExp('<$t>([^<]*)</$t>').firstMatch(xml)?.group(1)?.trim();
    final label = RegExp(r'label="([^"]*)"').firstMatch(xml)?.group(1) ?? '?';
    found[tag('ip') ?? dg.ip] = (label: label, firmware: tag('version') ?? '?');
  });
  final ping = Uint8List.fromList('visual_identify'.codeUnits);
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    socket.send(ping, '255.255.255.255', port);
    await Future.delayed(const Duration(seconds: 1));
  }
  await sub.cancel();
  socket.close();
  return found;
}
