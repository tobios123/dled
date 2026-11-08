// Fixtures in one cue can have different values and FX. Like the real LPU
// (2026-11-02, LOAD / RECORD on the LPU): LOAD + RECORD keeps the cue
// exactly; a changed attribute goes to every selected fixture, the others
// keep their own values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/screens/edit_screen.dart';
import 'package:dled/services/show_exporter.dart';
import 'package:dled/services/show_loader.dart';
import 'package:dled/widgets/edit_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late ShowModel model;
  late List<int> patched;

  /// The cue's 50-byte records per slot, as they go to the LPU.
  List<String> records(Cue c) {
    final blocks = coreCueFromModel(c, 0, patched).blocks;
    return [
      for (var s = 0; s < 64; s++)
        s ~/ 16 < blocks.length && blocks[s ~/ 16].length >= (s % 16 + 1) * 50
            ? base64Encode(blocks[s ~/ 16].sublist((s % 16) * 50, (s % 16 + 1) * 50))
            : ''
    ];
  }

  /// FX bytes (0..11) of every record.
  List<String> fxBytes(Cue c) => [for (final r in records(c)) r.isEmpty ? '' : base64Encode(base64Decode(r).sublist(0, 12))];

  (int, int) find1(bool Function(Cue c) test) {
    for (final (i, cl) in model.cuelists.indexed) {
      for (final (j, c) in cl.cues.indexed) {
        if (c.slots.length > 1 && test(c)) return (i, j);
      }
    }
    throw StateError('no such cue in m400.show');
  }

  Future<void> open(WidgetTester tester, int pb, Cue cue) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<ShowModel>.value(
        value: model, child: MaterialApp(home: EditScreen(cuelistIndex: pb))));
    await tester.pump();
    final tile = cue.label.isEmpty || cue.label == 'Cue ${cue.number}' ? '${cue.number}' : cue.label;
    await tester.tap(find.text(tile).first);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
  }

  void intensity(WidgetTester tester, double v) =>
      tester.widgetList<LedFader>(find.byType(LedFader)).firstWhere((f) => f.label == 'In').onChanged!(v);

  String colour(Cue c, int s) => [for (final a in ['R', 'G', 'B', 'A', 'W']) c.channels['$s:$a'] ?? 0].join(',');

  setUp(() {
    model = ShowModel();
    ShowLoader.loadFromString(File('test/core_data/shows/m400.show').readAsStringSync())!.applyToModel(model);
    patched = [for (final f in model.fixtures) if (f.isPatched) f.slot];
  });
  tearDown(() => model.vnService.stop());

  testWidgets('LOAD then RECORD keeps every fixture as it was', (tester) async {
    // red and yellow fixtures in one cue (m400 pb5 cue 1)
    final (pb, q) = find1((c) => {for (final s in c.slots) colour(c, s)}.length > 1);
    final cue = model.cuelists[pb].cues[q];
    final before = records(cue);
    await open(tester, pb, cue);
    await tap(tester, 'LOAD');
    model.showModified = false;
    await tap(tester, 'RECORD');
    expect(model.showModified, isTrue, reason: 'RECORD did not record');
    expect(records(cue), before);
  });

  testWidgets('a changed intensity goes to all, each keeps its colour', (tester) async {
    final (pb, q) = find1((c) => {for (final s in c.slots) colour(c, s)}.length > 1);
    final cue = model.cuelists[pb].cues[q];
    final colours = {for (final s in cue.slots) s: colour(cue, s)};
    await open(tester, pb, cue);
    await tap(tester, 'LOAD');
    intensity(tester, 127.5);
    await tester.pump();
    await tap(tester, 'RECORD');
    for (final s in cue.slots) {
      expect(cue.channels['$s:In'], closeTo(0.5, 1e-9), reason: 'slot ${s + 1}');
      expect(colour(cue, s), colours[s], reason: 'slot ${s + 1}');
    }
  });

  testWidgets('RECORD replaces the cue by the programmer, like the LPU', (tester) async {
    // LOAD cue 1, 2 fixtures blue, RECORD into cue 3: cue 3 = cue 1 with
    // those 2 blue; what cue 3 had besides is gone (the LPU, case D)
    final (pb, q) = find1((c) => {for (final s in c.slots) colour(c, s)}.length > 1);
    final cl = model.cuelists[pb];
    final src = cl.cues[q], dst = cl.cues[q + 2];
    dst.channels['38:In'] = 1.0; // a fixture only the target has
    dst.slots.add(38);
    final srcSlots = src.slots.toList()..sort();
    final colours = {for (final s in srcSlots) s: colour(src, s)};
    final pan = {for (final s in srcSlots) s: src.channels['$s:Pan']};
    await open(tester, pb, src);
    await tap(tester, 'LOAD');
    // keep only the first two fixtures selected (tap the others off)
    for (final s in srcSlots.skip(2)) {
      await tester.tap(find.text('${s + 1}').last);
      await tester.pump();
    }
    tester.widgetList<LedFader>(find.byType(LedFader)).firstWhere((f) => f.label == 'B').onChanged!(255);
    tester.widgetList<LedFader>(find.byType(LedFader)).firstWhere((f) => f.label == 'R').onChanged!(0);
    tester.widgetList<LedFader>(find.byType(LedFader)).firstWhere((f) => f.label == 'G').onChanged!(0);
    await tester.pump();
    // cue tiles toggle: cue 1 off, cue 3 on
    await tester.tap(find.text('${src.number}').first);
    await tester.tap(find.text('${dst.number}').first);
    await tester.pump();
    await tap(tester, 'RECORD');
    expect(dst.slots, srcSlots.toSet());
    for (final s in srcSlots) {
      expect(colour(dst, s), s == srcSlots[0] || s == srcSlots[1] ? '0.0,0.0,1.0,0.0,0.0' : colours[s], reason: 'slot ${s + 1}');
      expect(dst.channels['$s:Pan'], pan[s], reason: 'slot ${s + 1} pan');
    }
    expect(dst.channels.containsKey('38:In'), isFalse);
  });

  testWidgets('fixtures with their own FX keep them through an edit', (tester) async {
    final (pb, q) = find1((c) => c.slotFx.isNotEmpty);
    final cue = model.cuelists[pb].cues[q];
    final fx = fxBytes(cue);
    await open(tester, pb, cue);
    await tap(tester, 'LOAD');
    intensity(tester, 100);
    await tester.pump();
    await tap(tester, 'RECORD');
    expect(fxBytes(cue), fx);
  });
}
