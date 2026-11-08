// api.dart -- DLED's shared Dart logic (lib/core + services/vn_service.dart,
// the same code the Flutter app uses) as a small JavaScript library for the
// light page: `window.dled`. Built by tool/build_light.dart into core.js.
//
// The page draws; this keeps the state. Every change to the protocol or the
// LPU handling is made once in Dart and reaches both the Flutter app and the
// light page (PARITY.md lists what the page itself still has to follow).
//
//   dled.start()                  discovery + automatic connecting
//   dled.onChange(fn)             fn() after state changes (batched)
//   dled.state()                  JSON string, see _state()
//   dled.go(pb) / release(pb) / releaseAll()
//   dled.flash(pb, down)          FLASH pressed (true) / let go (false)
//   dled.fader(pb, 0..1)          playback intensity
//   dled.speed(pb, -1..1)         playback speed (knob)
//   dled.knobToSpeed(-1..1) / speedToKnob(-1..1)
//                                  the knob's curve (core/knob.dart)
//   dled.rename(pb, name)         RENAME PLAYBACK
//   dled.swap(a, b)               SWAP two whole playbacks
//   dled.props(pb, goMode, repeat, background, exclusive)
//                                  PLAYBACK PROPERTIES; null = unchanged
//   dled.connect(ip) / deselect() choose / drop the LPU (OPTIONS)
//   dled.deviceName(name) / artNet(on, raw) / sacn(on, universe)
//   dled.network(dhcp, ip, mask)  IP ADDRESS; false = invalid, nothing sent
//   dled.showText()               the LPU's show as .show text (SAVE)
//   dled.emptyShowText()          an empty show (NEW)
//   dled.checkShow(text)          true when it is a .show file (IMPORT)
//   dled.openShow(text, progress(fraction, step), aborted())
//                                  OPEN: send it to the LPU; Promise of a message
// PATCH (written to the LPU at once, read back):
//   dled.personality(slots[], manufacturer, model, mode, profileHex)
//                                  patch; addresses: free channels (core/patch.dart)
//   dled.renameFixtures(slots[], name) / addressFixtures(slots[], start)
//   dled.flag(slots[], 'p'|'t'|'s'|'d')   INVERT PAN / TILT, SWAP, VIRTUAL DIMMER
//   dled.clearFixtures(slots[])
// EDIT (screens/edit_screen.dart; state().edit, null when closed; the LPU's
// programmer follows it live and it follows the programmer):
//   dled.editOpen(pb) / editClose()
//   dled.editCue(q)               (de)select a cue
//   dled.editSelect(slots[])      the selected fixtures
//   dled.editSlider(key, 0..255) / editPosition(pan, tilt) / editRgb(r, g, b)
//   dled.editFx(generator, waveform, size, speed, phase, keep)
//                                  live; keep = Ok (Cancel sends the kept one)
//   dled.editAdd() / editRemove() / editRename(name) / editCondition()
//   dled.editFade(text) / editDelay(text)   false = not a time
//   dled.editLoad() / editRecord() / editClear() / editClearAll()
// POSITIONS (screens/positions_screen.dart; state().positions, the stored
// tiles; kept per show file next to it, options.js):
//   dled.positionsLoad(text) / positionsText()   '' = none
//   dled.positionStore(tile)      the selected fixtures' own pan / tilt; false = none
//   dled.positionRecall(tile, withFixtures)       pan / tilt per fixture
//   dled.positionRename(tile, name) / positionDelete(tile) / positionSwap(a, b)
// pb = playback 0..63, slot = fixture 0..63. The chosen LPU is remembered in
// the browser.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dled/core/cue_codec.dart';
import 'package:dled/core/fixture_codes.dart';
import 'package:dled/core/knob.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/core/lpu_live.dart';
import 'package:dled/core/net.dart';
import 'package:dled/core/patch.dart';
import 'package:dled/core/show_file.dart';
import 'package:dled/models/position_store.dart';
import 'package:dled/services/vn_service.dart';
import 'package:web/web.dart' as web;

/// One playback as the PLAYBACK page shows it.
class _Pb {
  String label = '';
  int cues = 0;
  int? active; // cue index, null = released
  String state = 'released'; // released / playing / releasing
  bool fading = false; // a cue is running its fade / delay
  double level = 1.0; // fader 0..1
  double speed = 0.0; // knob -1..1
  String goMode = 'Go', repeat = 'Loop';
  bool background = false, exclusive = false;

  void clear() {
    label = '';
    cues = 0;
    active = null;
    state = 'released';
    fading = false;
    level = 1.0;
    speed = 0.0;
    goMode = 'Go';
    repeat = 'Loop';
    background = false;
    exclusive = false;
  }

  void fromShow(ShowPlayback p) {
    label = p.label;
    cues = p.cues.length;
    level = p.intensity.clamp(0.0, 1.0);
    speed = p.speed.clamp(-1.0, 1.0);
    goMode = p.goMode;
    repeat = p.repeat;
    background = p.background;
    exclusive = p.exclusive;
  }

  // Active cue pushed by the LPU: null = released (as ShowModel does it).
  void activeCue(int? cue) {
    active = cue;
    state = cue == null ? 'released' : 'playing';
  }

