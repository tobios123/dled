// Windows show storage: saved shows are real .show files in a folder.
// (A temporary folder here - the tests never touch Documents\DLED.)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/show_file.dart' as core;
import 'package:dled/core/lpu_io.dart' show compareShows;
import 'package:dled/models/show_model.dart';
import 'package:dled/services/show_folder.dart';
import 'package:dled/services/show_loader.dart';

const _m400 = 'test/core_data/shows/m400.show';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('dled_shows_');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ShowModel> model() async {
    final m = ShowModel();
    await m.useShowFolder(ShowFolder(dir));
    return m;
  }

  test('SAVE writes a real .show file; the list is the folder', () async {
    final m = await model();
    ShowLoader.loadFromString(File(_m400).readAsStringSync())!.applyToModel(m);
    expect(await m.saveShow('my show'), isTrue);
    final file = File('${dir.path}${Platform.pathSeparator}my show.show');
    expect(file.existsSync(), isTrue);
    // the same show as the original file
    expect(compareShows(core.parseShow(File(_m400).readAsStringSync()), core.parseShow(file.readAsStringSync())),
        isEmpty);
    expect(m.showFiles.map((s) => s.name), ['my show']);
    expect(m.showFiles.single.sizeBytes, file.lengthSync());

    // a file copied into the folder appears
    File(_m400).copySync('${dir.path}${Platform.pathSeparator}copied.show');
    await m.loadShowFileList();
    expect(m.showFiles.map((s) => s.name), ['copied', 'my show']);
  });

  test('OPEN, RENAME and REMOVE work on the files', () async {
    final m = await model();
    File(_m400).copySync('${dir.path}${Platform.pathSeparator}a.show');
    await m.loadShowFileList();
    await m.loadShow('a');
    expect(m.showFileName, 'a');
    expect(m.fixtures, isNotEmpty);
    expect(await m.renameShow('a', 'b'), isTrue);
    expect(m.showFiles.map((s) => s.name), ['b']);
    expect(await m.savedShowContent('b'), isNotNull);
    await m.deleteShow('b');
    expect(m.showFiles, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('NEW adds "show 1", "show 2" ... without touching the open show', () async {
    final m = await model();
    m.cuelists[0].label = 'keep me';
    expect(await m.addEmptyShow(), 'show 1');
    expect(await m.addEmptyShow(), 'show 2');
    expect(m.showFiles.map((s) => s.name), ['show 1', 'show 2']);
    expect(m.cuelists[0].label, 'keep me');
  });

  test('shows saved in the app before are copied into the folder once', () async {
    final old = ShowModel(); // no folder: the app's internal storage
    await Future.delayed(const Duration(milliseconds: 20));
    ShowLoader.loadFromString(File(_m400).readAsStringSync())!.applyToModel(old);
    await old.saveShow('old show');

    final m = await model();
    expect(m.showFiles.map((s) => s.name), ['old show']);
    await m.loadShow('old show');
    expect(m.fixtures.length, old.fixtures.length);
    m.deleteShow('old show');
    await Future.delayed(const Duration(milliseconds: 20));
    await m.useShowFolder(ShowFolder(dir)); // not copied a second time
    expect(m.showFiles, isEmpty);
  });

  test('unsafe characters become _ in file names', () {
    expect(ShowFolder.safeName('a/b:c?'), 'a_b_c_');
  });
}
