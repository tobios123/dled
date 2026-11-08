// dled_cli.dart -- command line for the LPU-1, on the same core as the app.
//
//   dart run bin/dled_cli.dart <command> [options]
//
// Commands (playback numbers are 1-64 like the UI):
//   discover [--timeout S]                 find LPUs (visual_identify broadcast)
//   info     --ip IP                       device settings and a show summary
//   download --ip IP --show FILE           whole show to a .show file
//   upload   FILE --ip IP [--yes] [--backup FILE] [--no-verify]
//                                          dry run unless --yes; then backup,
//                                          upload, read back and compare
//   go N | flash N [--hold MS] | release N | release-all     --ip IP
//   playback N --ip IP [--gomode Go|Toggle|Flash|Solo] [--repeat Loop|Bounce|Random|Off]
//                    [--background on|off] [--exclusive on|off] [--label TEXT]
//                    [--intensity 0-1] [--speed S]   playback properties window
//   set      --ip IP [--alias NAME] [--artnet on|off] [--artnet-universe 0-15]
//                    [--sacn on|off] [--sacn-universe N]
//   status   --ip IP                       playback states (read-only; flags stuck ones)
//   monitor  --ip IP [--seconds S]         print the LPU's change notifications
//   show     FILE                          summary of a .show file (offline)
// Common: --port P (default 16945, e.g. 26945 for the emulator). Without
// --ip the CLI finds the LPU by discovery (fails with a list if several answer).
// Exit codes: 0 ok, 1 error / differences, 2 dry run, 64 usage.

import 'dart:async';
import 'dart:io';

import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_io.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/show_file.dart';

class _Args {
  final List<String> positional = [];
  final Map<String, String> options = {};
  final Set<String> flags = {};

  _Args(List<String> args) {
    const boolFlags = {'yes', 'no-verify', 'help'};
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('--')) {
        final name = a.substring(2);
        if (boolFlags.contains(name)) {
          flags.add(name);
        } else if (i + 1 < args.length) {
          options[name] = args[++i];
        } else {
          throw _Usage('option $a needs a value');
        }
      } else {
        positional.add(a);
      }
    }
  }

  String? opt(String name) => options[name];
  int get port => int.tryParse(options['port'] ?? '') ?? vnPort;
}

/// --ip, or the one LPU that answers discovery.
Future<String> _ip(_Args a) async {
  final ip = a.opt('ip');
  if (ip != null) return ip;
  stdout.writeln('no --ip given, looking for an LPU ...');
  final found = await discover(timeout: const Duration(seconds: 3), port: a.port);
  if (found.length == 1) {
    final e = found.entries.first;
    stdout.writeln('found ${e.value.label} at ${e.key} (firmware ${e.value.firmware})');
    return e.key;
  }
  if (found.isEmpty) throw LpuError('no LPU found by discovery - pass --ip');
  found.forEach((ip, d) => stdout.writeln('  $ip  ${d.label}  firmware ${d.firmware}'));
  throw LpuError('several LPUs found - pass --ip');
}

class _Usage implements Exception {
  final String message;
  _Usage(this.message);
}

int _playback(_Args a) {
  if (a.positional.length < 2) throw _Usage('playback number (1-64) missing');
  final n = int.tryParse(a.positional[1]);
  if (n == null || n < 1 || n > slots) throw _Usage('playback must be 1-64');
  return n - 1;
}

bool? _onOff(String? v) => v == null ? null : (v == 'on' || v == 'true' || v == '1');

Future<T> _withClient<T>(_Args a, Future<T> Function(LpuClient c) body) async {
  final c = await LpuClient.connect(await _ip(a), port: a.port);
  try {
    return await body(c);
  } finally {
    await c.close();
  }
}

String _summary(Show s) {
  final b = StringBuffer();
  b.writeln('fixtures: ${s.fixtures.length}');
  for (final f in s.fixtures) {
    final name = f.name.isEmpty ? '' : '  "${f.name}"';
    b.writeln('  ${(f.index + 1).toString().padLeft(2)}  DMX ${f.address}  ${f.manufacturer} / ${f.model}'
        '${f.mode.isEmpty ? '' : ' / ${f.mode}'}$name');
  }
  b.writeln('playbacks: ${s.playbacks.length}, cues: ${s.playbacks.fold<int>(0, (n, p) => n + p.cues.length)}');
  for (final p in s.playbacks) {
    b.writeln('  ${(p.index + 1).toString().padLeft(2)}  ${p.label.isEmpty ? '(no label)' : p.label}  '
        '${p.cues.length} cue(s), ${p.goMode}, ${p.repeat}');
  }
  return b.toString();
}