  // Cue phase pushed by the LPU: 0 no cues, 1 released, 2 running with a
  // timer, 3 holding, 4 releasing (as ShowModel.setLiveCuePhase).
  void phase(int p) {
    fading = p == 2;
    switch (p) {
      case 4:
        state = 'releasing';
      case 0 || 1:
        state = 'released';
      case 2 || 3:
        if (state == 'releasing') state = 'playing';
    }
  }

  Map<String, Object?> toJson() => {
        'l': label, 'n': cues, 'a': active, 's': state, 'f': fading, 'v': level, 'sp': speed, //
        'g': goMode, 'r': repeat, 'bg': background, 'ex': exclusive,
      };
}

final VnService _vn = VnService();
final List<_Pb> _pbs = List.generate(64, (_) => _Pb());
final Map<int, ShowFixture> _fixtures = {}; // slot -> fixture (for the collision lock)
Show? _show; // the LPU's show, kept up to date from its live messages (SAVE, Abort)
LpuInfo? _info; // the connected LPU's settings

bool _patched(ShowFixture f) => f.manufacturer.isNotEmpty || f.model.isNotEmpty || f.profile.isNotEmpty;

/// Patched fixtures that share DMX channels (red address in PATCH; playback
/// and EDIT are locked) - core/patch.dart.
Set<int> get _collisions => overlappingRanges([
      for (final f in _fixtures.values)
        if (_patched(f)) (key: f.index, start: f.address, count: profileChannels(f.profile).clamp(1, 512), universe: 0)
    ]);
bool get _locked => _collisions.isNotEmpty;

List<int> _slots(JSArray<JSNumber> a) => [for (final n in a.toDart) n.toDartInt]..sort();

/// The slot's fixture, or a new empty entry (name / address only).
ShowFixture _entry(int slot) => _fixtures[slot] ?? ShowFixture(index: slot, address: 1);
JSFunction? _listener;
bool _pending = false;

void _changed() {
  if (_pending) return;
  _pending = true;
  scheduleMicrotask(() {
    _pending = false;
    _listener?.callAsFunction();
  });
}

void _state(PlaybackStatus st, _Pb p) {
  p.cues = st.cues > 0 ? st.cues : p.cues;
  p.activeCue(st.activeCue);
  p.phase(st.state);
}

void _onLive(LiveEvent e) {
  switch (e) {
    case ShowDownloaded():
      for (final p in _pbs) {
        p.clear();
      }
      _fixtures
        ..clear()
        ..addEntries(e.show.fixtures.map((f) => MapEntry(f.index, f)));
      _show = e.show;
      _info = e.info;
      for (final p in e.show.playbacks) {
        if (p.index < 0 || p.index >= 64) continue;
        _pbs[p.index].fromShow(p);
        final st = e.states[p.index];
        if (st != null) _state(st, _pbs[p.index]);
      }
    case PlaybackUpdated():
      if (e.index < 0 || e.index >= 64) return;
      _show?.playbacks.removeWhere((x) => x.index == e.index);
      if (e.playback != null) _show?.playbacks.add(e.playback!);
      _show?.playbacks.sort((a, b) => a.index.compareTo(b.index));
      final p = _pbs[e.index];
      if (e.playback == null) {
        p.clear();
      } else {
        p.fromShow(e.playback!);
        _state(e.state, p);
      }
    case FixtureUpdated():
      if (e.fixture == null) {
        _fixtures.remove(e.slot);
      } else {
        _fixtures[e.slot] = e.fixture!;
      }
      _show?.fixtures
        ?..removeWhere((x) => x.index == e.slot)
        ..addAll([if (e.fixture != null) e.fixture!])
        ..sort((a, b) => a.index.compareTo(b.index));
    case CueUpdated():
      final pb = _show?.playbacks.where((x) => x.index == e.playback).firstOrNull;
      if (pb != null) {
        if (e.cueIndex < pb.cues.length) {
          pb.cues[e.cueIndex] = e.cue;
        } else if (e.cueIndex == pb.cues.length) {
          pb.cues.add(e.cue);
        }
      }
    case DeviceUpdated():
      _info = e.info;
    case ActiveCue():
      if (e.playback >= 0 && e.playback < 64) _pbs[e.playback].activeCue(e.cue);
    case CuePhase():
      if (e.playback >= 0 && e.playback < 64) _pbs[e.playback].phase(e.phase);
    case FaderLevel():
      if (e.playback >= 0 && e.playback < 64) _pbs[e.playback].level = e.level.clamp(0.0, 1.0);
    case KnobSpeed():
      if (e.playback >= 0 && e.playback < 64) _pbs[e.playback].speed = e.speed.clamp(-1.0, 1.0);
    case CueCount():
      if (e.playback >= 0 && e.playback < 64) _pbs[e.playback].cues = e.count;
      // deleted cues: the LPU only reports the new count
      final pb = _show?.playbacks.where((x) => x.index == e.playback).firstOrNull;
      if (pb != null && pb.cues.length > e.count) pb.cues.removeRange(e.count, pb.cues.length);
    case ProgrammerValue():
      _onProgrammer(e);
    default:
      return;
  }
  _changed();
}

