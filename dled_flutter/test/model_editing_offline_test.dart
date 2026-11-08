// Offline (not connected) the model's editing methods change only the app's show.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ShowModel model() {
    final m = ShowModel();
    m.cuelists[0]
      ..label = 'A'
      ..goMode = GoMode.flash
      ..cues.addAll([Cue(number: 1), Cue(number: 2)]);
    m.cuelists[1].label = 'B';
    return m;
  }

  test('SWAP exchanges whole playbacks', () {
    final m = model();
    m.swapCuelists(0, 1);
    expect([m.cuelists[0].label, m.cuelists[0].cues.length, m.cuelists[0].goMode], ['B', 0, GoMode.go]);
    expect([m.cuelists[1].label, m.cuelists[1].cues.length, m.cuelists[1].goMode], ['A', 2, GoMode.flash]);
    expect([m.cuelists[0].id, m.cuelists[1].id], [1, 2]); // slots keep their number
  });

  test('a playback holds at most 48 cues', () {
    final m = model();
    while (m.cuelists[0].cues.length < ShowModel.maxCues) {
      expect(m.addCue(0), greaterThanOrEqualTo(0));
    }
    expect(m.addCue(0), -1);
    expect(m.cuelists[0].cues.length, 48);
  });

  test('add / remove cues, properties', () {
    final m = model();
    expect(m.addCue(0), 2);
    expect(m.cuelists[0].cues.last.label, 'Cue 3');
    m.removeCues(0, [0, 2]);
    expect(m.cuelists[0].cues.map((c) => c.number), [2]);
    m.setCuelistProps(m.cuelists[1].id, repeatMode: RepeatMode.random, background: true);
    expect([m.cuelists[1].repeatMode, m.cuelists[1].background, m.cuelists[1].goMode],
        [RepeatMode.random, true, GoMode.go]);
    expect(m.showModified, isTrue);
  });

  test('upload needs a connection', () async {
    expect(await model().uploadShowToLpu(), 'Not connected to an LPU.');
  });
}
