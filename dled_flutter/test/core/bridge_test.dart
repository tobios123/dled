// The browser bridge (bin/dled_bridge.dart): a datagram sent over its
// WebSocket in the udp_web.dart format reaches the LPU (emulator) as UDP,
// and the answer comes back on the same channel with the LPU's address.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/frame.dart';

import 'emulator.dart';

void main() {
  test('a read goes through the bridge and its answer comes back', () async {
    final lpuPort = 37000 + pid % 1000;
    final emu = await Emulator.start(lpuPort, show: 'test/core_data/shows/m400.show');
    if (emu == null) return markTestSkipped('python / emulator not available');
    addTearDown(emu.stop);

    // the bridge needs a web build to serve; a stand-in index.html will do
    final web = await Directory.systemTemp.createTemp('dled_web');
    addTearDown(() => web.delete(recursive: true));
    File('${web.path}/index.html').writeAsStringSync('<html></html>');
    final httpPort = 38500 + pid % 1000;
    final dart = '${File(Platform.resolvedExecutable).parent.path}/dart${Platform.isWindows ? '.exe' : ''}';
    // dart.exe itself, not through a shell: kill() of a shell leaves the
    // bridge running (18 were left over on 2026-10-28, all polling the LPUs
    // on the network, which the LPD-1 board could not keep up with)
    final direct = File(dart).existsSync();
    final bridge = await Process.start(
        direct ? dart : 'dart', ['run', 'bin/dled_bridge.dart', '--web', web.path, '--port', '$httpPort'],
        runInShell: !direct);
    addTearDown(() async {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '${bridge.pid}']); // with its Dart VM child
      } else {
        bridge.kill();
      }
    });
    final ready = Completer<void>();
    bridge.stdout.transform(const SystemEncoding().decoder).listen((s) {
      if (s.contains('http://') && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 60));

    final ws = await WebSocket.connect('ws://127.0.0.1:$httpPort/vn');
    addTearDown(ws.close);
    final answer = Completer<Uint8List>();
    ws.listen((m) {
      if (m is List<int> && !answer.isCompleted) answer.complete(Uint8List.fromList(m));
    });

    // playback 1's state (29 1d 30), to 127.0.0.1:<lpuPort>, channel 7
    final read = Frame(objPlayback, tNoBody, 0x30, seq: 0x0101).encode();
    ws.add(Uint8List.fromList([7, 127, 0, 0, 1, lpuPort >> 8, lpuPort & 0xff, ...read]));

    final m = await answer.future.timeout(const Duration(seconds: 5));
    expect(m[0], 7); // same channel
    expect(m.sublist(1, 5), [127, 0, 0, 1]); // from the LPU
    expect(m[5] << 8 | m[6], lpuPort);
    final f = Frame.parse(Uint8List.sublistView(m, 7))!;
    expect([f.op, f.prop], [objPlayback, 0x30]); // the state reply
  }, timeout: const Timeout(Duration(minutes: 2)));
}
