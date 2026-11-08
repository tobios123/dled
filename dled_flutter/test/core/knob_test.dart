// The speed knob's curve (core/knob.dart): fine around 0, the full range at
// the ends, the inverse gives the knob position back.

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/knob.dart';

void main() {
  test('ends and the middle', () {
    expect(speedFromKnob(0), 0);
    expect(speedFromKnob(1), closeTo(1, 1e-9));
    expect(speedFromKnob(-1), closeTo(-1, 1e-9));
    expect(speedFromKnob(knobDeadZone), 0); // the dead zone: exactly normal speed
    expect(speedFromKnob(-knobDeadZone / 2), 0);
  });

  test('fine around 0, coarse at the ends', () {
    expect(speedFromKnob(0.25), lessThan(0.1));
    expect(speedFromKnob(0.5), inInclusiveRange(0.15, 0.3));
    expect(speedFromKnob(-0.5), closeTo(-speedFromKnob(0.5), 1e-12));
    // the same knob movement changes the speed far less near 0 than at the end
    expect(speedFromKnob(0.2) - speedFromKnob(0.1), lessThan((speedFromKnob(1) - speedFromKnob(0.9)) / 5));
  });

  test('knobFromSpeed is the inverse', () {
    for (final k in [-1.0, -0.6, -0.2, -0.05, 0.0, 0.04, 0.3, 0.77, 1.0]) {
      expect(knobFromSpeed(speedFromKnob(k)), closeTo(k, 1e-9), reason: '$k');
    }
    expect(knobFromSpeed(0), 0);
    expect(knobFromSpeed(2), closeTo(1, 1e-9)); // clamped
  });
}
