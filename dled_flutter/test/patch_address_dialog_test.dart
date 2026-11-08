// The patch screen's "SET START ADDRESS" dialog: DIP switches and digit arrows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/patch_screen.dart';

void main() {
  SharedPreferences.setMockInitialValues({});

  Future<ShowModel> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final model = ShowModel();
    model.addFixture(FixturePatch(id: 1, slot: 0, address: 29, channelCount: 5));
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: model, child: const MaterialApp(home: PatchScreen())));
    await tester.pump();
    await tester.tap(find.text('1').first); // select slot 1
    await tester.pump();
    await tester.tap(find.textContaining(RegExp('ADDRESS', caseSensitive: false)).first);
    await tester.pumpAndSettle();
    expect(find.text('SET START ADDRESS'), findsOneWidget);
    return model;
  }

  testWidgets('shows the address and its DIP switches', (tester) async {
    await openDialog(tester);
    expect(find.text('029'), findsOneWidget);
    // 29 = switches 1, 3, 4, 5: their "on" is lit (light background).
    final lit = tester
        .widgetList<Container>(find.ancestor(of: find.text('on'), matching: find.byType(Container)))
        .where((c) => c.color == const Color(0xFFBBBBBB))
        .length;
    expect(lit, 4);
  });

  testWidgets('arrows, DIP switch and Ok change the fixture address', (tester) async {
    final model = await openDialog(tester);
    await tester.tap(find.byIcon(Icons.arrow_drop_up).at(0)); // +100
    await tester.pump();
    expect(find.text('129'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_drop_down).at(2)); // -1
    await tester.pump();
    expect(find.text('128'), findsOneWidget);
    await tester.tap(find.text('2').last); // DIP switch 2 (+2)
    await tester.pump();
    expect(find.text('130'), findsOneWidget);
    await tester.tap(find.text('Ok'));
    await tester.pumpAndSettle();
    expect(model.fixtures.first.address, 130);
  });

  testWidgets('stays within 1-512 and Cancel changes nothing', (tester) async {
    final model = await openDialog(tester);
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byIcon(Icons.arrow_drop_up).at(0));
      await tester.pump();
    }
    expect(find.text('429'), findsOneWidget); // 529 would be past 512
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(model.fixtures.first.address, 29);
  });
}
