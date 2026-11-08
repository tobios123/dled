// knob.dart -- the speed knob's curve, shared by the Flutter app and the
// light page: very fine around normal speed (0 %), coarse towards the ends.
//
// knob = the knob's position, -1 (left end) .. 0 (top) .. +1 (right end);
// speed = the playback speed the LPU gets, -1 .. +1 (-100 % .. +100 %).
// Exponential: speed = (e^(a x) - 1) / (e^a - 1) for x = 0..1 of the travel
// outside a small dead zone, mirrored for the other side. With a = 2.5:
//   knob 10 % -> speed ~2 %, 25 % -> ~7 %, 50 % -> ~21 %, 75 % -> ~48 %, 100 % -> 100 %.
// (a = 4 was too steep in use.)

import 'dart:math' as math;

/// Steepness: higher = finer around 0.
const double knobCurve = 2.5;

/// Knob positions within this of the top give exactly normal speed (0 %).
const double knobDeadZone = 0.03;

/// The speed for knob position [knob] (-1..1).
double speedFromKnob(double knob) {
  final k = knob.clamp(-1.0, 1.0), a = k.abs();
  if (a <= knobDeadZone) return 0;
  final x = (a - knobDeadZone) / (1 - knobDeadZone);
  final s = (math.exp(knobCurve * x) - 1) / (math.exp(knobCurve) - 1);
  return k < 0 ? -s : s;
}

/// Where the knob stands for [speed] (-1..1): the inverse of [speedFromKnob].
double knobFromSpeed(double speed) {
  final s = speed.clamp(-1.0, 1.0), a = s.abs();
  if (a == 0) return 0;
  final x = math.log(1 + a * (math.exp(knobCurve) - 1)) / knobCurve;
  final k = knobDeadZone + (1 - knobDeadZone) * x;
  return s < 0 ? -k : k;
}
