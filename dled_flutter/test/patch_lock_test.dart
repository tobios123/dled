// PATCH: every button works on an empty slot (like the reference app); a DMX
// collision locks PLAYBACK (no EDIT, no playback changes) without a message.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/patch_screen.dart';
import 'package:dled/screens/playback_screen.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/widgets/app_button.dart';

ShowModel _model() {
  final m = ShowModel();
  ShowLoader.loadFromString(File('test/core_data/shows/m400.show').readAsStringSync())!.applyToModel(m);
  return m;
}

Future<void> _pump(WidgetTester tester, ShowModel m, Widget home) async {
  tester.view.physicalSize = const Size(768, 1024);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(m.vnService.stop);
  await tester.pumpWidget(ChangeNotifierProvider<ShowModel>.value(value: m, child: MaterialApp(home: home)));
  await tester.pump();
}

bool _on(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).onTap != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('an empty slot enables every PATCH button and can be named', (tester) async {
    final m = _model();
    await _pump(tester, m, const PatchScreen(initialTab: 0));
    await tester.tap(find.text('40'));
    await tester.pump();
    for (final b in ['PERSONALITY', 'RENAME', 'ADDRESS', 'CLEAR', 'INVERT\nPAN', 'VIRTUAL\nDIMMER']) {
      expect(_on(tester, b), isTrue, reason: b);
    }
    await tester.tap(find.text('RENAME'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'spare');
    await tester.tap(find.text('Ok'));
    await tester.pumpAndSettle();
    final e = m.fixtures.firstWhere((f) => f.slot == 39);
    expect([e.label, e.isPatched], ['spare', false]);
  });

  testWidgets('a DMX collision locks playback and EDIT', (tester) async {
    final m = _model();
    await _pump(tester, m, const PlaybackScreen());
    expect(_on(tester, 'EDIT'), isTrue);
    m.addFixture(FixturePatch(id: 99, slot: 56, model: 'WARD', address: 1, channelCount: 30));
    await tester.pump();
    expect(m.patchCollision, isTrue);
    for (final b in ['EDIT', 'RELEASE', 'RENAME', 'SWAP', 'PROPS']) {
      expect(_on(tester, b), isFalse, reason: b);
    }
    expect(_on(tester, 'PATCH'), isTrue); // the way to fix it
    m.removeFixture(99);
    await tester.pump();
    expect(_on(tester, 'EDIT'), isTrue);
  });
}
