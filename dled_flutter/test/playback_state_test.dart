// Playback tile state (colours) and fader display, connected and offline.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/models/show_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ShowModel model() {
    final m = ShowModel();
    m.cuelists[0].cues.addAll([
      Cue(number: 1, fadeIn: 0.3, delay: 0.1),
      Cue(number: 2),
    ]);
    return m;
  }

  test('LPU cue phases: 2 fading (green), 3 holding (yellow), 4 releasing (orange), 1 released', () {
    final m = model();
    m.setLiveActiveCue(0, 0);
    m.setLiveCuePhase(0, 2);
    expect([m.cuelists[0].state, m.cuelists[0].fading], [PlaybackState.playing, true]);
    m.setLiveCuePhase(0, 3);
    expect([m.cuelists[0].state, m.cuelists[0].fading], [PlaybackState.playing, false]);
    m.setLiveCuePhase(0, 4);
    expect(m.cuelists[0].state, PlaybackState.releasing);
    m.setLiveCuePhase(0, 1);
    expect([m.cuelists[0].state, m.cuelists[0].fading], [PlaybackState.released, false]);
  });

  test('offline GO: green for delay + fade, then yellow; RELEASE: orange for the fade, then red', () async {
    final m = model();
    final cl = m.cuelists[0];
    m.goCuelist(cl.id);
    expect([cl.state, cl.fading], [PlaybackState.playing, true]);
    await Future.delayed(const Duration(milliseconds: 600));
    expect([cl.state, cl.fading], [PlaybackState.playing, false]);
    m.releaseCuelist(cl.id);
    expect(cl.state, PlaybackState.releasing);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(cl.state, PlaybackState.released);
  });

  test('a cue without fade releases at once (no orange)', () {
    final m = model();
    final cl = m.cuelists[0];
    m.goCuelist(cl.id);
    m.goCuelist(cl.id); // cue 2: no fade, no delay
    expect(cl.fading, isFalse);
    m.releaseCuelist(cl.id);
    expect(cl.state, PlaybackState.released);
  });

  test('offline faders start full; RELEASE and SOLO do not move them', () {
    final m = model();
    final cl = m.cuelists[0];
    expect(m.shownLevel(cl), 1.0);
    m.setPlaybackLevel(0, 0.4);
    expect(m.shownLevel(cl), closeTo(0.4, 1e-9));
    m.goCuelist(cl.id);
    m.releaseCuelist(cl.id);
    expect(m.shownLevel(cl), closeTo(0.4, 1e-9));
  });

  test('moving the fader / knob marks the change for the tile display', () {
    final m = model();
    final cl = m.cuelists[0];
    expect([cl.levelChangedAt, cl.speedChangedAt], [null, null]);
    m.setPlaybackLevel(0, 0.5);
    expect(cl.levelChangedAt, isNotNull);
    m.setPlaybackSpeed(0, -0.8);
    expect([cl.speedChangedAt, cl.liveSpeed], [isNotNull, closeTo(-0.8, 1e-9)]);
    m.setLiveFaderLevel(1, 0.2); // from the LPU
    expect(m.cuelists[1].levelChangedAt, isNotNull);
  });
}
