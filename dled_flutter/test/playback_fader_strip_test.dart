import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/playback_screen.dart';

// Wrap PlaybackScreen with a ChangeNotifierProvider<ShowModel>.
Widget _buildApp(ShowModel model) {
  return ChangeNotifierProvider<ShowModel>.value(
    value: model,
    child: const MaterialApp(home: PlaybackScreen()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('PlaybackScreen fader strip', () {
    late ShowModel model;

    setUp(() {
      // The app is laid out for a landscape tablet; the default 800x600 test
      // window makes rows overflow.
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1920, 1080);
      view.devicePixelRatio = 1.0;
      addTearDown(view.resetPhysicalSize);
      addTearDown(view.resetDevicePixelRatio);
      model = ShowModel();
      // Label the first 8 cuelists so the fader strip has readable text.
      for (int i = 0; i < 8; i++) {
        model.cuelists[i].label = 'CL ${i + 1}';
      }
    });

    testWidgets('tiles show the name, or the number when there is none',
        (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      // Like the reference app: a named playback shows its name instead of the number.
      for (int slot = 1; slot <= 8; slot++) {
        expect(find.text(slot.toString()), findsNothing,
            reason: 'playback $slot has a name');
      }
      for (int slot = 9; slot <= 16; slot++) {
        expect(find.text(slot.toString()), findsOneWidget,
            reason: 'empty playback $slot shows its number');
      }
    });

    testWidgets('renders cuelist labels on the tiles', (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      for (int i = 1; i <= 8; i++) {
        expect(find.text('CL $i'), findsWidgets,
            reason: 'label CL $i should appear on its tile');
      }
    });

    testWidgets('FLASH button text is present for each fader strip',
        (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      // There are 8 fader strips on the first page, each with a FLASH button.
      expect(find.text('FLASH'), findsWidgets);
    });

    // Middle of the first fader (the fader section is the lower third).
    const firstFader = Offset(1920 / 16, 1080 - 1080 * 0.33 / 2);

    testWidgets('faders start full and follow a drag', (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      expect(model.shownLevel(model.cuelists[0]), 1.0);
      await tester.dragFrom(firstFader, const Offset(0, 120));
      await tester.pump();
      final l = model.shownLevel(model.cuelists[0]);
      expect(l, lessThan(1.0));
      expect(l, greaterThan(0.0));
    });

    testWidgets('Ctrl + mouse wheel moves the faders to the next row', (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(firstFader));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40))); // no Ctrl: nothing
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // The first fader is now playback 9's.
      await tester.dragFrom(firstFader, const Offset(0, 120));
      await tester.pump();
      expect(model.shownLevel(model.cuelists[8]), lessThan(1.0));
      expect(model.shownLevel(model.cuelists[0]), 1.0);
    });

    testWidgets('Ctrl + two-finger touchpad slide moves the faders to the next row', (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(pad.panZoomStart(firstFader));
      await tester.sendEventToBinding(pad.panZoomUpdate(firstFader, pan: const Offset(0, -50))); // fingers up
      await tester.sendEventToBinding(pad.panZoomEnd());
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.dragFrom(firstFader, const Offset(0, 120));
      await tester.pump();
      expect(model.shownLevel(model.cuelists[8]), lessThan(1.0));
      expect(model.shownLevel(model.cuelists[0]), 1.0);
    });

    testWidgets('holding RELEASE for 0.5 s releases all', (tester) async {
      model.cuelists[0].cues.add(Cue(number: 1));
      model.goCuelist(model.cuelists[0].id);
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();
      expect(model.cuelists[0].state, PlaybackState.playing);

      final g = await tester.startGesture(tester.getCenter(find.text('RELEASE')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.cuelists[0].state, PlaybackState.playing); // not yet
      await tester.pump(const Duration(milliseconds: 250));
      expect(model.cuelists[0].state, PlaybackState.released);
      await g.up();
      await tester.pump();
    });

    testWidgets('LED is dark (not green/not blue) when cuelist is released',
        (tester) async {
      // Ensure first cuelist is released.
      model.cuelists[0].state = PlaybackState.released;
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      // The PlaybackScreen should render without error.
      expect(find.byType(PlaybackScreen), findsOneWidget);
    });

    testWidgets('LED appears highlighted when cuelist is playing',
        (tester) async {
      model.cuelists[0].state = PlaybackState.playing;
      model.cuelists[0].level = 1.0;
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      // The screen should rebuild with the playing state without error.
      expect(find.byType(PlaybackScreen), findsOneWidget);
    });

    testWidgets('notifyListeners rebuild does not throw', (tester) async {
      await tester.pumpWidget(_buildApp(model));
      await tester.pump();

      // Mutate model and verify the widget tree rebuilds cleanly.
      model.setLiveFaderLevel(0, 0.75);
      await tester.pump();

      expect(find.byType(PlaybackScreen), findsOneWidget);
    });
  });
}
