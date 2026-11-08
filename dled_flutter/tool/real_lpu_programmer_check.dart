// Check the v1.2 programmer messages on a real LPU and leave it as found:
//   dart run tool/real_lpu_programmer_check.dart [ip]
// Stops without writing when the programmer already holds data (someone is
// editing). Otherwise: entering edit (35 = 0), select the first patched
// fixture, intensity 50 % (attr 0) - that fixture lights for a moment -,
// CLEAR (2c 1d 38), selection and edit flag back as found; checks each on the
// LPU ("programmer has data" 2c 45) and that the show is byte-for-byte
// unchanged afterwards. (Programmer attribute reads are not used: the LPU
// answers them as attribute 17, FINDINGS 20.17.)

import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/core/show_file.dart';

var failures = 0;

void check(String what, bool ok, [Object? got]) {
  stdout.writeln('${ok ? 'OK  ' : 'FAIL'}  $what${ok || got == null ? '' : '  (got $got)'}');
  if (!ok) failures++;
}

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '192.168.1.12';
  final s = await LpuSession.connect(ip);
  final lpu = await LpuClient.connect(ip);
  final before = writeShow(s.show);
  final hasData = await lpu.readValue(objGlobal, 0x45);
  final mode = await lpu.readValue(objGlobal, 0x34);
  final sel = (await lpu.read(objGlobal, 0x3b)).body;
  stdout.writeln('programmer has data: $hasData, edit flag (35): $mode, selection: '
      '${sel.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
  if (hasData != 0) {
    stdout.writeln('The programmer holds data (someone is editing): nothing written.');
    await lpu.close();
    await s.close();
    exit(2);
  }

  await s.setEditing(true);
  check('entering edit: 35 = 0', await lpu.readValue(objGlobal, 0x34) == 0);
  final first = s.show.fixtures.first.index;
  await s.selectFixtures([first]);
  final m = (await lpu.read(objGlobal, 0x3b)).body;
  check('fixture ${first + 1} selected', m[first >> 3] == 1 << (first & 7), m);
  s.setProgrammer(0, tFloat, encFloat(0.5)); // fire and forget, like a slider
  var has = await lpu.readValue(objGlobal, 0x45);
  for (var i = 0; i < 50 && has == 0; i++) {
    await Future.delayed(const Duration(milliseconds: 40));
    has = await lpu.readValue(objGlobal, 0x45);
  }
  check('intensity 50 %: programmer has data', has != 0, has);
  await Future.delayed(const Duration(seconds: 1)); // visible on the rig

  await s.clearProgrammer();
  check('CLEAR: programmer empty', await lpu.readValue(objGlobal, 0x45) == 0);

  await s.selectFixtures([for (var i = 0; i < 64; i++) if (sel[i >> 3] & (1 << (i & 7)) != 0) i]);
  await s.setEditing(mode == 0);
  check('edit flag back to $mode', await lpu.readValue(objGlobal, 0x34) == mode);
  check('selection unchanged', _same((await lpu.read(objGlobal, 0x3b)).body, sel));
  final now = writeShow((await download(lpu)).show);
  check('show byte-for-byte unchanged', now == before);

  await lpu.close();
  await s.close();
  stdout.writeln(failures == 0 ? 'ALL CHECKS PASSED' : '$failures CHECK(S) FAILED');
  exit(failures == 0 ? 0 : 1);
}

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
