// PLAYBACK: a long press (0.8 s) on a running playback releases it, like the
// reference app - holding (yellow) and also fading / waiting (green, 2026-10-29);
// on a released playback it does nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/playback_screen.dart';

/// Hold [f] for [ms] milliseconds.
Future<void> hold(WidgetTester tester, Finder f, int ms) async {
  final g = await tester.startGesture(tester.getCenter(f));
  await tester.pump(Duration(milliseconds: ms));
  await g.up();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Future<ShowModel> pump(WidgetTester tester) async {
    final m = ShowModel();
    m.cuelists[0]
      ..label = 'held'
      ..cues.add(Cue(number: 1));
    m.cuelists[1]
      ..label = 'fading'
      ..cues.add(Cue(number: 1, fadeIn: 30));
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(m.vnService.stop);
    await tester.pumpWidget(
        ChangeNotifierProvider<ShowModel>.value(value: m, child: const MaterialApp(home: PlaybackScreen())));
    await tester.pump();
    return m;
  }

  testWidgets('long press on a holding playback releases it', (tester) async {
    final m = await pump(tester);
    m.goCuelist(m.cuelists[0].id); // no fade: holding (yellow) at once
    await tester.pump();
    expect([m.cuelists[0].state, m.cuelists[0].fading], [PlaybackState.playing, false]);
    await hold(tester, find.text('held'), 600); // not long enough: a tap (GO, next cue)
    expect(m.cuelists[0].state, PlaybackState.playing);
    await hold(tester, find.text('held'), 900);
    expect(m.cuelists[0].state, PlaybackState.released);
    expect(releaseHold, const Duration(milliseconds: 800));
  });

  testWidgets('long press on a fading playback releases it too', (tester) async {
    final m = await pump(tester);
    m.goCuelist(m.cuelists[1].id); // 30 s fade: green
    await tester.pump();
    expect([m.cuelists[1].state, m.cuelists[1].fading], [PlaybackState.playing, true]);
    await hold(tester, find.text('fading'), 900);
    expect(m.cuelists[1].state, isNot(PlaybackState.playing));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('long press on a released playback does nothing', (tester) async {
    final m = await pump(tester);
    await hold(tester, find.text('held'), 900); // released (red): no GO either
    expect(m.cuelists[0].state, PlaybackState.released);
  });
}
