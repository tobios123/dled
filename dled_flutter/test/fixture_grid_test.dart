// The shared fixture grid (PATCH and EDIT): every slot can be selected,
// patched or not (the reference app allows recording unpatched slots too).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/widgets/fixture_grid.dart';

void main() {
  testWidgets('an unpatched slot can be selected', (tester) async {
    final selected = <int>{};
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: FixtureGrid(
            fixtures: const [],
            selected: selected,
            square: false,
            onToggle: (s) => setState(() => selected.contains(s) ? selected.remove(s) : selected.add(s)),
            onSet: (s, on) => setState(() => on ? selected.add(s) : selected.remove(s)),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('5'));
    await tester.pump();
    expect(selected, {4});
    await tester.tap(find.text('5'));
    await tester.pump();
    expect(selected, isEmpty);
  });

  testWidgets('EDIT colours: recorded patched red, empty never red, selected bold', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FixtureGrid(
          fixtures: [FixturePatch(id: 1, slot: 0, label: '', manufacturer: 'M', model: 'X')],
          selected: const {0, 5},
          recorded: const {0, 1, 2},
          square: false,
          onToggle: (_) {},
          onSet: (_, __) {},
        ),
      ),
    ));
    Border border(int slot) {
      final box = tester.widget<Container>(find
          .ancestor(of: find.text('${slot + 1}'), matching: find.byType(Container))
          .at(0));
      return (box.decoration! as BoxDecoration).border! as Border;
    }

    expect([border(0).top.color, border(0).top.width], [const Color(0xFFE02828), 3.5]); // recorded + selected
    expect([border(1).top.color, border(1).top.width], [Colors.white, 1.5]); // empty, recorded
    expect([border(5).top.color, border(5).top.width], [Colors.white, 3.5]); // empty, selected
    expect(border(9).top.width, 1); // nothing
  });

  test('overlapping DMX ranges collide (same universe only)', () {
    FixturePatch f(int slot, int address, int channels, {int universe = 0}) => FixturePatch(
        id: slot, slot: slot, model: 'X', address: address, channelCount: channels, universe: universe);
    expect(collidingSlots([f(0, 1, 6), f(1, 7, 6), f(2, 13, 6)]), isEmpty); // back to back
    expect(collidingSlots([f(0, 1, 6), f(1, 7, 6), f(56, 1, 30)]), {0, 1, 56}); // ADB on 1-30
    expect(collidingSlots([f(0, 1, 6), f(56, 1, 30, universe: 1)]), isEmpty);
  });

  test('an empty slot with only a name / address never collides', () {
    final par = FixturePatch(id: 1, slot: 0, model: 'Par', address: 1, channelCount: 6);
    final named = FixturePatch(id: 2, slot: 5, label: 'spare', address: 3, channelCount: 0);
    expect(named.isPatched, isFalse);
    expect(collidingSlots([par, named]), isEmpty);
  });
}
