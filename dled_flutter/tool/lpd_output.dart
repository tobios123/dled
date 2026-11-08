// Turn the LPU's Art-Net / sACN output on or off:
//   dart run tool/lpd_output.dart [ip] [artnet=on|off] [sacn=on|off] [artnet-universe=N] [sacn-universe=N]
// Without settings it only prints the current ones.

import 'dart:io';

import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/show_file.dart';

Future<void> main(List<String> args) async {
  var ip = '192.168.1.12';
  bool? artNet, sacn;
  int? artUni, sacnUni;
  for (final a in args) {
    final kv = a.split('=');
    if (kv.length == 1) {
      ip = a;
    } else if (kv[0] == 'artnet') {
      artNet = kv[1] == 'on';
    } else if (kv[0] == 'sacn') {
      sacn = kv[1] == 'on';
    } else if (kv[0] == 'artnet-universe') {
      artUni = int.parse(kv[1]);
    } else if (kv[0] == 'sacn-universe') {
      sacnUni = int.parse(kv[1]);
    } else {
      stderr.writeln('unknown: $a');
      exit(2);
    }
  }
  final c = await LpuClient.connect(ip);
  String show(LpuInfo i) => 'Art-Net ${i.artNetEnabled ? 'on' : 'off'} (raw universe ${i.artNetUniverseRaw}), '
      'sACN ${i.sacnEnabled ? 'on' : 'off'} (universe ${i.sacnUniverse})';
  stdout.writeln('$ip: ${show(await readDevice(c, Show()))}');
  if (artNet != null || artUni != null) await setArtNet(c, enabled: artNet, universe: artUni);
  if (sacn != null || sacnUni != null) await setSacn(c, enabled: sacn, universe: sacnUni);
  if (artNet != null || artUni != null || sacn != null || sacnUni != null) {
    stdout.writeln('now: ${show(await readDevice(c, Show()))}');
  }
  await c.close();
}
