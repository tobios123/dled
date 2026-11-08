// EDIT opens again as it was left (like the reference app, 2026-10-29): the
// selected cue on the same playback, the fixtures, the slider values - also
// when nothing was recorded.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/edit_screen.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/widgets/app_button.dart';
import 'package:dled/widgets/edit_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('EDIT opens again as it was left', (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final model = ShowModel();
    ShowLoader.loadFromString(File('test/core_data/shows/m400.show').readAsStringSync())!.applyToModel(model);
    addTearDown(model.vnService.stop);
    Future<void> open(int cuelist) async {
      await tester.pumpWidget(ChangeNotifierProvider<ShowModel>.value(
          value: model, child: MaterialApp(home: EditScreen(key: UniqueKey(), cuelistIndex: cuelist))));
      await tester.pump();
    }

    Future<void> close() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    bool button(String label) =>
        tester.widget<AppButton>(find.widgetWithText(AppButton, label)).onTap != null;
    LedFader fader(String label) =>
        tester.widgetList<LedFader>(find.byType(LedFader)).firstWhere((f) => f.label == label);

    await open(0);
    expect(button('LOAD'), isFalse);
    await tester.tap(find.text('1').first); // cue 1
    await tester.tap(find.text('1').last); // fixture 1
    await tester.pump();
    fader('In').onChanged!(200);
    await tester.pump();
    expect(button('LOAD'), isTrue);
    await close();

    await open(0); // the same playback: everything back
    expect(button('LOAD'), isTrue);
    expect(fader('In').onChanged, isNotNull); // fixture 1 selected
    expect(fader('In').value, 200);
    await close();

    await open(1); // another playback: fixtures and values, not the cue
    expect(button('LOAD'), isFalse);
    expect(fader('In').onChanged, isNotNull);
    expect(fader('In').value, 200);
  });
}
