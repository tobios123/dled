// build_light.dart -- build the light DLED page into light/dist/.
//
//   dart run tool/build_light.dart
//
// Compiles light/api.dart (the shared Dart logic) to core.js, takes the page
// files from light/src/ and stores everything gzipped (index.html.gz ...),
// the way WLED builds its pages. The PC bridge serves light/dist with
// --web light/dist; the ESP32 firmware puts the same files in its flash.

import 'dart:io';

Future<void> main() async {
  final dist = Directory('light/dist');
  if (dist.existsSync()) dist.deleteSync(recursive: true);
  dist.createSync(recursive: true);
  final tmp = Directory.systemTemp.createTempSync('dled_light');

  // the shared logic, minified by dart2js
  final dart = Platform.resolvedExecutable;
  final r = await Process.run(dart, ['compile', 'js', '-O2', '--no-source-maps', '-o', '${tmp.path}/core.js', 'light/api.dart']);
  if (r.exitCode != 0) {
    stderr.write(r.stdout);
    stderr.write(r.stderr);
    exit(1);
  }

  final files = <String, List<int>>{
    'core.js': File('${tmp.path}/core.js').readAsBytesSync(),
    // the fixture library for PATCH > PERSONALITY (the app's own copy)
    'personalities.xml': (File('assets/personalities.local.xml').existsSync()
            ? File('assets/personalities.local.xml')
            : File('assets/personalities.xml'))
        .readAsBytesSync(),
    for (final f in Directory('light/src').listSync().whereType<File>())
      f.uri.pathSegments.last: f.readAsBytesSync(),
  };
  tmp.deleteSync(recursive: true);

  var total = 0;
  for (final e in files.entries) {
    // pictures are compressed already: stored as they are
    final gz = e.key.endsWith('.png') ? e.value : gzip.encoder.convert(e.value);
    File('${dist.path}/${e.key}${e.key.endsWith('.png') ? '' : '.gz'}').writeAsBytesSync(gz);
    total += gz.length;
    stdout.writeln('${e.key.padRight(14)} ${(e.value.length / 1024).toStringAsFixed(1).padLeft(7)} KB'
        ' -> ${(gz.length / 1024).toStringAsFixed(1).padLeft(6)} KB gz');
  }
  stdout.writeln('light/dist: ${(total / 1024).toStringAsFixed(1)} KB in ${files.length} files');
}
