// Put the LPU back in a clean state after an LPD test:
//   dart run tool/lpd_reset.dart [ip]
// CLEARs the programmer (with EDIT open), closes EDIT, RELEASE ALL, and
// prints every playback that is not released.

import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';

Future<void> main(List<String> args) async {
  final c = await LpuClient.connect(args.isNotEmpty ? args[0] : '192.168.1.12');
  await c.write(objGlobal, tBool, 0x35, body: encBool(false)); // EDIT open: CLEAR works only then
  await c.write(objGlobal, tNoBody, 0x38); // CLEAR programmer
  await c.write(objGlobal, tBool, 0x35, body: encBool(true)); // EDIT closed
  await releaseAll(c);
  await Future.delayed(const Duration(seconds: 1));
  const phase = {0: 'no cues', 1: 'released', 2: 'running', 3: 'holding', 4: 'RELEASING'};
  for (var p = 0; p < slots; p++) {
    final s = playbackState((await c.read(objPlayback, 0x30, i1: p)).body);
    if (s.state > 1) stdout.writeln('pb ${p + 1}: ${phase[s.state]}');
  }
  await c.close();
  exit(0);
}
