// dled_bridge.dart -- run DLED in a browser: serve the web build and pass
// its LPU traffic on as UDP (a browser cannot send UDP itself).
//
//   dart run bin/dled_bridge.dart [--web build/web] [--port 8080]
//   dart run bin/dled_bridge.dart --web light/dist     (the light page)
//
// Open http://<this PC>:8080 on a phone, tablet or laptop in the same
// network. The page talks to /vn over a WebSocket; every message is one
// datagram (lib/core/udp_web.dart):
//   [channel u8] [IPv4 4 bytes] [port u16 big-endian] [datagram]
// For each channel the bridge opens one UDP socket (broadcast on) and sends
// the datagram to that address; what arrives at the socket goes back with
// the sender's address. 0.0.0.0:0 without a datagram closes the channel.
// Sends are paced 0.5 ms apart per socket, as the LPU drops answers to
// requests that arrive back to back (FINDINGS 20.16). A broadcast to
// 255.255.255.255 also goes to the /24 broadcast of every network of this PC
// (some networks only pass those). Later the same job moves into an ESP32.
//
// Show files (the light page's OPTIONS), stored in --shows (default
// Documents/DLED/shows, the folder the Windows app uses), as NAME.show:
//   GET    /api/shows            [{"name","size","modified"(ms)}], sorted by name
//   GET    /api/shows/NAME       the .show text
//   PUT    /api/shows/NAME       save the body as NAME.show
//   DELETE /api/shows/NAME
//   POST   /api/shows/NAME?to=NEW   rename
// NAME.positions is the show's stored positions (NAME.positions.json, as the
// Windows app keeps them); it is not listed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _types = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'json': 'application/json',
  'wasm': 'application/wasm',
  'css': 'text/css',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'xml': 'text/xml',
  'txt': 'text/plain',
};

Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final webDir = Directory(opt('web', 'build/web'));
  final port = int.parse(opt('port', '8080'));
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  _shows = Directory(opt('shows', '$home/Documents/DLED/shows'))..createSync(recursive: true);
  _verbose = args.contains('--log');
  if (!File('${webDir.path}/index.html').existsSync() && !File('${webDir.path}/index.html.gz').existsSync()) {
    stderr.writeln('No web build in ${webDir.path} - run: flutter build web --release --no-web-resources-cdn');
    exit(1);
  }
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  final ips = await _localIps();
  stdout.writeln('DLED bridge: open one of these in a browser in the same network:');
  for (final ip in ips) {
    stdout.writeln('  http://$ip:$port');
  }
  stdout.writeln('(Ctrl+C to stop)');

  await for (final request in server) {
    if (request.uri.path == '/vn' && WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      _Relay(ws, request.connectionInfo?.remoteAddress.address ?? '?', ips);
    } else if (request.uri.path == '/api/shows' || request.uri.path.startsWith('/api/shows/')) {
      unawaited(_showsApi(request));
    } else {
      unawaited(_serveFile(request, webDir));
    }
  }
}

bool _verbose = false; // --log: every datagram, both ways
late Directory _shows;

/// A show name as a file name: no path or reserved characters.
String? _showFile(String name) {
  if (name.isEmpty || name.length > 64 || RegExp(r'[\\/:*?"<>|]').hasMatch(name) || name.startsWith('.')) return null;
  // a show's stored positions (NAME.positions, light page): the file the
  // Windows app keeps next to the show (models/position_store.dart)
  if (name.endsWith('.positions')) return '${_shows.path}/$name.json';
  return '${_shows.path}/$name.show';
}

Future<void> _showsApi(HttpRequest req) async {
  final res = req.response;
  Future<void> done(int status, [String body = '']) async {
    res.statusCode = status;
    res.write(body);
    await res.close();
  }

  try {
    if (req.uri.path == '/api/shows') {
      final list = [
        for (final f in _shows.listSync().whereType<File>().where((f) => f.path.endsWith('.show')))
          {
            'name': f.uri.pathSegments.last.replaceAll(RegExp(r'\.show$'), ''),
            'size': f.lengthSync(),
            'modified': f.lastModifiedSync().millisecondsSinceEpoch,
          }
      ]..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
      res.headers.contentType = ContentType.json;
      return await done(200, jsonEncode(list));
    }
    final path = _showFile(Uri.decodeComponent(req.uri.pathSegments.last));
    if (path == null) return await done(400, 'bad name');
    final file = File(path);
    switch (req.method) {
      case 'GET':
        if (!file.existsSync()) return await done(404);
        res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
        return await done(200, await file.readAsString());
      case 'PUT':
        await file.writeAsBytes(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
        return await done(200);
      case 'DELETE':
        if (file.existsSync()) file.deleteSync();
        return await done(200);
      case 'POST':
        final to = _showFile(req.uri.queryParameters['to'] ?? '');
        if (to == null || !file.existsSync()) return await done(400);
        file.renameSync(to);
        return await done(200);
    }
    return await done(405);
  } catch (e) {
    return await done(500, '$e');
  }
}

Future<List<String>> _localIps() async => [
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false))
        for (final a in i.addresses) a.address
    ];

