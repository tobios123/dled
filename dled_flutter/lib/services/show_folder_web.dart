// Web stub for show_folder.dart: browsers have no show folder; the app's
// internal storage is used (show_model.dart) with IMPORT / EXPORT.

typedef ShowFileInfo = ({String name, DateTime modified, int size});

class ShowFolder {
  static Future<ShowFolder?> open() async => null;
  static String safeName(String name) => name;
  String get path => '';
  List<ShowFileInfo> list() => const [];
  bool exists(String name) => false;
  String? read(String name) => null;
  void write(String name, String text) {}
  void delete(String name) {}
  bool rename(String from, String to) => false;
  String? readPositions(String name) => null;
  void writePositions(String name, String? text) {}
  Future<void> reveal() async {}
}