String _stateJson() {
  final c = _vn.connected;
  return jsonEncode({
    'connected': c == null ? null : {'label': c.label, 'ip': c.ip, 'version': c.version},
    'connecting': _vn.connecting?.ip, // the LPU being connected (show download), or null
    'devices': [
      for (final d in _vn.devices) {'label': d.label, 'ip': d.ip, 'version': d.version}
    ],
    'locked': _locked,
    'fixtures': [
      for (final f in _fixtures.values)
        {
          'slot': f.index, 'name': f.name, 'mfr': f.manufacturer, 'model': f.model, 'mode': f.mode, //
          'address': f.address, 'ch': profileChannels(f.profile), 'patched': _patched(f),
          'p': f.invertPan, 't': f.invertTilt, 's': f.swapPanTilt, 'd': f.virtualDimmer,
        }
    ],
    'collisions': _collisions.toList(),
    'info': _info == null
        ? null
        : {
            'alias': _info!.alias, 'firmware': _info!.firmware, 'pcb': _info!.pcb, 'subnet': _info!.subnet, //
            'artNet': _info!.artNetEnabled, 'artNetRaw': _info!.artNetUniverseRaw,
            'sacn': _info!.sacnEnabled, 'sacnUniverse': _info!.sacnUniverse,
          },
    'pb': [for (final p in _pbs) p.toJson()],
    'edit': _editJson(),
    'positions': [
      for (final t in _positions.positions.keys.toList()..sort())
        {
          'tile': t, 'name': _positions[t]!.name, 'slots': (_positions[t]!.fixtures.keys.toList()..sort()), //
          'match': _positions[t]!.fixtures.values.any((f) {
            final x = _fixtures[f.slot];
            return x != null && _patched(x) && x.model == f.model;
          }),
        }
    ],
  });
}

bool _ok(int pb) => pb >= 0 && pb < 64;

// --- EDIT (screens/edit_screen.dart) -------------------------------------------

const _sliderKeys = [
  'R', 'G', 'B', 'A', 'W', 'UV', 'In', 'Sh', 'Col', 'Go', //
  'Rota', 'Prism', 'Iris', 'Focus', 'Zoom', 'Frost', 'Custom', 'Custom2',
];

class _Edit {
  final int pb;
  _Edit(this.pb);
  final Set<int> cues = {}; // selected cue indices
  int loaded = -1; // the loaded (LOAD / RECORD) cue: its fixtures are red
  final Set<int> fixtures = {};
  // The programmer per fixture, as cue records: LOAD copies the cue's, a
  // change goes to the selected ones, RECORD makes the cue of them (the LPU,
  // 2026-11-02, lpd/DMX_ENGINE.md 12).
  final Map<int, Uint8List> recs = {};
  final Map<String, double> attrs = {for (final k in _sliderKeys) k: 0};
  double pan = 128, tilt = 128;
  final List<FxValues> fx = [noFx, noFx, noFx]; // intensity, position, colour
  final Map<int, DateTime> sentAt = {}; // programmer attr -> our last write
  DateTime quietUntil = DateTime(0); // after LOAD: its values are set here
}

_Edit? _edit;

ShowPlayback? _editPb() {
  final e = _edit;
  if (e == null || _show == null) return null;
  return _show!.playbacks.where((p) => p.index == e.pb).firstOrNull;
}

List<ShowCue> _editCues() => _editPb()?.cues ?? const [];

ShowCue? _selectedCue() {
  final e = _edit!, cues = _editCues();
  if (e.cues.length != 1) return null;
  final q = e.cues.first;
  return q < cues.length ? cues[q] : null;
}

bool _cueHasData(ShowCue c) => c.blocks.any((b) => b.any((x) => x != 0));

/// The channels the selected patched fixtures have (all for a patched
/// fixture without a known profile); empty slots add none.
Set<String> _enabled() {
  final e = _edit!;
  final out = <String>{};
  for (final s in e.fixtures) {
    final f = _fixtures[s];
    if (f == null || !_patched(f)) continue;
    final codes = f.codes;
    if (codes.isEmpty) return {..._sliderKeys, 'Pan', 'Tilt'};
    for (final c in codes) {
      final a = attrForCode(c);
      if (a != null) out.add(a);
    }
  }
  return out;
}

/// The sliders show the highest value of the selected fixtures (from LOAD).
void _recalcMerged() {
  final e = _edit!;
  for (final k in e.attrs.keys) {
    e.attrs[k] = 0;
  }
  double? pan, tilt;
  for (final s in e.fixtures) {
    final r = e.recs[s];
    if (r == null) continue;
    for (final k in kAttrRecordOffset.keys) {
      if (recordU16(r, 0, kAttrRecordOffset[k]!) == 0) continue; // not set (pan / tilt: the centre)
      final v = recordDmx(r, 0, k) / 65535 * 255;
      if (k == 'Pan') {
        if (pan == null || v > pan) pan = v;
      } else if (k == 'Tilt') {
        if (tilt == null || v > tilt) tilt = v;
      } else if (v > (e.attrs[k] ?? 0)) {
        e.attrs[k] = v;
      }
    }
  }
  e.pan = pan ?? 128;
  e.tilt = tilt ?? 128;
}