Future<void> _serveFile(HttpRequest request, Directory root) async {
  final res = request.response;
  var path = Uri.decodeComponent(request.uri.path);
  if (path.endsWith('/')) path += 'index.html';
  var file = File('${root.path}$path');
  // inside the web build only
  if (path.contains('..')) {
    res.statusCode = HttpStatus.notFound;
    await res.close();
    return;
  }
  // A gzipped copy (the light page has only those, like the ESP32): sent as
  // is, the browser unpacks it.
  if (!await file.exists()) {
    file = File('${file.path}.gz');
    if (!await file.exists()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
  }
  final ext = path.split('.').last.toLowerCase();
  res.headers.contentType = ContentType.parse(_types[ext] ?? 'application/octet-stream');
  // Always checked again: Flutter's file names stay the same between builds,
  // so a cached main.dart.js would keep running an old build.
  res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  await res.addStream(file.openRead());
  await res.close();
}

/// One browser page: its channels and their UDP sockets.
class _Relay {
  final WebSocket ws;
  final String who;
  final List<String> ownIps;
  final Map<int, RawDatagramSocket> _sockets = {};
  final Map<int, int> _lastSendUs = {};
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _work = Future.value(); // the page's messages, in order

  _Relay(this.ws, this.who, this.ownIps) {
    stdout.writeln('${_time()} page connected from $who');
    ws.listen((m) {
      if (m is List<int>) {
        final data = Uint8List.fromList(m);
        _work = _work.then((_) => _fromPage(data)).catchError((_) {});
      }
    }, onDone: _close, onError: (_) => _close());
  }

  String _time() => DateTime.now().toIso8601String().substring(11, 23);
  String _hex(List<int> d) =>
      d.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') + (d.length > 16 ? ' ...' : '');

  Future<void> _fromPage(Uint8List m) async {
    if (m.length < 7) return;
    final channel = m[0];
    final ip = '${m[1]}.${m[2]}.${m[3]}.${m[4]}';
    final port = m[5] << 8 | m[6];
    final data = Uint8List.sublistView(m, 7);
    if (ip == '0.0.0.0' && port == 0 && data.isEmpty) {
      _sockets.remove(channel)?.close();
      return;
    }
    final socket = _sockets[channel] ?? await _open(channel);
    if (_verbose) stdout.writeln('${_time()} ch$channel -> $ip:$port ${_hex(data)}');
    final targets = [
      ip,
      if (ip == '255.255.255.255')
        for (final own in ownIps) '${own.substring(0, own.lastIndexOf('.'))}.255',
    ];
    for (final t in targets) {
      // at least 0.5 ms between two sends of a socket (busy wait: timers are
      // far coarser)
      while (_clock.elapsedMicroseconds - (_lastSendUs[channel] ?? -1000) < 500) {}
      _lastSendUs[channel] = _clock.elapsedMicroseconds;
      try {
        socket.send(data, InternetAddress(t), port);
      } on SocketException {
        // lost; the page retries
      }
    }
  }

  Future<RawDatagramSocket> _open(int channel) async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
      ..broadcastEnabled = true;
    _sockets[channel] = s;
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg == null) return;
      if (_verbose) stdout.writeln('${_time()} ch$channel <- ${dg.address.address}:${dg.port} ${_hex(dg.data)}');
      final a = dg.address.rawAddress;
      final out = Uint8List(7 + dg.data.length)
        ..[0] = channel
        ..setRange(1, 5, a)
        ..[5] = dg.port >> 8
        ..[6] = dg.port & 0xff
        ..setRange(7, 7 + dg.data.length, dg.data);
      ws.add(out);
    });
    return s;
  }

  void _close() {
    for (final s in _sockets.values) {
      s.close();
    }
    _sockets.clear();
    stdout.writeln('${_time()} page from $who left');
  }
}
