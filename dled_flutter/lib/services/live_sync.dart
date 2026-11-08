// live_sync.dart -- apply what a connected LPU reports to the app model.
//
// Read-only (v0.5): the LPU is the truth for the show and the playback
// state; nothing here sends anything. Events come from core/lpu_session.dart
// through VnService.onLiveEvent. Pure Dart + model, so it also builds for web.

import '../core/lpu_live.dart';
import '../models/show_model.dart';
import 'show_loader.dart';

class LiveSync {
  /// Apply one event; [deviceIp] is the connected LPU (for device settings).
  static void apply(ShowModel model, LiveEvent e, {String? deviceIp}) {
    switch (e) {
      case ShowDownloaded():
        _download(model, e, deviceIp);
      case ActiveCue():
        model.setLiveActiveCue(e.playback, e.cue);
      case CuePhase():
        model.setLiveCuePhase(e.playback, e.phase);
      case FaderLevel():
        model.setLiveFaderLevel(e.playback, e.level);
      case KnobSpeed():
        model.setLiveRotaryLevel(e.playback, e.speed);
      case PlaybackUpdated():
        _playback(model, e);
      case CueUpdated():
        _cue(model, e);
      case FixtureUpdated():
        _fixture(model, e);
      case DeviceUpdated():
        _device(model, e.info, deviceIp);
      case ProgrammerValue():
        model.programmerValues.add((attr: e.attr, body: e.body));
      case ConnectionLost():
        model.liveConnected = false;
        _notify(model);
      default:
        break; // GoActive, CueCount, other notifications: state comes via the above
    }
  }

  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  static void _notify(ShowModel model) => model.notifyListeners();

  static Map<int, ShowFixture> _fixtureMap(ShowModel model) =>
      (model.liveFixtureMap as Map<int, ShowFixture>?) ?? {};

  // The slots with a personality (an empty slot with only a name counts as
  // empty).
  static Set<int> _patched(ShowModel model) =>
      {for (final f in model.fixtures) if (f.isPatched) f.slot};

  static void _download(ShowModel model, ShowDownloaded e, String? deviceIp) {
    // Like the reference app: connecting loads the LPU's show into the app.
    ShowLoader.fromShow(e.show).applyToModel(model);
    model.showFileName = 'LPU';
    for (final cl in model.cuelists) {
      // Slots the LPU did not list are at their defaults: fader full.
      cl.liveLevel = cl.hasLevel ? cl.level : 1.0;
      cl.liveSpeed = cl.speed;
    }
    e.states.forEach((pb, st) {
      model.setLiveActiveCue(pb, st.activeCue);
      model.setLiveCuePhase(pb, st.state); // tile colour: fading / holding / releasing
    });
    _device(model, e.info, deviceIp);
    model.liveConnected = true;
    _notify(model);
  }

  static void _playback(ShowModel model, PlaybackUpdated e) {
    if (e.index < 0 || e.index >= model.cuelists.length) return;
    final cl = model.cuelists[e.index];
    final pb = e.playback;
    if (pb == null) {
      ParsedShow.fillCuelist(cl, ShowPlayback(index: e.index, label: '', intensity: 1.0, cues: const []), null);
    } else {
      ParsedShow.fillCuelist(cl, ShowLoader.playbackFromCore(pb, _fixtureMap(model)), pb,
          patched: _patched(model));
    }
    cl.liveLevel = cl.level;
    cl.liveSpeed = cl.speed;
    model.setLiveActiveCue(e.index, e.state.activeCue);
    model.setLiveCuePhase(e.index, e.state.state);
  }

  static void _cue(ShowModel model, CueUpdated e) {
    if (e.playback < 0 || e.playback >= model.cuelists.length) return;
    final cl = model.cuelists[e.playback];
    final cue = ParsedShow.modelCue(ShowLoader.cueFromCore(e.cue, _fixtureMap(model)), e.cueIndex, e.cue,
        patched: _patched(model));
    if (e.cueIndex < cl.cues.length) {
      cl.cues[e.cueIndex] = cue;
    } else if (e.cueIndex == cl.cues.length) {
      cl.cues.add(cue);
    }
    _notify(model);
  }

  static void _fixture(ShowModel model, FixtureUpdated e) {
    model.fixtures.removeWhere((f) => f.slot == e.slot);
    final map = _fixtureMap(model);
    final f = e.fixture;
    if (f == null) {
      map.remove(e.slot);
    } else {
      final sf = ShowFixture.fromCore(f);
      final id = model.fixtures.fold<int>(0, (m, x) => x.id > m ? x.id : m) + 1;
      model.fixtures.add(ParsedShow.modelFixture(sf, id));
      map[e.slot] = sf;
    }
    model.liveFixtureMap = map;
    _notify(model);
  }

  static void _device(ShowModel model, LpuInfo info, String? deviceIp) {
    if (info.firmware.isNotEmpty) model.deviceInfo['firmware_version'] = info.firmware;
    if (info.mac.isNotEmpty) model.deviceInfo['mac'] = info.mac;
    for (final d in model.networkDevices) {
      if (d.ipAddress != deviceIp) continue;
      if (info.alias.isNotEmpty) d.shortName = info.alias;
      d.artNetEnabled = info.artNetEnabled;
      d.artNetUniverse = info.artNetUniverse;
      d.artNetRaw = info.artNetUniverseRaw;
      d.sacnEnabled = info.sacnEnabled;
      d.sacnUniverse = info.sacnUniverse;
      if (info.firmware.isNotEmpty) d.firmware = info.firmware;
      if (info.pcb.isNotEmpty) d.hardware = info.pcb;
    }
    _notify(model);
  }
}