/// A change goes to every selected fixture, the others keep their own
/// values (the colour is R G B A W at once, the position pan and tilt).
void _touch(Iterable<String> keys) {
  final e = _edit!;
  final all = {...keys};
  if (all.any(colourKeys.contains)) all.addAll(colourKeys);
  if (all.contains('Pan') || all.contains('Tilt')) all.addAll(const ['Pan', 'Tilt']);
  for (final s in e.fixtures) {
    final r = e.recs[s] ??= Uint8List(recordSize);
    for (final k in all) {
      if (!kAttrRecordOffset.containsKey(k)) continue; // UV: no record slot
      final v = k == 'Pan' ? e.pan : (k == 'Tilt' ? e.tilt : e.attrs[k] ?? 0);
      setRecordDmx(r, 0, k, (v / 255 * 65535).round());
    }
  }
}

void _touchFx(int g) {
  final e = _edit!;
  const offsets = [kFxIntensityOffset, kFxPositionOffset, kFxColourOffset];
  for (final s in e.fixtures) {
    (e.recs[s] ??= Uint8List(recordSize)).setRange(offsets[g], offsets[g] + 4, fxBytes(fxGenerators[g], e.fx[g]));
  }
}

void _sendWrites(List<ProgrammerWrite> writes) {
  final e = _edit!, now = DateTime.now();
  for (final w in writes) {
    e.sentAt[w.attr] = now;
    _vn.setProgrammer(w.attr, w.type, w.body);
  }
}

void _sendSliders(Iterable<String> keys) {
  final e = _edit!;
  _sendWrites(sliderWrites(e.attrs, e.pan, e.tilt, keys));
}

/// The LPU's programmer changed (any app, or a LOAD): follow it, except the
/// echo of our own writes for a moment (a slider being dragged).
void _onProgrammer(ProgrammerValue v) {
  final e = _edit;
  if (e == null) return;
  // a CLEAR just before a LOAD echoes late (zeros): LOAD has set the values
  if (DateTime.now().isBefore(e.quietUntil)) return;
  final sent = e.sentAt[v.attr];
  if (sent != null && DateTime.now().difference(sent) < const Duration(milliseconds: 600)) return;
  final d = decodeProgrammer(v.attr, Uint8List.fromList(v.body));
  if (d == null) return;
  d.sliders.forEach((k, value) {
    if (k == 'Pan') {
      e.pan = value;
    } else if (k == 'Tilt') {
      e.tilt = value;
    } else {
      e.attrs[k] = value;
    }
  });
  _touch(d.sliders.keys);
  final fx = d.fx;
  if (fx != null) {
    e.fx[fxGenerators.indexOf(fx.generator)] = fx.fx;
    _touchFx(fxGenerators.indexOf(fx.generator));
  }
}

/// Write cue [q] of the edited playback to the LPU (and keep it here).
void _writeCue(int q, ShowCue c) {
  final pb = _editPb();
  if (pb == null || q >= pb.cues.length) return;
  pb.cues[q] = c;
  _vn.writeCue(_edit!.pb, q, c);
}

ShowCue _copyCue(ShowCue c, {String? label, int? fadeMs, int? delayMs, bool? follow, List<Uint8List>? blocks}) =>
    ShowCue(
        label: label ?? c.label,
        fadeMs: fadeMs ?? c.fadeMs,
        delayMs: delayMs ?? c.delayMs,
        follow: follow ?? c.follow,
        blocks: blocks ?? c.blocks,
        extraAttrs: c.extraAttrs);

/// A time typed like the reference app shows it ("2.5s", "3", "1,5 s"), or null.
double? _seconds(String s) {
  final v = double.tryParse(s.toLowerCase().replaceAll('s', '').replaceAll(',', '.').trim());
  return v == null || v < 0 ? null : v;
}

String _secondsText(int ms) {
  final s = ms / 1000;
  return '${s == s.roundToDouble() ? s.round() : s.toStringAsFixed(1)}s';
}

Map<String, Object?>? _editJson() {
  final e = _edit;
  if (e == null) return null;
  final cues = _editCues();
  final loaded = e.loaded >= 0 && e.loaded < cues.length ? decodeCue(cues[e.loaded]) : null;
  Map<String, Object> fx(FxValues f) => {'w': f.waveform, 'size': f.size, 'speed': f.speed, 'phase': f.phase};
  return {
    'pb': e.pb,
    'cues': [
      for (final (q, c) in cues.indexed)
        {
          'n': c.label.isEmpty ? '${q + 1}' : c.label, 'delay': _secondsText(c.delayMs), //
          'fade': _secondsText(c.fadeMs), 'follow': c.follow, 'rec': _cueHasData(c),
        }
    ],
    'sel': (e.cues.toList()..sort()),
    'loaded': loaded == null ? -1 : e.loaded,
    'recorded': loaded == null ? const <int>[] : (loaded.slots.toList()..sort()),
    'loadedFx': loaded == null ? const [false, false, false] : [for (final f in loaded.fx) f.waveform != 'None'],
    'fixtures': (e.fixtures.toList()..sort()),
    'attrs': e.attrs,
    'pan': e.pan,
    'tilt': e.tilt,
    'fx': [for (final f in e.fx) fx(f)],
    'enabled': _enabled().toList(),
    'storable': _storable().isNotEmpty, // POSITIONS > STORE has fixtures to store
  };
}

// --- POSITIONS (screens/positions_screen.dart, models/position_store.dart) ---

