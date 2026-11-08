// Check the v0.8 device-settings writes on a real LPU and put everything back:
//   dart run tool/real_lpu_device_check.dart <ip> [port]
// Flips Art-Net and sACN on/off and changes the alias through the app's
// session (LpuSession.writeDeviceSettings), checks the DeviceUpdated read-back
// and a second client's read, then restores the original values.
// Exit code 0 = every check passed and the original settings are back.

import 'dart:async';
import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/lpu_session.dart';
import 'package:dled/core/show_file.dart';

var failures = 0;

void check(String what, bool ok, [Object? got]) {
  stdout.writeln('${ok ? 'OK  ' : 'FAIL'}  $what${ok || got == null ? '' : '  (got $got)'}');
  if (!ok) failures++;
}

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '192.168.1.12';
  final port = args.length > 1 ? int.parse(args[1]) : vnPort;
  stdout.writeln('connecting to $ip:$port (download takes a while) ...');
  final s = await LpuSession.connect(ip, port: port);
  final lpu = await LpuClient.connect(ip, port: port);
  final orig = await readDevice(lpu, Show());
  stdout.writeln('now: alias "${orig.alias}", Art-Net ${orig.artNetEnabled}, sACN ${orig.sacnEnabled}');

  final updates = <LpuInfo>[];
  final sub = s.events.listen((e) {
    if (e is DeviceUpdated) updates.add(e.info);
  });

  final alias = orig.alias == 'DLED CHECK' ? 'DLED CHECK 2' : 'DLED CHECK';
  await s.writeDeviceSettings(alias: alias, artNet: !orig.artNetEnabled, sacn: !orig.sacnEnabled);
  final now = await readDevice(lpu, Show());
  check('alias changed', now.alias == alias, now.alias);
  check('Art-Net flipped', now.artNetEnabled == !orig.artNetEnabled, now.artNetEnabled);
  check('sACN flipped', now.sacnEnabled == !orig.sacnEnabled, now.sacnEnabled);
  check('session reported DeviceUpdated with the new values',
      updates.isNotEmpty && updates.last.alias == alias && updates.last.artNetEnabled == !orig.artNetEnabled,
      updates.map((u) => u.alias).toList());

  stdout.writeln('restoring ...');
  await s.writeDeviceSettings(alias: orig.alias, artNet: orig.artNetEnabled, sacn: orig.sacnEnabled);
  final back = await readDevice(lpu, Show());
  check('restored: alias "${orig.alias}", Art-Net ${orig.artNetEnabled}, sACN ${orig.sacnEnabled}',
      back.alias == orig.alias && back.artNetEnabled == orig.artNetEnabled && back.sacnEnabled == orig.sacnEnabled,
      '"${back.alias}" ${back.artNetEnabled} ${back.sacnEnabled}');
  check('Art-Net universe untouched', back.artNetUniverseRaw == orig.artNetUniverseRaw, back.artNetUniverseRaw);

  await sub.cancel();
  await lpu.close();
  await s.close();
  stdout.writeln(failures == 0 ? 'ALL CHECKS PASSED' : '$failures CHECK(S) FAILED');
  exit(failures == 0 ? 0 : 1);
}
