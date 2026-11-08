// EDIT: an empty (unpatched) slot can be selected, but adds no channels:
// alone it enables no fader, with a patched fixture that fixture's channels
// count (like the reference app).

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

  testWidgets('an empty slot enables no fader on its own', (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final model = ShowModel();
    ShowLoader.loadFromString(File('test/core_data/shows/m400.show').readAsStringSync())!.applyToModel(model);
    addTearDown(model.vnService.stop);
    await tester.pumpWidget(ChangeNotifierProvider<ShowModel>.value(
        value: model, child: const MaterialApp(home: EditScreen(cuelistIndex: 0))));
    await tester.pump();
    expect(model.fixtures.any((f) => f.slot == 19), isFalse); // slot 20 is empty
    List<String> on() => [
          for (final f in tester.widgetList<LedFader>(find.byType(LedFader)))
            if (f.onChanged != null) f.label
        ];
    bool button(String label) =>
        tester.widget<AppButton>(find.widgetWithText(AppButton, label)).onTap != null;

    await tester.tap(find.text('20'));
    await tester.pump();
    expect(on(), isEmpty);
    expect(button('Fine'), isFalse); // no pan / tilt either

    // with fixture 1 (an RGB par, no pan / tilt): only its channels
    await tester.tap(find.text('1').last); // the tile (the first '1' is cue 1)
    await tester.pump();
    final one = model.fixtures.firstWhere((f) => f.slot == 0).channels;
    expect(on().toSet(), one.intersection(on().toSet()));
    expect(on(), isNotEmpty);
    expect(button('Fine'), one.contains('Pan') || one.contains('Tilt'));
  });
}
