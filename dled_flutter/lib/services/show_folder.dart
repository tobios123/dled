// show_folder.dart -- saved shows as real .show files in a folder (Windows).
//
// On Windows the show list is the folder Documents\DLED\shows. Every saved
// show is one .show file (the reference app's format), so files copied in appear
// in the list and FOLDER opens the folder in Explorer. Phone and web keep the app's
// internal storage (show_model.dart) with IMPORT / EXPORT.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef ShowFileInfo = ({String name, DateTime modified, int size});

class ShowFolder {
  final Directory dir;
  ShowFolder(this.dir);

  /// The show folder on Windows (created when missing); null elsewhere and
  /// in tests (they must never touch the user's Documents).
  static Future<ShowFolder?> open() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(['${docs.path}', 'DLED', 'shows'].join(Platform.pathSeparator));
      await dir.create(recursive: true);
      return ShowFolder(dir);
    } catch (_) {
      return null; // no folder: the internal storage is used
    }
  }

  String get path => dir.path;

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}${safeName(name)}.show');

  /// The show's stored positions, next to it (models/position_store.dart):
  /// the reference app drops anything extra inside a .show when it saves.
  File _positions(String name) => File('${dir.path}${Platform.pathSeparator}${safeName(name)}.positions.json');

  /// A show name as a Windows file name (no \ / : * ? " < > |).
  static String safeName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  List<ShowFileInfo> list() {
    final out = <ShowFileInfo>[];
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.show')) continue;
      final base = e.uri.pathSegments.last;
      final st = e.statSync();
      out.add((name: Uri.decodeComponent(base.substring(0, base.length - 5)), modified: st.modified, size: st.size));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  bool exists(String name) => _file(name).existsSync();
  String? read(String name) => exists(name) ? _file(name).readAsStringSync() : null;
  void write(String name, String text) => _file(name).writeAsStringSync(text);
  void delete(String name) {
    if (exists(name)) _file(name).deleteSync();
    if (_positions(name).existsSync()) _positions(name).deleteSync();
  }

  bool rename(String from, String to) {
    if (!exists(from) || exists(to)) return false;
    _file(from).renameSync(_file(to).path);
    if (_positions(from).existsSync()) {
      if (_positions(to).existsSync()) _positions(to).deleteSync();
      _positions(from).renameSync(_positions(to).path);
    }
    return true;
  }

  /// The positions file's text, or null when the show has none.
  String? readPositions(String name) => _positions(name).existsSync() ? _positions(name).readAsStringSync() : null;

  /// Writes the positions file; null removes it (a show without positions).
  void writePositions(String name, String? text) {
    final f = _positions(name);
    if (text != null) {
      f.writeAsStringSync(text);
    } else if (f.existsSync()) {
      f.deleteSync();
    }
  }

  /// Open the folder in Explorer (FOLDER button).
  Future<void> reveal() => Process.run('explorer', [dir.path]);
}
