// Pure-Dart backend shared by the app and the CLI (no Flutter imports).
// lpu_client.dart and lpu_io.dart need dart:io, so they are not exported here
// (web builds); import them directly where sockets are available.
export 'fixture_codes.dart';
export 'frame.dart';
export 'lpu_live.dart';
export 'show_file.dart';