Future<int> _run(List<String> argv) async {
  final a = _Args(argv);
  if (a.positional.isEmpty || a.flags.contains('help')) throw _Usage('');
  switch (a.positional.first) {
    case 'discover':
      final secs = int.tryParse(a.opt('timeout') ?? '') ?? 4;
      final found = await discover(timeout: Duration(seconds: secs), port: a.port);
      if (found.isEmpty) {
        stdout.writeln('no LPU found');
        return 1;
      }
      found.forEach((ip, d) => stdout.writeln('$ip  ${d.label}  firmware ${d.firmware}'));
      return 0;

    case 'info':
      return _withClient(a, (c) async {
        final r = await download(c);
        final i = r.info;
        stdout.writeln('LPU ${c.address.address}: alias "${i.alias}", firmware ${i.firmware}, PCB ${i.pcb}, MAC ${i.mac}');
        stdout.writeln('Art-Net ${i.artNetEnabled ? 'enabled' : 'disabled'}, universe ${i.artNetUniverse}; '
            'sACN ${i.sacnEnabled ? 'enabled' : 'disabled'}, universe ${i.sacnUniverse}');
        stdout.write(_summary(r.show));
        return 0;
      });

    case 'download':
      final path = a.opt('show') ?? (throw _Usage('--show FILE is required'));
      return _withClient(a, (c) async {
        final t = Stopwatch()..start();
        final r = await download(c, log: stdout.writeln);
        File(path).parent.createSync(recursive: true);
        File(path).writeAsStringSync(writeShow(r.show));
        stdout.writeln('downloaded in ${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)}s -> $path');
        return 0;
      });

    case 'upload':
      if (a.positional.length < 2) throw _Usage('upload needs a .show file');
      final show = parseShow(File(a.positional[1]).readAsStringSync());
      final cues = show.playbacks.fold<int>(0, (n, p) => n + p.cues.length);
      stdout.writeln('${a.positional[1]}: ${show.fixtures.length} fixtures, '
          '${show.playbacks.length} playbacks, $cues cues');
      if (!a.flags.contains('yes')) {
        stdout.write(_summary(show));
        stdout.writeln('cleared on the LPU: ${slots - show.fixtures.length} fixture slots and '
            '${slots - show.playbacks.length} playback slots not in this file');
        stdout.writeln('dry run: nothing sent. Re-run with --yes to back up, upload and verify.');
        return 2;
      }
      return _withClient(a, (c) async {
        final backup = a.opt('backup');
        if (backup != null) {
          stdout.writeln('1/3 backing up the current show ...');
          File(backup).parent.createSync(recursive: true);
          File(backup).writeAsStringSync(writeShow((await download(c)).show));
          stdout.writeln('    backup: $backup');
        }
        stdout.writeln('2/3 uploading ...');
        await upload(c, show, log: (m) => stdout.writeln('  $m'));
        if (a.flags.contains('no-verify')) return 0;
        stdout.writeln('3/3 verifying ...');
        final diffs = compareShows(show, (await download(c)).show);
        if (diffs.isEmpty) {
          stdout.writeln('    verified: the LPU now holds exactly this show');
          return 0;
        }
        for (final d in diffs.take(40)) {
          stdout.writeln('    - $d');
        }
        return 1;
      });

    case 'go':
    case 'flash':
    case 'release':
    case 'release-all':
      final cmd = a.positional.first;
      final pb = cmd == 'release-all' ? 0 : _playback(a);
      final hold = Duration(milliseconds: int.tryParse(a.opt('hold') ?? '') ?? 500);
      return _withClient(a, (c) async {
        switch (cmd) {
          case 'go':
            await go(c, pb);
          case 'flash':
            await flash(c, pb, hold: hold);
          case 'release':
            await release(c, pb);
          default:
            await releaseAll(c);
        }
        stdout.writeln('done');
        return 0;
      });

    case 'playback':
      final pb = _playback(a);
      String? choice(String opt, List<String> allowed) {
        final v = a.opt(opt);
        if (v == null) return null;
        final m = allowed.where((x) => x.toLowerCase() == v.toLowerCase());
        if (m.isEmpty) throw _Usage('--$opt must be one of ${allowed.join(', ')}');
        return m.first;
      }
      double? number(String opt) => a.opt(opt) == null ? null : double.parse(a.opt(opt)!);
      final goMode = choice('gomode', goModes), repeat = choice('repeat', repeatModes);
      return _withClient(a, (c) async {
        await setPlayback(c, pb,
            goMode: goMode,
            repeat: repeat,
            background: _onOff(a.opt('background')),
            exclusive: _onOff(a.opt('exclusive')),
            label: a.opt('label'),
            intensity: number('intensity'),
            speed: number('speed'));
        // Read back just this playback (packed state 29 30, label, intensity, speed).
        final st = (await c.read(objPlayback, 0x30, i1: pb)).body;
        final label = await c.readValue(objPlayback, 0x05, i1: pb) as String;
        final intensity = await c.readValue(objPlayback, 0x17, i1: pb) as double;
        final speed = await c.readValue(objPlayback, 0x15, i1: pb) as double;
        final g = st.length >= 2 ? st[0] >> 4 : 0, r = st.length >= 2 ? st[1] >> 4 : 0;
        stdout.writeln('playback ${pb + 1}: ${label.isEmpty ? '(no label)' : label}, '
            'go mode ${g < 4 ? goModes[g] : g}, repeat ${r < 4 ? repeatModes[r] : r}, '
            'intensity ${formatG(intensity)}, speed ${formatG(speed)}'
            '${st.isNotEmpty && st[0] & 1 != 0 ? ', background' : ''}'
            '${st.isNotEmpty && st[0] & 2 != 0 ? ', exclusive' : ''}');
        return 0;
      });

    case 'set':
      return _withClient(a, (c) async {
        final alias = a.opt('alias');
        if (alias != null) await setAlias(c, alias);
        final artU = a.opt('artnet-universe');
        if (artU != null || a.opt('artnet') != null) {
          final u = artU == null ? null : int.parse(artU);
          if (u != null && (u < 0 || u > 15)) throw _Usage('--artnet-universe is 0-15');
          await setArtNet(c, enabled: _onOff(a.opt('artnet')), universe: u);
        }
        final sU = a.opt('sacn-universe');
        if (sU != null || a.opt('sacn') != null) {
          await setSacn(c, enabled: _onOff(a.opt('sacn')), universe: sU == null ? null : int.parse(sU));
        }
        stdout.writeln('done');
        return 0;
      });

    case 'status':
      // Read-only: each playback's packed state (29 30) - shows stuck releases
      // and active cues that point past the end of the playback (FINDINGS 20.13).
      return _withClient(a, (c) async {
        const phase = {0: 'no cues', 1: 'released', 2: 'running', 3: 'holding', 4: 'RELEASING'};
        var problems = 0;
        for (var p = 0; p < slots; p++) {
          final s = playbackState((await c.read(objPlayback, 0x30, i1: p)).body);
          // State 0 = no cues: the active cue byte means nothing then (the LPU
          // sets it to 0 when the last cue is deleted, FINDINGS 20).
          if (s.cues == 0 && s.state <= 1) continue;
          final label = await c.readValue(objPlayback, 0x05, i1: p) as String;
          final bad = s.state != 0 && s.activeCue != null && s.activeCue! >= s.cues;
          if (bad) problems++;
          stdout.writeln('pb${(p + 1).toString().padLeft(2)}  ${label.isEmpty ? '(no label)' : label}'
              '  ${s.cues} cue(s)  ${phase[s.state] ?? 'state ${s.state}'}'
              '  ${s.activeCue == null ? 'released' : 'active cue ${s.activeCue! + 1}'}'
              '${bad ? '  <- cue does not exist' : ''}');
        }
        return problems == 0 ? 0 : 1;
      });

    case 'monitor':
      final secs = int.tryParse(a.opt('seconds') ?? '') ?? 30;
      return _withClient(a, (c) async {
        // The LPU sends live messages to sockets that sent it typed frames
        // (FINDINGS 20.14); keepalives and short reads do not count. One typed
        // read of playback 1's state registers this client.
        final alias = decStr(await c.shortRead(ShortProp.alias));
        await c.read(objPlayback, 0x30, i1: 0);
        stdout.writeln('connected to LPU ${c.address.address} ("$alias"). Listening for $secs s - '
            'press buttons / move faders now. Every line below is one live message.');
        var count = 0;
        final sub = c.notifications.listen((f) {
          count++;
          final v = f.value();
          stdout.writeln('${DateTime.now().toIso8601String().substring(11, 23)}  '
              '${f.op.toRadixString(16)} ${f.type.toRadixString(16)} ${f.prop.toRadixString(16)} '
              '[${f.i1},${f.i2},${f.i3}]  ${v is List<int> ? '${v.length} bytes' : v}'
              '   ${decodeNotification(f) ?? ''}');
        });
        await Future.delayed(Duration(seconds: secs));
        await sub.cancel();
        stdout.writeln('done: $count live message(s) received in $secs s.');
        return 0;
      });

    case 'show':
      if (a.positional.length < 2) throw _Usage('show needs a .show file');
      stdout.write(_summary(parseShow(File(a.positional[1]).readAsStringSync())));
      return 0;
  }
  throw _Usage('unknown command ${a.positional.first}');
}

Future<void> main(List<String> argv) async {
  int code;
  try {
    code = await _run(argv);
  } on _Usage catch (e) {
    if (e.message.isNotEmpty) stderr.writeln('error: ${e.message}');
    final src = File.fromUri(Platform.script);
    final help = src.existsSync()
        ? src.readAsLinesSync().skip(1).takeWhile((l) => l.startsWith('//')).map((l) => l.replaceFirst(RegExp(r'^// ?'), ''))
        : ['see bin/dled_cli.dart'];
    stderr.writeln(help.join('\n'));
    code = 64;
  } on LpuError catch (e) {
    stderr.writeln('error: ${e.message}');
    code = 1;
  }
  exit(code);
}