final PositionStore _positions = PositionStore();

bool _hasPanTilt(ShowFixture f) =>
    f.codes.isEmpty || f.codes.any((c) => const {'Pan', 'Tilt'}.contains(attrForCode(c)));

/// What STORE stores: every selected patched fixture with pan / tilt that has
/// its own position in the programmer (like the app's EDIT).
List<StoredFixture> _storable() {
  final e = _edit;
  if (e == null) return const [];
  final out = <StoredFixture>[];
  for (final s in e.fixtures.toList()..sort()) {
    final f = _fixtures[s], r = e.recs[s];
    if (f == null || !_patched(f) || !_hasPanTilt(f) || r == null) continue;
    if (recordU16(r, 0, kAttrRecordOffset['Pan']!) == 0 && recordU16(r, 0, kAttrRecordOffset['Tilt']!) == 0) continue;
    out.add(StoredFixture(
        slot: s,
        manufacturer: f.manufacturer,
        model: f.model,
        mode: f.mode,
        name: f.name,
        pan: recordDmx(r, 0, 'Pan'),
        tilt: recordDmx(r, 0, 'Tilt')));
  }
  return out;
}

/// Recall: only pan / tilt change, per fixture (SELECTED: the selected ones in
/// it; WITH FIXTURES: the selection becomes its fixtures). On the LPU one
/// fixture at a time (VnService.programmerPositions).
void _recall(StoredPosition p, bool withFixtures) {
  final e = _edit;
  if (e == null) return;
  final targets = withFixtures
      ? (p.fixtures.keys.toList()..sort())
      : [for (final s in e.fixtures.toList()..sort()) if (p.fixtures.containsKey(s)) s];
  if (targets.isEmpty) return;
  if (withFixtures) {
    e.fixtures
      ..clear()
      ..addAll(targets);
  }
  final bodies = <int, Uint8List>{};
  for (final s in targets) {
    final f = p.fixtures[s]!;
    final r = e.recs[s] ??= Uint8List(recordSize);
    setRecordDmx(r, 0, 'Pan', f.pan);
    setRecordDmx(r, 0, 'Tilt', f.tilt);
    bodies[s] = sliderWrites(const {}, f.editPan, f.editTilt, const ['Pan']).single.body;
  }
  _recalcMerged();
  final now = DateTime.now();
  e.sentAt[2] = now; // the echoes are no change
  e.quietUntil = now.add(const Duration(seconds: 1));
  _vn.programmerPositions(bodies, e.fixtures);
}

void _positionsApi(void Function(String, JSFunction) fn) {
  fn('positionsLoad', ((String? text) {
    text == null || text.isEmpty ? _positions.clear() : _positions.decode(text);
    _changed();
  }).toJS);
  fn('positionsText', (() => (_positions.isEmpty ? '' : _positions.encode()).toJS).toJS);
  fn('positionStore', ((int tile) {
    final ok = _positions.store(tile, _storable());
    if (ok) _changed();
    return ok.toJS;
  }).toJS);
  fn('positionRecall', ((int tile, bool withFixtures) {
    final p = _positions[tile];
    if (p == null) return;
    _recall(p, withFixtures);
    _changed();
  }).toJS);
  fn('positionRename', ((int tile, String name) {
    if (_positions.rename(tile, name)) _changed();
  }).toJS);
  fn('positionDelete', ((int tile) {
    if (_positions.delete(tile)) _changed();
  }).toJS);
  fn('positionSwap', ((int a, int b) {
    if (_positions.swap(a, b)) _changed();
  }).toJS);
}

