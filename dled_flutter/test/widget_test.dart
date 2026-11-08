import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/main.dart';
import 'package:dled/models/show_model.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // Landscape tablet size, like the real device.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // main() wraps the app in the model provider; do the same here.
    final model = ShowModel();
    await tester.pumpWidget(ChangeNotifierProvider.value(value: model, child: const DLEDApp()));
    await tester.pump(const Duration(seconds: 2));
    // App should load without throwing
    expect(find.byType(DLEDApp), findsOneWidget);
    // Unmount and stop the VN service: its discovery timer starts after an
    // async socket bind, so it can outlive the app's own dispose() in a test.
    await tester.pumpWidget(const SizedBox());
    model.vnService.stop();
    await tester.pump(const Duration(seconds: 5));
  });
}
