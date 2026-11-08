// PLAYBACK: a running playback's tile shows the cue's name, like the real
// app: under the playback's name when both fit, else the cue's name alone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/playback_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('both names when they fit, else only the cue name', () {
    List<String> at(double height) => tileLines('Fire', 'flames', width: 70, height: height, fontSize: 12);
    expect(at(60), ['Fire', 'flames']);
    expect(at(20), ['flames']);
    expect(tileLines('Fire', '', width: 70, height: 20, fontSize: 12), ['Fire']);
  });

  testWidgets('the tile shows the cue name only while running', (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final m = ShowModel();
    m.cuelists[0]
      ..label = 'Fire'
      ..cues.add(Cue(number: 1, label: 'flames'));
    addTearDown(m.vnService.stop);
    await tester.pumpWidget(
        ChangeNotifierProvider<ShowModel>.value(value: m, child: const MaterialApp(home: PlaybackScreen())));
    await tester.pump();
    expect(find.text('flames'), findsNothing);
    m.goCuelist(m.cuelists[0].id);
    await tester.pump();
    expect(find.text('flames'), findsOneWidget);
    m.releaseCuelist(m.cuelists[0].id);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('flames'), findsNothing);
  });
}