void _editApi(void Function(String, JSFunction) fn) {
  fn('editOpen', ((int pb) {
    if (!_ok(pb)) return;
    _edit = _Edit(pb);
    _vn.setEditing(true); // like the reference app (2c 02 35 = 0)
    _changed();
  }).toJS);
  fn('editClose', () {
    if (_edit == null) return;
    _edit = null;
    _vn.setEditing(false); // the programmer keeps its values
    _changed();
  }.toJS);
  fn('editCue', ((int q) {
    final e = _edit;
    if (e == null) return;
    e.cues.contains(q) ? e.cues.remove(q) : e.cues.add(q);
    _changed();
  }).toJS);
  fn('editSelect', ((JSArray<JSNumber> slots) {
    final e = _edit;
    if (e == null) return;
    e.fixtures
      ..clear()
      ..addAll(_slots(slots).where((s) => s >= 0 && s < 64));
    _recalcMerged();
    // the values the LPU reports for the new selection are no change
    e.quietUntil = DateTime.now().add(const Duration(seconds: 1));
    _vn.selectFixtures(e.fixtures);
    _changed();
  }).toJS);
  fn('editSlider', ((String key, double v) {
    final e = _edit;
    if (e == null) return;
    e.attrs[key] = v.clamp(0.0, 255.0);
    _touch([key]);
    _sendSliders([key]);
    _changed();
  }).toJS);
  fn('editPosition', ((double pan, double tilt) {
    final e = _edit;
    if (e == null) return;
    e.pan = pan.clamp(0.0, 255.0);
    e.tilt = tilt.clamp(0.0, 255.0);
    _touch(const ['Pan']);
    _sendSliders(const ['Pan']);
    _changed();
  }).toJS);
  fn('editRgb', ((double r, double g, double b) {
    final e = _edit;
    if (e == null) return;
    e.attrs['R'] = r.clamp(0.0, 255.0);
    e.attrs['G'] = g.clamp(0.0, 255.0);
    e.attrs['B'] = b.clamp(0.0, 255.0);
    _touch(colourKeys);
    _sendSliders(const ['R', 'G', 'B']);
    _changed();
  }).toJS);
  fn('editFx', ((String generator, String waveform, double size, double speed, double phase, bool keep) {
    final e = _edit;
    final g = fxGenerators.indexOf(generator);
    if (e == null || g < 0) return;
    final f = (waveform: waveform, size: size, speed: speed, phase: phase);
    if (keep) {
      e.fx[g] = f;
      _touchFx(g);
    }
    _sendWrites([fxWrite(generator, f)]);
    _changed();
  }).toJS);
  fn('editAdd', () {
    final e = _edit;
    if (e == null || _show == null) return;
    var pb = _editPb();
    if (pb == null) {
      pb = ShowPlayback(index: e.pb);
      _show!.playbacks
        ..add(pb)
        ..sort((a, b) => a.index.compareTo(b.index));
    }
    if (pb.cues.length >= 48) return;
    // An empty playback gets its first cue like the upload allocates it; else
    // the LPU copies the previous cue's settings (FINDINGS 20.2).
    if (pb.cues.isEmpty) {
      _vn.allocateCues(e.pb, 1);
      pb.cues.add(ShowCue());
    } else {
      _vn.insertCue(e.pb, pb.cues.length);
      final last = pb.cues.last;
      pb.cues.add(ShowCue(fadeMs: last.fadeMs, delayMs: last.delayMs, follow: last.follow));
    }
    _pbs[e.pb].cues = pb.cues.length;
    e.cues
      ..clear()
      ..add(pb.cues.length - 1);
    _changed();
  }.toJS);
  fn('editRemove', () {
    final e = _edit;
    final pb = _editPb();
    if (e == null || pb == null || e.cues.isEmpty) return;
    final sorted = e.cues.where((q) => q < pb.cues.length).toList()..sort((a, b) => b.compareTo(a));
    if (sorted.isEmpty) return;
    for (final q in sorted) {
      pb.cues.removeAt(q);
    }
    // contiguous runs, from the end so earlier indices stay valid
    var k = 0;
    while (k < sorted.length) {
      var first = sorted[k], count = 1;
      while (k + count < sorted.length && sorted[k + count] == first - 1) {
        first--;
        count++;
      }
      _vn.deleteCues(e.pb, first, count);
      k += count;
    }
    if (sorted.contains(e.loaded)) e.loaded = -1;
    final min = sorted.last;
    e.cues.clear();
    if (min < pb.cues.length) {
      e.cues.add(min);
    } else if (pb.cues.isNotEmpty) {
      e.cues.add(pb.cues.length - 1);
    }
    _pbs[e.pb].cues = pb.cues.length;
    _changed();
  }.toJS);
  fn('editRename', ((String name) {
    final e = _edit;
    final c = e == null ? null : _selectedCue();
    if (e == null || c == null) return;
    final number = '${e.cues.first + 1}';
    _writeCue(e.cues.first, _copyCue(c, label: name.trim() == number ? '' : name.trim()));
    _changed();
  }).toJS);
  fn('editCondition', () {
    final e = _edit;
    if (e == null) return;
    final cues = _editCues();
    for (final q in e.cues) {
      if (q < cues.length) _writeCue(q, _copyCue(cues[q], follow: !cues[q].follow));
    }
    _changed();
  }.toJS);
  void time(String name, ShowCue Function(ShowCue c, int ms) apply) => fn(
      name,
      ((String text) {
        final e = _edit, v = _seconds(text);
        if (e == null || v == null) return false.toJS;
        final cues = _editCues();
        for (final q in e.cues) {
          if (q < cues.length) _writeCue(q, apply(cues[q], (v * 1000).round()));
        }
        _changed();
        return true.toJS;
      }).toJS);
  time('editFade', (c, ms) => _copyCue(c, fadeMs: ms));
  time('editDelay', (c, ms) => _copyCue(c, delayMs: ms));
  fn('editLoad', () {
    final e = _edit;
    final c = e == null ? null : _selectedCue();
    if (e == null || c == null) return;
    final d = decodeCue(c);
    // like the reference app: LOAD selects exactly the fixtures the cue holds
    if (d.slots.isEmpty) return; // an empty cue
    e.recs.clear();
    for (final s in d.slots) {
      e.recs[s] = Uint8List.fromList(c.block(s ~/ 16).sublist((s % 16) * recordSize, (s % 16 + 1) * recordSize));
    }
    e.fixtures
      ..clear()
      ..addAll(d.slots);
    _recalcMerged();
    e.loaded = e.cues.first;
    for (var g = 0; g < 3; g++) {
      e.fx[g] = d.fx[g];
    }
    e.quietUntil = DateTime.now().add(const Duration(seconds: 3));
    // like the reference app: LOAD on the LPU, then the loaded cue's selection
    _vn.loadCue(e.pb, e.loaded);
    _vn.selectFixtures(e.fixtures);
    _changed();
  }.toJS);
  fn('editRecord', () {
    final e = _edit;
    final c = e == null ? null : _selectedCue();
    if (e == null || c == null) return;
    // the cue becomes the programmer: a fixture without values is not in it
    final blocks = List.generate(4, (_) => Uint8List(blockSize));
    e.recs.forEach((s, r) => blocks[s ~/ 16].setRange((s % 16) * recordSize, (s % 16 + 1) * recordSize, r));
    _writeCue(e.cues.first, _copyCue(c, blocks: [for (final b in blocks) b.any((x) => x != 0) ? b : Uint8List(0)]));
    e.loaded = e.cues.first; // its tiles turn red
    _changed();
  }.toJS);
  void clear(bool all) {
    final e = _edit;
    if (e == null) return;
    e.recs.clear();
    for (final k in e.attrs.keys) {
      e.attrs[k] = 0;
    }
    e.pan = e.tilt = 128;
    for (var g = 0; g < 3; g++) {
      e.fx[g] = noFx;
    }
    _vn.clearProgrammer(); // like the reference app (no message)
    if (all) {
      e.loaded = -1;
      e.fixtures.clear();
    } else {
      _vn.selectFixtures(e.fixtures); // CLEAR on the LPU drops the selection too
    }
    _changed();
  }

  fn('editClear', () {
    clear(false);
  }.toJS);
  fn('editClearAll', () {
    clear(true);
  }.toJS);
}

