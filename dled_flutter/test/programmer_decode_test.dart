// The EDIT page follows the LPU's programmer: decodeProgrammer reads back
// exactly what sliderWrites / fxWrite send (any app's change looks the same).

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/programmer.dart';

void main() {
  test('sliders come back as they were sent', () {
    final attrs = {'In': 200.0, 'R': 255.0, 'G': 128.0, 'B': 0.0, 'A': 10.0, 'W': 20.0, 'Col': 77.0, 'Custom2': 144.0};
    final writes = sliderWrites(attrs, 60, 191, ['In', 'R', 'Pan', 'Col', 'Custom2']);
    final back = <String, double>{};
    for (final w in writes) {
      back.addAll(decodeProgrammer(w.attr, w.body)!.sliders);
    }
    for (final k in ['In', 'R', 'G', 'B', 'A', 'W', 'Col', 'Custom2']) {
      expect(back[k], closeTo(attrs[k]!, 0.6), reason: k);
    }
    expect(back['Pan'], closeTo(60, 0.6));
    expect(back['Tilt'], closeTo(191, 0.6));
  });

  test('an FX generator comes back as it was sent', () {
    final w = fxWrite('position', CueFxSlot(waveform: 'Eight', size: 80, speed: 20, phase: 50));
    final d = decodeProgrammer(w.attr, w.body)!.fx!;
    expect(d.generator, 'position');
    expect(d.fx.waveform, 'Eight');
    expect(d.fx.size, closeTo(80, 0.5));
    expect(d.fx.speed, closeTo(20, 0.6));
    expect(d.fx.phase, closeTo(50, 0.5));
  });
}
