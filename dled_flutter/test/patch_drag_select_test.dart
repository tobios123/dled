// Patch grid drag selection: dragging selects the rectangle between the start
// tile and the tile under the pointer, like the reference app.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/patch_screen.dart';

void main() {
  SharedPreferences.setMockInitialValues({});

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: ShowModel(), child: const MaterialApp(home: PatchScreen())));
    await tester.pump();
  }

  // Tile n (1-64) is selected when its box has the thick white border.
  Set<int> selected(WidgetTester tester) => {
        for (var n = 1; n <= 64; n++)
          if (tester
              .widgetList<Container>(find.ancestor(of: find.text('$n'), matching: find.byType(Container)))
              .any((c) {
            final d = c.decoration;
            return d is BoxDecoration && d.border is Border && (d.border as Border).top.width == 2.5;
          }))
            n,
      };

  Offset centre(WidgetTester tester, int n) => tester.getCenter(find.text('$n'));

  testWidgets('dragging from 1 to 11 selects 1 2 3 9 10 11', (tester) async {
    await open(tester);
    final g = await tester.startGesture(centre(tester, 1));
    await g.moveTo(centre(tester, 2));
    await g.moveTo(centre(tester, 11));
    await tester.pump();
    expect(selected(tester), {1, 2, 3, 9, 10, 11});
    // Back to 2: the rectangle shrinks to 1-2, the rest is released again.
    await g.moveTo(centre(tester, 2));
    await tester.pump();
    expect(selected(tester), {1, 2});
    await g.up();
    await tester.pump();
    expect(selected(tester), {1, 2});
  });

  testWidgets('starting on a selected tile deselects the rectangle', (tester) async {
    await open(tester);
    var g = await tester.startGesture(centre(tester, 1));
    await g.moveTo(centre(tester, 2));
    await g.moveTo(centre(tester, 19));
    await g.up();
    await tester.pump();
    expect(selected(tester), {1, 2, 3, 9, 10, 11, 17, 18, 19});
    g = await tester.startGesture(centre(tester, 10));
    await g.moveTo(centre(tester, 11));
    await g.moveTo(centre(tester, 19));
    await g.up();
    await tester.pump();
    expect(selected(tester), {1, 2, 3, 9, 17});
  });
}
