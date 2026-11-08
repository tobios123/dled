// Check the v1.1 automatic connecting on the real network, like the app does
// it (VnService: real discovery broadcast, no LPU remembered):
//   dart run tool/real_lpu_autoconnect_check.dart [seconds]
// 1. start -> discovery finds the LPU(s); with exactly one it connects by itself
// 2. stays connected while nobody does anything for [seconds] (default 60):
//    the watchdog must not report a healthy LPU as lost
// 3. during that time you may pull the LPU's network cable or power and put
//    it back: every loss and reconnect is printed with the time.
// Read-only: nothing is written to the LPU.

import 'dart:io';

import 'package:dled/core/lpu_live.dart';
import 'package:dled/services/vn_service.dart';

Future<void> main(List<String> args) async {
  final seconds = args.isNotEmpty ? int.parse(args[0]) : 60;
  final t0 = DateTime.now();
  String t() => '${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)} s'.padLeft(7);
  var losses = 0, connects = 0;

  final vn = VnService();
  vn.onDevicesChanged = (d) => stdout.writeln('${t()}  discovery: ${d.map((x) => x.ip).join(', ')}');
  vn.onConnectionChanged = (d) {
    if (d != null) connects++;
    stdout.writeln('${t()}  ${d == null ? 'offline' : 'CONNECTED to ${d.ip}'}');
  };
  vn.onAutoConnectEnded = () => stdout.writeln('${t()}  automatic connecting gave up (window over)');
  vn.onLiveEvent = (e) {
    if (e is ConnectionLost) {
      losses++;
      stdout.writeln('${t()}  CONNECTION LOST: ${e.reason} -> trying to reconnect');
    } else if (e is ShowDownloaded) {
      stdout.writeln('${t()}  show downloaded: ${e.show.playbacks.length} playbacks');
    }
  };
  await vn.start();
  stdout.writeln('${t()}  started; watching for $seconds s (pull the cable / power now if you want)');
  await Future.delayed(Duration(seconds: seconds));
  final ok = vn.isConnected;
  stdout.writeln('${t()}  end: ${ok ? 'connected to ${vn.connected!.ip}' : 'NOT connected'}, '
      '$connects connect(s), $losses loss(es)');
  vn.stop();
  exit(ok ? 0 : 1);
}
