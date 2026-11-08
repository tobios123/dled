// Stored positions: the store's rules, the file next
// to the show, and POSITIONS in EDIT - STORE, recall SELECTED / WITH FIXTURES.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/edit_screen.dart';
import 'package:dled/services/show_folder.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/widgets/edit_controls.dart';
import 'package:dled/widgets/fixture_grid.dart';

const _m400 = 'test/core_data/shows/m400.show';

StoredFixture _f(int slot, int pan, int tilt, {String model = 'M'}) =>
    StoredFixture(slot: slot, model: model, pan: pan, tilt: tilt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('store', () {
    test('STORE onto a used tile merges', () {
      final s = PositionStore();
      expect(s.store(3, [_f(1, 10, 20), _f(2, 30, 40)]), isTrue);
      expect(s.store(3, [_f(2, 50, 60), _f(5, 70, 80)]), isTrue);
      final p = s[3]!;
      expect(p.fixtures.keys.toSet(), {1, 2, 5});
      expect(p.fixtures[1]!.pan, 10); // stays
      expect(p.fixtures[2]!.pan, 50); // updated
      expect(s.store(4, const []), isFalse); // nothing to store: no tile
      expect(s[4], isNull);
    });

    test('swap, move, rename, delete', () {
      final s = PositionStore()
        ..store(0, [_f(1, 1, 1)])
        ..store(1, [_f(2, 2, 2)]);
      expect(s.swap(0, 1), isTrue);
      expect(s[0]!.fixtures.keys, [2]);
      expect(s[1]!.fixtures.keys, [1]);
      expect(s.swap(1, 9), isTrue); // onto an empty tile: a move
      expect(s[1], isNull);
      expect(s[9]!.fixtures.keys, [1]);
      expect(s.swap(20, 21), isFalse);
      expect(s.rename(9, '  Singer '), isTrue);
      expect(s[9]!.name, 'Singer');
      expect(s.delete(9), isTrue);
      expect(s[9], isNull);
    });

    test('16 bits: a FINE position comes back as it was', () {
      for (final v in [0.0, 50.25, 127.5, 128.0, 200.1, 255.0]) {
        expect(StoredFixture.toEdit(StoredFixture.fromEdit(v)), closeTo(v, 255 / 65535 / 2 + 1e-9));
      }
    });

    test('JSON round trip; a newer version or junk is empty', () {
      final s = PositionStore()
        ..store(7, [
          const StoredFixture(
              slot: 8, manufacturer: 'Shehds', model: 'LED BEAM', mode: '16 ch', name: 'MH L', pan: 41210, tilt: 30001)
        ])
        ..rename(7, 'Singer');
      final t = PositionStore()..decode(s.encode());
      final f = t[7]!.fixtures[8]!;
      expect(t[7]!.name, 'Singer');
      expect([f.manufacturer, f.model, f.mode, f.name, f.pan, f.tilt], ['Shehds', 'LED BEAM', '16 ch', 'MH L', 41210, 30001]);
      expect((PositionStore()..decode('{"version": 2, "positions": []}')).isEmpty, isTrue);
      expect((PositionStore()..decode('not json')).isEmpty, isTrue);
      final bad = PositionStore()
        ..decode('{"version":1,"positions":[{"tile":99,"fixtures":[{"slot":1,"pan":1,"tilt":1}]},'
            '{"tile":2,"fixtures":[{"slot":70,"pan":1,"tilt":1},{"slot":3,"pan":5,"tilt":6}]}]}');
      expect(bad.positions.keys, [2]);
      expect(bad[2]!.fixtures.keys, [3]);
    });
  });

  group('saved with the show', () {
    late Directory dir;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('dled_pos_');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    File file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

    test('Windows: NAME.positions.json next to NAME.show', () async {
      final m = ShowModel();
      await m.useShowFolder(ShowFolder(dir));
      ShowLoader.loadFromString(File(_m400).readAsStringSync())!.applyToModel(m);
      expect(await m.saveShow('a'), isTrue);
      expect(file('a.positions.json').existsSync(), isFalse); // no positions: no file
      m.positions.store(0, [_f(8, 1000, 2000)]);
      m.positionsChanged();
      expect(m.showModified, isTrue);
      await m.saveShow('a');
      expect(file('a.positions.json').existsSync(), isTrue);
      // the .show itself has nothing extra (the reference app opens it as always)
      expect(file('a.show').readAsStringSync(), isNot(contains('position')));
      expect(m.showFiles.map((f) => f.name), ['a']); // not listed as a show

      m.newShow();
      expect(m.positions.isEmpty, isTrue);
      await m.loadShow('a');
      expect(m.positions[0]!.fixtures[8]!.tilt, 2000);

      expect(await m.renameShow('a', 'b'), isTrue);
      expect(file('b.positions.json').existsSync(), isTrue);
      expect(file('a.positions.json').existsSync(), isFalse);

      m.positions.clear();
      await m.saveShow('b'); // all deleted: the file goes
      expect(file('b.positions.json').existsSync(), isFalse);

      m.positions.store(1, [_f(9, 1, 1)]);
      await m.saveShow('b');
      await m.deleteShow('b');
      expect(file('b.positions.json').existsSync(), isFalse);
      m.dispose();
    });

    test('internal storage: in the show\'s JSON', () async {
      final m = ShowModel();
      await m.useShowFolder(null);
      m.positions.store(5, [_f(8, 123, 456)]);
      await m.saveShow('x');
      m.newShow();
      await m.loadShow('x');
      expect(m.positions[5]!.fixtures[8]!.pan, 123);
      m.dispose();
    });
  });

  group('POSITIONS in EDIT', () {
    late ShowModel model;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      model = ShowModel();
      ShowLoader.loadFromString(File(_m400).readAsStringSync())!.applyToModel(model);
    });
    tearDown(() => model.vnService.stop());

    testWidgets('STORE per fixture, recall SELECTED and WITH FIXTURES', (tester) async {
      tester.view.physicalSize = const Size(768, 1024);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final pb = model.cuelists.indexWhere((c) => c.cues.isNotEmpty);
      final cue = model.cuelists[pb].cues.first;
      await tester.pumpWidget(ChangeNotifierProvider<ShowModel>.value(
          value: model, child: MaterialApp(home: EditScreen(cuelistIndex: pb))));
      await tester.pump();
      final tileLabel = cue.label.isEmpty || cue.label == 'Cue ${cue.number}' ? '${cue.number}' : cue.label;
      await tester.tap(find.text(tileLabel).first);
      await tester.pump();
      await tester.tap(find.text('CLEAR ALL'));
      await tester.pump();

      FixtureGrid grid() => tester.widget<FixtureGrid>(find.byType(FixtureGrid));
      Future<void> select(int slot, bool on) async {
        grid().onSet(slot, on);
        await tester.pump();
      }

      Future<void> aim(double pan, double tilt) async {
        tester.widget<PositionPad>(find.byType(PositionPad)).onChanged!(pan, tilt);
        await tester.pump();
      }

      Future<void> tap(String text) async {
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      Future<void> tile(int t) async {
        await tester.tap(find.byKey(ValueKey('position_tile_$t')));
        await tester.pumpAndSettle();
      }

      // 8 and 9 (moving heads) aimed differently, 0 (no pan / tilt) selected too
      await select(8, true);
      await select(9, true);
      await aim(200, 60);
      await select(8, false);
      await aim(50.25, 180);
      await select(8, true);
      await select(0, true);

      await tap('POS');
      await tap('STORE');
      await tile(0);
      final p = model.positions[0]!;
      expect(p.fixtures.keys.toSet(), {8, 9}); // 0 has no pan / tilt
      expect(p.fixtures[8]!.editPan, closeTo(200, 0.01));
      expect(p.fixtures[9]!.editPan, closeTo(50.25, 0.01));
      expect(p.fixtures[9]!.editTilt, closeTo(180, 0.01));
      expect(p.fixtures[8]!.model, 'LED BEAM 12x12W RGBW Moving H');
      expect(find.text('Pos 1'), findsOneWidget);
      expect(model.showModified, isTrue);
      await tap('BACK'); // the positions window's BACK
      expect(find.byType(EditScreen), findsOneWidget);

      // all home, then only 9 (and 0) selected: SELECTED recalls into 9 only
      await aim(128, 128);
      await select(8, false);
      await tap('POS');
      await tile(0);
      expect(find.text('STORE'), findsNothing); // back in EDIT
      await tap('RECORD');
      expect(cue.channels['9:Pan']! * 255, closeTo(50.25, 0.01));
      expect(cue.channels['9:Tilt']! * 255, closeTo(180, 0.01));
      expect(cue.channels['8:Pan']! * 255, closeTo(128, 0.01));
      expect(grid().selected, {0, 9});

      // WITH FIXTURES: the selection becomes 8 and 9, each its own position
      await tap('POS');
      await tap('SELECTED'); // the mode button -> WITH FIXTURES
      expect(find.text('WITH FIXTURES'), findsOneWidget);
      await tile(0);
      expect(grid().selected, {8, 9});
      await tap('RECORD');
      expect(cue.channels['8:Pan']! * 255, closeTo(200, 0.01));
      expect(cue.channels['8:Tilt']! * 255, closeTo(60, 0.01));
      expect(cue.channels['9:Pan']! * 255, closeTo(50.25, 0.01));
      expect(model.positionsWithFixtures, isTrue);

      // RENAME, SWAP and DELETE keep the window open
      await tap('POS');
      await tap('SWAP');
      await tile(0);
      await tile(10);
      expect(model.positions[0], isNull);
      expect(model.positions[10], isNotNull);
      await tap('DELETE');
      await tile(10);
      expect(model.positions.isEmpty, isTrue);
      expect(find.text('STORE'), findsOneWidget);
    });
  });
}
