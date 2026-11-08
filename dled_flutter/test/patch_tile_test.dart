// Patch grid tiles: long manufacturer / model names wrap over several lines
// instead of being cut, and nothing overflows.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/patch_screen.dart';

void main() {
  SharedPreferences.setMockInitialValues({});

  testWidgets('long names wrap and stay readable', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final model = ShowModel();
    model.addFixture(FixturePatch(
        id: 1, slot: 0, address: 1, channelCount: 10,
        manufacturer: 'Erik Nelson Entertainment', model: 'Diamond beam 3R moving head', mode: 'Default'));
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: model, child: const MaterialApp(home: PatchScreen())));
    await tester.pump();
    // Full texts are shown (wrapped), not cut.
    expect(find.text('Erik Nelson Entertainment'), findsOneWidget);
    expect(find.text('Diamond beam 3R moving head'), findsOneWidget);
    final brand = tester.renderObject<RenderParagraph>(find.text('Erik Nelson Entertainment'));
    expect(brand.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull); // no overflow
  });
}
