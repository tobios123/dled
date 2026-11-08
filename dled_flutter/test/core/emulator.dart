// Test helper: run the Python LPU emulator and the Python tools from Dart tests.
// Every helper returns null / skips when Python or the scripts are missing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const emulatorScript = '../analysis/scripts/lpu_emulator.py';
const pythonDownload = '../.claude/skills/lpu-show-download/scripts/lpu_download.py';

class Emulator {
  final Process process;
  final int port;
  Emulator._(this.process, this.port);

  /// Start the emulator on [ip]:[port] with [show] loaded; null if impossible.
  /// (Other loopback addresses like 127.0.0.2 give a second "LPU".)
  static Future<Emulator?> start(int port, {String? show, String ip = '127.0.0.1'}) async {
    if (!File(emulatorScript).existsSync()) return null;
    final Process p;
    try {
      p = await Process.start('python', [
        emulatorScript, '--port', '$port', '--bind', ip, '--ip', ip,
        '--alias', 'EMU', if (show != null) ...['--show', show],
      ]);
    } on ProcessException {
      return null;
    }
    final ready = Completer<bool>();
    p.stdout.transform(utf8.decoder).listen((s) {
      if (s.contains('LPU emulator') && !ready.isCompleted) ready.complete(true);
    });
    p.stderr.transform(utf8.decoder).listen((_) {});
    final ok = await ready.future.timeout(const Duration(seconds: 15), onTimeout: () => false);
    if (!ok) {
      p.kill();
      return null;
    }
    return Emulator._(p, port);
  }

  void stop() => process.kill();
}

/// Download with the Python tool into [path]; returns false if it failed.
Future<bool> pythonDownloadTo(int port, String path) async {
  final r = await Process.run('python', [pythonDownload, '--ip', '127.0.0.1', '--port', '$port', '--show', path]);
  return r.exitCode == 0;
}

/// The Dart SDK that ships with Flutter (the plain `dart` wrapper needs git).
String? dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final candidates = [
    if (root != null) '$root/bin/cache/dart-sdk/bin/$exe',
    '${File(Platform.resolvedExecutable).parent.path}/$exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