void main() {
  // through the ESP32 box an answer is now and then lost or late: a read asks
  // again after 200 ms instead of 600 (the slowest normal answers ~120 ms)
  LpuClient.readFirstTimeout = const Duration(milliseconds: 200);
  // the LPU chosen last, remembered in this browser (the app: SharedPreferences)
  try {
    final saved = web.window.localStorage.getItem('dled_lpu');
    if (saved != null && saved.isNotEmpty) _vn.preferredIp = saved;
  } catch (_) {}
  _vn
    ..onPreferredChanged = (ip) {
      try {
        ip.isEmpty ? web.window.localStorage.removeItem('dled_lpu') : web.window.localStorage.setItem('dled_lpu', ip);
      } catch (_) {}
    }
    ..onLiveEvent = _onLive
    ..onDevicesChanged = (_) {
      _changed();
    }
    ..onConnectionChanged = (d) {
      if (d == null) {
        for (final p in _pbs) {
          p.clear();
        }
        _fixtures.clear();
        _show = null;
        _info = null;
        _edit = null;
      }
      _changed();
    };

  final api = JSObject();
  void fn(String name, JSFunction f) => api.setProperty(name.toJS, f);
  fn('start', () {
    unawaited(_vn.start());
  }.toJS);
  fn('onChange', (JSFunction f) {
    _listener = f;
  }.toJS);
  fn('state', (() => _stateJson().toJS).toJS);
  fn('go', ((int pb) {
    if (_ok(pb)) _vn.sendGoCommand(pb);
  }).toJS);
  fn('release', ((int pb) {
    if (_ok(pb)) _vn.release(pb);
  }).toJS);
  fn('releaseAll', () {
    _vn.releaseAll();
  }.toJS);
  fn('flash', ((int pb, bool down) {
    if (_ok(pb)) _vn.flash(pb, down);
  }).toJS);
  fn('fader', ((int pb, double v) {
    if (!_ok(pb)) return;
    _pbs[pb].level = v.clamp(0.0, 1.0);
    _vn.sendFaderLevel(pb, _pbs[pb].level);
    _changed();
  }).toJS);
  fn('speed', ((int pb, double v) {
    if (!_ok(pb)) return;
    _pbs[pb].speed = v.clamp(-1.0, 1.0);
    _vn.sendRotaryLevel(pb, _pbs[pb].speed);
    _changed();
  }).toJS);
  fn('knobToSpeed', ((double knob) => speedFromKnob(knob).toJS).toJS);
  fn('speedToKnob', ((double speed) => knobFromSpeed(speed).toJS).toJS);
  fn('rename', ((int pb, String name) {
    if (!_ok(pb)) return;
    _pbs[pb].label = name;
    _vn.writePlaybackLabel(pb, name);
    _changed();
  }).toJS);
  fn('swap', ((int a, int b) {
    if (!_ok(a) || !_ok(b) || a == b) return;
    final x = _pbs[a];
    _pbs[a] = _pbs[b];
    _pbs[b] = x;
    _vn.swapPlaybacks(a, b); // the LPU's read-back confirms both
    _changed();
  }).toJS);
  fn('props', ((int pb, String? goMode, String? repeat, bool? background, bool? exclusive) {
    if (!_ok(pb)) return;
    final p = _pbs[pb];
    if (goMode != null) p.goMode = goMode;
    if (repeat != null) p.repeat = repeat;
    if (background != null) p.background = background;
    if (exclusive != null) p.exclusive = exclusive;
    _vn.writePlaybackProps(pb, goMode: goMode, repeat: repeat, background: background, exclusive: exclusive);
    _changed();
  }).toJS);
  fn('deviceName', ((String name) {
    if (name.isEmpty) return;
    _info?.alias = name;
    _vn.writeDeviceSettings(alias: name);
    _changed();
  }).toJS);
  fn('artNet', ((bool on, int raw) {
    _vn.writeDeviceSettings(artNet: on, artNetRaw: raw);
  }).toJS);
  fn('sacn', ((bool on, int universe) {
    _vn.writeDeviceSettings(sacn: on, sacnUniverse: universe);
  }).toJS);
  fn('network', ((bool dhcp, String ip, String mask) {
    if (dhcp) {
      unawaited(_vn.setNetwork());
      return true.toJS;
    }
    final i = parseIpv4(ip), m = parseIpv4(mask);
    if (i == null || m == null) return false.toJS; // like the reference app: nothing sent
    unawaited(_vn.setNetwork(ip: i, mask: m));
    return true.toJS;
  }).toJS);
  fn('showText', (() => writeShow(_show ?? Show()).toJS).toJS);
  fn('emptyShowText', (() => writeShow(Show()).toJS).toJS);
  fn('checkShow', ((String text) {
    try {
      parseShow(text);
      return true.toJS;
    } catch (_) {
      return false.toJS;
    }
  }).toJS);
  fn('openShow', ((String text, JSFunction progress, JSFunction aborted) {
    Future<String> run() async {
      final Show show;
      try {
        show = parseShow(text);
      } catch (_) {
        return 'Not a show file.';
      }
      var step = '';
      try {
        final r = await _vn.uploadShow(show,
            restore: _show,
            progress: (s) {
              step = s;
              progress.callAsFunction(null, (-1).toJS, s.toJS);
            },
            fraction: (f) => progress.callAsFunction(null, f.toJS, step.toJS),
            cancelled: () => (aborted.callAsFunction() as JSBoolean?)?.toDart ?? false);
        if (r == null) return 'Not connected to an LPU.';
        if (r.aborted) return 'Aborted: the LPU has its previous show again.';
        return r.diffs.isEmpty ? 'Sent to the LPU and verified.' : 'Sent, ${r.diffs.length} difference(s).';
      } catch (e) {
        return 'Upload stopped: $e';
      }
    }

    return run().then((m) => m.toJS).toJS;
  }).toJS);
  fn('personality', ((JSArray<JSNumber> slotsJs, String mfr, String model, String mode, String hex) {
    final slots = _slots(slotsJs);
    if (slots.isEmpty) return;
    final n = profileChannels(hex).clamp(1, 512);
    // replacing a patched fixture keeps its address; else the first free
    // channels, each next fixture after the one before
    final used = [
      for (final f in _fixtures.values)
        if (_patched(f) && !slots.contains(f.index)) (start: f.address, count: profileChannels(f.profile).clamp(1, 512))
    ];
    final first = _fixtures[slots.first];
    var next = first != null && _patched(first) ? first.address : 1;
    for (final s in slots) {
      if (!(s == slots.first && first != null && _patched(first))) next = freeAddress(used, n, from: next);
      used.add((start: next, count: n));
      final f = ShowFixture(index: s, address: next, manufacturer: mfr, model: model, mode: mode, profile: hex);
      _fixtures[s] = f;
      _vn.patchFixture(s, f, definition: true, address: true, name: true, flags: true);
      next += n;
    }
    _changed();
  }).toJS);
  fn('renameFixtures', ((JSArray<JSNumber> slots, String name) {
    for (final s in _slots(slots)) {
      final f = _entry(s)..name = name;
      _fixtures[s] = f;
      _vn.patchFixture(s, f, name: true);
    }
    _changed();
  }).toJS);
  fn('addressFixtures', ((JSArray<JSNumber> slots, int start) {
    var next = start.clamp(1, 512);
    for (final s in _slots(slots)) {
      final f = _entry(s)..address = next;
      _fixtures[s] = f;
      _vn.patchFixture(s, f, address: true);
      next = (next + profileChannels(f.profile).clamp(1, 512)).clamp(1, 512);
    }
    _changed();
  }).toJS);
  fn('flag', ((JSArray<JSNumber> slotsJs, String which) {
    final slots = _slots(slotsJs);
    if (slots.isEmpty) return;
    bool get(ShowFixture f) => switch (which) { 'p' => f.invertPan, 't' => f.invertTilt, 's' => f.swapPanTilt, _ => f.virtualDimmer };
    // the first selected fixture decides: all get the opposite of its value
    final on = !get(_entry(slots.first));
    for (final s in slots) {
      final f = _entry(s);
      switch (which) {
        case 'p':
          f.invertPan = on;
        case 't':
          f.invertTilt = on;
        case 's':
          f.swapPanTilt = on;
        default:
          f.virtualDimmer = on;
      }
      _fixtures[s] = f;
      _vn.patchFixture(s, f, flags: true);
    }
    _changed();
  }).toJS);
  fn('clearFixtures', ((JSArray<JSNumber> slots) {
    for (final s in _slots(slots)) {
      _fixtures.remove(s);
      _vn.patchFixture(s, null);
    }
    _changed();
  }).toJS);
  _editApi(fn);
  _positionsApi(fn);
  fn('connect', ((String ip) {
    for (final d in _vn.devices) {
      if (d.ip == ip) unawaited(_vn.connect(d));
    }
  }).toJS);
  fn('deselect', () {
    _vn.deselect();
  }.toJS);
  globalContext.setProperty('dled'.toJS, api);
}
