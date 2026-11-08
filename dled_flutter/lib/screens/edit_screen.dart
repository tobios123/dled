import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/fixture_codes.dart' show isSignedAttr;
import '../models/show_model.dart';
import '../services/programmer.dart';
import 'positions_screen.dart';
import '../widgets/app_button.dart';
import '../widgets/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/edit_controls.dart';
import '../widgets/fixture_grid.dart';

// ---------------------------------------------------------------------------
// FX data model
// ---------------------------------------------------------------------------

enum FxCategory { intensity, position, colour }

const _intensityWaveforms = ['None', 'Sinus', 'Ramp', 'Inversed Ramp', 'Square', 'Random'];
const _positionWaveforms  = ['None', 'Circle', 'Eight', 'Square', 'Pan', 'Tilt', 'Random'];
const _colourWaveforms    = ['None', 'Rainbow', 'Random', 'Full Sinus', 'Full Twinkle'];

List<String> _waveformsFor(FxCategory cat) {
  switch (cat) {
    case FxCategory.intensity: return _intensityWaveforms;
    case FxCategory.position:  return _positionWaveforms;
    case FxCategory.colour:    return _colourWaveforms;
  }
}

String _labelFor(FxCategory cat) {
  switch (cat) {
    case FxCategory.intensity: return 'INTENSITY FX';
    case FxCategory.position:  return 'POSITION FX';
    case FxCategory.colour:    return 'COLOURMIX FX';
  }
}

class FxSlot {
  String waveform = 'None';
  double size  = 0;
  double speed = 0; // the reference app's default (and what X resets to)
  double phase = 0;
  bool get active => waveform != 'None';

  void copyFrom(FxSlot o) {
    waveform = o.waveform;
    size = o.size;
    speed = o.speed;
    phase = o.phase;
  }

  void copyFromCue(CueFxSlot o) {
    waveform = o.waveform;
    size = o.size;
    speed = o.speed;
    phase = o.phase;
  }

  CueFxSlot toCue() => CueFxSlot(waveform: waveform, size: size, speed: speed, phase: phase);
}

class FxState {
  final FxSlot intensity = FxSlot();
  final FxSlot position  = FxSlot();
  final FxSlot colour    = FxSlot();
  bool get anyActive => intensity.active || position.active || colour.active;

  FxState copy() {
    final out = FxState();
    for (final cat in FxCategory.values) {
      out.slot(cat).copyFrom(slot(cat));
    }
    return out;
  }

  /// As a cue holds them: intensity, position, colour.
  List<CueFxSlot> toCue() => [for (final cat in FxCategory.values) slot(cat).toCue()];

  FxSlot slot(FxCategory cat) {
    switch (cat) {
      case FxCategory.intensity: return intensity;
      case FxCategory.position:  return position;
      case FxCategory.colour:    return colour;
    }
  }
}

/// The edit screen as it was closed (ShowModel.editMemory).
class _EditMemory {
  final int cuelist;
  final Set<int> cues;
  final int loadedCue;
  final Set<int> fixtures;
  final Map<int, Map<String, double>> slotAttrs;
  final Map<int, FxState> slotFx;
  final Map<String, double> attrs;
  final double pan, tilt;
  final bool fine;
  final int colourMode;
  final FxState fx;

  _EditMemory({
    required this.cuelist,
    required this.cues,
    required this.loadedCue,
    required this.fixtures,
    required this.slotAttrs,
    required this.slotFx,
    required this.attrs,
    required this.pan,
    required this.tilt,
    required this.fine,
    required this.colourMode,
    required this.fx,
  });
}

// ---------------------------------------------------------------------------
// EditScreen
// ---------------------------------------------------------------------------

class EditScreen extends StatefulWidget {
  final int cuelistIndex;
  const EditScreen({super.key, this.cuelistIndex = -1});

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late int _selectedCuelist;
  final Set<int> _selectedFixtures = {};
  // Per-slot programmer memory loaded from a cue (slot → attrKey → 0-255 value)
  // and each slot's FX: like the LPU's programmer, every fixture keeps its
  // own values; a change goes to the selected ones (_touch).
  final Map<int, Map<String, double>> _slotAttrs = {};
  final Map<int, FxState> _slotFx = {};
  final Set<int> _selectedCueIndices = {};
  int _loadedCueIndex = -1;
  bool _fineMode = false;
  int _colourMode = 0; // 0 R G B A W faders, 1 colour square, 2 colour wheel
  double _pan  = 128;
  double _tilt = 128;

  final Map<String, double> _attrs = {
    'R': 0, 'G': 0, 'B': 0, 'A': 0, 'W': 0, 'UV': 0,
    'In': 0, 'Sh': 0, 'Col': 0, 'Go': 0,
    'Rota': 0, 'Prism': 0, 'Iris': 0, 'Focus': 0,
    'Zoom': 0, 'Frost': 0, 'Custom': 0, 'Custom2': 0,
  };

  final FxState _fx = FxState();

  late final ShowModel _model = context.read<ShowModel>();
  final ScrollController _cueScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _selectedCuelist = widget.cuelistIndex;
    _restore();
    _model.programmerEditing(true); // like the reference app (2c 02 35 = 0)
    _programmerSub = _model.programmerValues.stream.listen(_onProgrammerValue);
  }

  // The reference app opens EDIT as it was left: the selected cue (same
  // playback), fixtures, slider values and FX - recorded or not (2026-10-29,
  // side by side with the reference app). The programmer itself stays on the
  // LPU, so nothing is sent.
  void _restore() {
    final m = _model.editMemory;
    if (m is! _EditMemory) return;
    final cl = _cuelist;
    final cues = cl?.cues.length ?? 0;
    if (m.cuelist == _selectedCuelist) {
      _selectedCueIndices.addAll(m.cues.where((i) => i < cues));
      if (m.loadedCue < cues) _loadedCueIndex = m.loadedCue;
    }
    _selectedFixtures.addAll(m.fixtures.where((s) => s >= 0 && s < 64));
    m.slotAttrs.forEach((slot, a) => _slotAttrs[slot] = Map.of(a));
    m.slotFx.forEach((slot, f) => _slotFx[slot] = f.copy());
    _attrs.addAll(m.attrs);
    _pan = m.pan;
    _tilt = m.tilt;
    _fineMode = m.fine;
    _colourMode = m.colourMode;
    for (final cat in FxCategory.values) {
      _fx.slot(cat).copyFrom(m.fx.slot(cat));
    }
  }

  void _remember() {
    final fx = FxState();
    for (final cat in FxCategory.values) {
      fx.slot(cat).copyFrom(_fx.slot(cat));
    }
    _model.editMemory = _EditMemory(
      cuelist: _selectedCuelist,
      cues: Set.of(_selectedCueIndices),
      loadedCue: _loadedCueIndex,
      fixtures: Set.of(_selectedFixtures),
      slotAttrs: {for (final e in _slotAttrs.entries) e.key: Map.of(e.value)},
      slotFx: {for (final e in _slotFx.entries) e.key: e.value.copy()},
      attrs: Map.of(_attrs),
      pan: _pan,
      tilt: _tilt,
      fine: _fineMode,
      colourMode: _colourMode,
      fx: fx,
    );
  }

  // Following the LPU's programmer live (the reference app does not): a change
  // made in another app, or the values a LOAD puts in, shows here. The echo
  // of our own writes is ignored for a moment, so a slider being dragged
  // does not jump back.
  StreamSubscription<({int attr, Uint8List body})>? _programmerSub;
  final Map<int, DateTime> _sentAt = {};
  static const _echoWindow = Duration(milliseconds: 600);

  void _onProgrammerValue(({int attr, Uint8List body}) v) {
    final sent = _sentAt[v.attr];
    if (sent != null && DateTime.now().difference(sent) < _echoWindow) return;
    final d = decodeProgrammer(v.attr, v.body);
    if (d == null || !mounted) return;
    setState(() {
      d.sliders.forEach((k, value) {
        if (k == 'Pan') {
          _pan = value;
        } else if (k == 'Tilt') {
          _tilt = value;
        }
        _attrs[k] = value;
      });
      // The values a LOAD or a new selection reports are no change to give
      // every selected fixture.
      final change = DateTime.now().isAfter(_settleUntil);
      if (change) _touch(d.sliders.keys);
      final fx = d.fx;
      if (fx != null) {
        final cat = switch (fx.generator) {
          'intensity' => FxCategory.intensity,
          'position' => FxCategory.position,
          _ => FxCategory.colour,
        };
        final slot = _fx.slot(cat);
        slot.waveform = fx.fx.waveform;
        slot.size = fx.fx.size;
        slot.speed = fx.fx.speed;
        slot.phase = fx.fx.phase;
        if (change) _touchFx(cat);
      }
    });
  }

  DateTime _settleUntil = DateTime(0);
  static const _settle = Duration(milliseconds: 1000);

  // Like the LPU's programmer: a changed attribute goes to every selected
  // fixture, the others keep their own values (test record_per_fixture,
  // 2026-11-02). The colour is one attribute (R G B A W together), so is the
  // position (pan and tilt). A fixture gets its memory with its first change.
  void _touch(Iterable<String> keys) {
    final all = {...keys};
    if (all.any(colourKeys.contains)) all.addAll(colourKeys);
    if (all.contains('Pan') || all.contains('Tilt')) all.addAll(const ['Pan', 'Tilt']);
    for (final slot in _selectedFixtures) {
      final m = _slotAttrs[slot] ??= {};
      for (final k in all) {
        final v = _attrs[k];
        v == null ? m.remove(k) : m[k] = v;
      }
    }
  }

  void _touchFx(FxCategory cat) {
    for (final slot in _selectedFixtures) {
      (_slotFx[slot] ??= FxState()).slot(cat).copyFrom(_fx.slot(cat));
    }
  }

  void _markSent(Iterable<ProgrammerWrite> writes) {
    final now = DateTime.now();
    for (final w in writes) {
      _sentAt[w.attr] = now;
    }
  }

  @override
  void dispose() {
    _remember();
    _model.programmerEditing(false); // the programmer keeps its values
    _programmerSub?.cancel();
    _cueScroll.dispose();
    super.dispose();
  }

  Cuelist? get _cuelist {
    final model = context.read<ShowModel>();
    if (_selectedCuelist >= 0 && _selectedCuelist < model.cuelists.length) {
      return model.cuelists[_selectedCuelist];
    }
    return null;
  }

  void _addCue() {
    final cl = _cuelist;
    if (cl == null) return;
    // The model adds it (and inserts it on the LPU when connected).
    final added = context.read<ShowModel>().addCue(_selectedCuelist);
    if (added < 0) return; // already ShowModel.maxCues cues
    setState(() {
      _selectedCueIndices.clear();
      _selectedCueIndices.add(added);
    });
    // Show the new cue completely (it is added at the end).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_cueScroll.hasClients) return;
      final p = _cueScroll.position;
      final end = (added + 1) * _cueExtent - p.viewportDimension;
      _cueScroll.animateTo(end.clamp(0.0, p.maxScrollExtent),
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  static const double _cueExtent = 102; // cue tile 96 + margins 2 x 3
  static const double _tallButton = 44; // the side buttons, like OPTIONS
  static const double _cuesHeight = 150; // CUES title + the cue tiles

  void _removeCue() {
    final cl = _cuelist;
    if (cl == null || _selectedCueIndices.isEmpty) return;
    final sorted = _selectedCueIndices.toList()..sort((a, b) => b.compareTo(a));
    // The model removes them (and deletes them on the LPU when connected).
    context.read<ShowModel>().removeCues(_selectedCuelist, sorted);
    setState(() {
      final minIdx = sorted.last;
      _selectedCueIndices.clear();
        if (minIdx < cl.cues.length) { _selectedCueIndices.add(minIdx); }
        else if (cl.cues.isNotEmpty) { _selectedCueIndices.add(cl.cues.length - 1); }
    });
  }

  void _recalcMergedAttrs() {
    for (final k in _attrs.keys) { _attrs[k] = 0; }
    for (final slot in _selectedFixtures) {
      final slotMap = _slotAttrs[slot];
      if (slotMap == null) continue;
      for (final entry in slotMap.entries) {
        final cur = _attrs[entry.key] ?? 0.0;
        if (entry.value > cur) _attrs[entry.key] = entry.value;
      }
    }
    _pan  = _attrs['Pan']  ?? 128;
    _tilt = _attrs['Tilt'] ?? 128;
  }

  // The LPU's programmer follows this screen live when connected, so the
  // lights show what is being edited, like in the reference app (the model does
  // nothing offline).
  void _sendSelection() {
    _settleUntil = DateTime.now().add(_settle);
    _model.programmerSelect(_selectedFixtures);
  }

  void _sendSliders(Iterable<String> keys) {
    final writes = sliderWrites(_attrs, _pan, _tilt, keys);
    _markSent(writes);
    _model.programmerWrite(writes);
  }

  void _sendFx(FxCategory cat, String waveform, double size, double speed, double phase) {
    final writes = [fxWrite(cat.name, CueFxSlot(waveform: waveform, size: size, speed: speed, phase: phase))];
    _markSent(writes);
    _model.programmerWrite(writes);
  }

  // RECORD as on the LPU (2026-11-02, DMX_ENGINE.md 12): the cue becomes the
  // programmer, every fixture with its own values and FX. A fixture with
  // none is not in it, selected or not; one the cue had is gone.
  void _recordProgrammer() {
      if (_selectedCuelist < 0) return;
      final cue = _getSelectedCue();
      if (cue == null) return;
      setState(() {
        final old = Map.of(cue.channels);
        cue.channels.clear();
        final recorded = <int>{};
        for (final slot in {..._slotAttrs.keys, ..._slotFx.keys}) {
          final own = _slotAttrs[slot] ?? const {};
          own.forEach((k, v) {
            // store as 0.0-1.0 fraction to match show_loader convention;
            // pan / tilt 0 is full left / up, a value (absent = the centre)
            if (v <= 0 && !isSignedAttr(k)) return;
            final key = '$slot:$k';
            final was = old[key];
            cue.channels[key] = was != null && (was * 255 - v).abs() <= 1e-6 ? was : v / 255.0;
            recorded.add(slot);
          });
          if (_slotFx[slot]?.anyActive ?? false) recorded.add(slot);
        }
        // Persist FX settings into the cue so they round-trip through save/load.
        cue.fxIntensity.waveform = _fx.intensity.waveform;
        cue.fxIntensity.size     = _fx.intensity.size;
        cue.fxIntensity.speed    = _fx.intensity.speed;
        cue.fxIntensity.phase    = _fx.intensity.phase;
        cue.fxPosition.waveform  = _fx.position.waveform;
        cue.fxPosition.size      = _fx.position.size;
        cue.fxPosition.speed     = _fx.position.speed;
        cue.fxPosition.phase     = _fx.position.phase;
        cue.fxColour.waveform    = _fx.colour.waveform;
        cue.fxColour.size        = _fx.colour.size;
        cue.fxColour.speed       = _fx.colour.speed;
        cue.fxColour.phase       = _fx.colour.phase;
        // a fixture with other FX than the dialogs show keeps its own
        final cueFx = jsonEncode(_fx.toCue());
        cue.slotFx.clear();
        for (final slot in recorded) {
          final fx = (_slotFx[slot] ?? FxState()).toCue();
          if (jsonEncode(fx) != cueFx) cue.slotFx[slot] = fx;
        }
        cue.isRecorded = true;
        cue.slots
          ..clear()
          ..addAll(recorded); // the cue holds these fixtures now
        // The recorded cue is the loaded one now: its tiles turn red.
        _loadedCueIndex = _cuelist?.cues.indexOf(cue) ?? -1;
      });
      // Writes the recorded cue to the LPU when connected.
      final cl = _cuelist;
      if (cl != null) context.read<ShowModel>().cueChanged(_selectedCuelist, cl.cues.indexOf(cue));
    }

  void _loadProgrammer() {
    final cue = _getSelectedCue();
    if (cue == null) return;
    // Like the reference app: LOAD selects exactly the fixtures the cue holds.
    final slots = _loadedSlotsOf(cue, context.read<ShowModel>());
    if (slots.isEmpty) return; // an empty cue (or nothing patched)
     setState(() {
       // Build per-slot programmer memory from the cue.
       _slotAttrs.clear();
       _slotFx.clear();
       for (final slot in slots) {
         final fx = FxState();
         for (final (g, f) in cue.fxOf(slot).indexed) {
           fx.slot(FxCategory.values[g]).copyFromCue(f);
         }
         _slotFx[slot] = fx;
         final slotMap = <String, double>{};
         for (final attrKey in {..._attrs.keys, 'Pan', 'Tilt'}) {
           final val = cue.channels['$slot:$attrKey'];
           // channels stored as 0.0-1.0; sliders use 0-255
           if (val != null) {
             slotMap[attrKey] = (val * 255).clamp(0.0, 255.0);
           }
         }
         _slotAttrs[slot] = slotMap;
       }
       // OR-merge (max) across all slots for the shared UI display.
       for (final k in _attrs.keys) { _attrs[k] = 0; }
       for (final slotMap in _slotAttrs.values) {
         for (final entry in slotMap.entries) {
           final cur = _attrs[entry.key] ?? 0.0;
           if (entry.value > cur) _attrs[entry.key] = entry.value;
         }
       }
       _pan  = _attrs['Pan']  ?? 128;
       _tilt = _attrs['Tilt'] ?? 128;
       _selectedFixtures.clear();
       _selectedFixtures.addAll(slots);
      _loadedCueIndex = _selectedCueIndices.first;
      // Restore FX settings from the cue into the programmer.
      _fx.intensity.waveform = cue.fxIntensity.waveform;
      _fx.intensity.size     = cue.fxIntensity.size;
      _fx.intensity.speed    = cue.fxIntensity.speed;
      _fx.intensity.phase    = cue.fxIntensity.phase;
      _fx.position.waveform  = cue.fxPosition.waveform;
      _fx.position.size      = cue.fxPosition.size;
      _fx.position.speed     = cue.fxPosition.speed;
      _fx.position.phase     = cue.fxPosition.phase;
      _fx.colour.waveform    = cue.fxColour.waveform;
      _fx.colour.size        = cue.fxColour.size;
      _fx.colour.speed       = cue.fxColour.speed;
       _fx.colour.phase       = cue.fxColour.phase;
     });
     // Like the reference app: LOAD on the LPU, then the loaded cue's selection.
     _model.programmerLoad(_selectedCuelist, _loadedCueIndex);
     _sendSelection();
   }

  /// CLEAR: channel values and FX back to default; the selection stays (and
  /// is sent again, as CLEAR on the LPU drops it too).
  void _clearValues() {
    setState(() {
      _slotAttrs.clear();
      _slotFx.clear();
      for (final k in _attrs.keys) { _attrs[k] = 0; }
      _fx.intensity.waveform = 'None';
      _fx.position.waveform  = 'None';
      _fx.colour.waveform    = 'None';
      _pan = 128; _tilt = 128;
    });
    _model.programmerClear();
    _sendSelection();
  }

  /// CLEAR ALL: the whole programmer, the selection and the loaded cue too.
  void _clearProgrammer() {
    setState(() {
      _loadedCueIndex = -1;
      _selectedFixtures.clear();
      _slotAttrs.clear();
      _slotFx.clear();
      for (final k in _attrs.keys) { _attrs[k] = 0; }
      _fx.intensity.waveform = 'None';
      _fx.position.waveform  = 'None';
      _fx.colour.waveform    = 'None';
      _pan = 128; _tilt = 128;
    });
    _model.programmerClear(); // CLEAR on the LPU, like the reference app (no message)
  }


  Cue? _getSelectedCue() {
    final cl = _cuelist;
    if (cl == null || _selectedCueIndices.length != 1) return null;
    final idx = _selectedCueIndices.first;
    if (idx < 0 || idx >= cl.cues.length) return null;
    return cl.cues[idx];
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ShowModel>();
    final cl = _selectedCuelist >= 0 && _selectedCuelist < model.cuelists.length
        ? model.cuelists[_selectedCuelist] : null;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildTopBar(),
          // Cues row: list on left, ADD/REMOVE on right (same column width as sidebar)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildCuesSection(cl)),
              SizedBox(width: 98, child: _buildCuesButtons()),
            ],
          ),
          // 4px gap between cues row and fixtures row
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildFixturesSection(model)),
                _buildRightSidebar(),
              ],
            ),
          ),
          _buildBottomPanel(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Top bar
  // ---------------------------------------------------------------------------
  Widget _buildTopBar() => AppTopBar(
        connected: context.watch<ShowModel>().liveConnected,
        left: [AppButton('BACK', onTap: () => Navigator.of(context).pop())],
      );

  // ---------------------------------------------------------------------------
  // POSITIONS: stored pan / tilt per fixture
  // ---------------------------------------------------------------------------

  /// What STORE stores: every selected patched fixture with pan / tilt, with
  /// its own position here (a fixture without one has not been aimed).
  List<StoredFixture> _storableFixtures() {
    final out = <StoredFixture>[];
    for (final slot in _selectedFixtures.toList()..sort()) {
      final fp = _model.fixtures.where((f) => f.slot == slot && f.isPatched).firstOrNull;
      if (fp == null) continue;
      if (fp.channels.isNotEmpty && !fp.channels.contains('Pan') && !fp.channels.contains('Tilt')) continue;
      final m = _slotAttrs[slot];
      if (m == null || (!m.containsKey('Pan') && !m.containsKey('Tilt'))) continue;
      out.add(StoredFixture(
        slot: slot,
        manufacturer: fp.manufacturer,
        model: fp.model,
        mode: fp.mode,
        name: fp.label,
        pan: StoredFixture.fromEdit(m['Pan'] ?? 127.5),
        tilt: StoredFixture.fromEdit(m['Tilt'] ?? 127.5),
      ));
    }
    return out;
  }

  Future<void> _openPositions() async {
    final p = await Navigator.of(context).push<StoredPosition>(MaterialPageRoute(
        builder: (_) => PositionsScreen(toStore: _storableFixtures, selected: Set.of(_selectedFixtures))));
    if (p != null && mounted) _recallPosition(p, _model.positionsWithFixtures);
  }

  /// A recalled position: only pan / tilt change, per fixture. SELECTED: the
  /// selected fixtures that are in it; WITH FIXTURES: the selection becomes
  /// its fixtures. A slot gets the stored values whatever is patched there
  /// now (the user's choice). On the LPU one fixture at a time, as its
  /// programmer writes to the selected fixtures.
  void _recallPosition(StoredPosition p, bool withFixtures) {
    final targets = withFixtures
        ? (p.fixtures.keys.toList()..sort())
        : [for (final s in _selectedFixtures.toList()..sort()) if (p.fixtures.containsKey(s)) s];
    if (targets.isEmpty) return;
    setState(() {
      if (withFixtures) {
        _selectedFixtures
          ..clear()
          ..addAll(targets);
      }
      for (final s in targets) {
        final f = p.fixtures[s]!;
        (_slotAttrs[s] ??= {})
          ..['Pan'] = f.editPan
          ..['Tilt'] = f.editTilt;
      }
      _recalcMergedAttrs();
    });
    final bodies = {
      for (final s in targets)
        s: sliderWrites(const {}, p.fixtures[s]!.editPan, p.fixtures[s]!.editTilt, const ['Pan']).single.body,
    };
    _sentAt[2] = DateTime.now(); // the echoes are no change
    _settleUntil = DateTime.now().add(_settle);
    _model.programmerPositions(bodies, _selectedFixtures);
  }

  // ---------------------------------------------------------------------------
  // Cues section (list only)
  // ---------------------------------------------------------------------------
  /// A time like the reference app shows it: 0s, 2.5s.
  static String _seconds(double s) =>
      '${s == s.roundToDouble() ? s.round() : s.toStringAsFixed(1)}s';

  Widget _buildCuesSection(Cuelist? cl) {
    return Container(
      height: _cuesHeight,
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CUES', style: appHeader),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                  color: AppColors.panel,
                  border: Border.all(color: AppColors.panelLine),
                  borderRadius: BorderRadius.circular(4)),
              child: cl == null || cl.cues.isEmpty ? const SizedBox()
                  // Up to 48 cues: scrollable by touch, by dragging with the
                  // mouse, with the mouse wheel and the scrollbar.
                  : Listener(
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent && _cueScroll.hasClients) {
                          final p = _cueScroll.position;
                          _cueScroll.jumpTo((p.pixels + e.scrollDelta.dy + e.scrollDelta.dx)
                              .clamp(p.minScrollExtent, p.maxScrollExtent));
                        }
                      },
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                            dragDevices: PointerDeviceKind.values.toSet()),
                        child: Scrollbar(
                          controller: _cueScroll,
                          thumbVisibility: true,
                          child: ListView.builder(
                      controller: _cueScroll,
                      scrollDirection: Axis.horizontal,
                      itemExtent: _cueExtent, // exact scroll positions (new cue in view)
                      padding: const EdgeInsets.only(bottom: 8), // room for the scrollbar
                      itemCount: cl.cues.length,
                      itemBuilder: (_, i) {
                        final cue = cl.cues[i];
                        final sel = _selectedCueIndices.contains(i);
                        return GestureDetector(
                          onTap: () {
                            // Like the reference app: tapping only (de)selects the
                            // cue, several can be selected; LOAD loads it
                            // (LOAD / RECORD need exactly one selected cue).
                            setState(() => _selectedCueIndices.contains(i)
                                ? _selectedCueIndices.remove(i)
                                : _selectedCueIndices.add(i));
                          },
                          // Like the reference app: name, delay, condition, fade,
                          // centred; a red border when the cue holds data.
                          child: Container(
                            width: 96,
                            margin: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: sel ? const Color(0xFF34404E) : const Color(0xFF1B232D),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                  color: (cue.isRecorded || cue.channels.isNotEmpty || cue.fxIntensity.active || cue.fxPosition.active || cue.fxColour.active)
                                      ? const Color(0xFFE02828)
                                      : sel
                                          ? Colors.white70
                                          : const Color(0xFF5A5E66),
                                  width: sel ? 2 : 1),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final line in [
                                  // an unnamed cue ("Cue 2" in the app) shows just its number
                                  cue.label.isEmpty || cue.label == 'Cue ${cue.number}' ? '${cue.number}' : cue.label,
                                  _seconds(cue.delay),
                                  cue.condition == CueCondition.follow ? 'Follow' : 'Halt',
                                  _seconds(cue.fadeIn),
                                ])
                                  Text(line,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: sel ? Colors.white : AppColors.text, fontSize: 12)),
                              ],
                            ),
                          ),
                        );
                      }),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ADD / REMOVE buttons — same row as cues
  Widget _buildCuesButtons() {
    return Container(
      height: _cuesHeight,
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(4, 28, 4, 6),
      alignment: Alignment.topCenter,
      child: AppButtonGroup(axis: Axis.vertical, children: [
        AppButton('ADD', onTap: _addCue, height: _tallButton),
        AppButton('REMOVE', onTap: _removeCue, height: _tallButton),
      ]),
    );
  }

  // ---------------------------------------------------------------------------
  // Fixtures grid: the PATCH grid (widgets/fixture_grid.dart) in a navy panel;
  // selected tiles get a red border like the reference app. Unpatched slots can be
  // selected (and recorded) too.
  // ---------------------------------------------------------------------------
  void _setFixture(int slot, bool on) {
    setState(() {
      on ? _selectedFixtures.add(slot) : _selectedFixtures.remove(slot);
      _recalcMergedAttrs();
    });
    _sendSelection();
  }

  /// The loaded cue (LOAD or RECORD), or null.
  Cue? get _loadedCue {
    final cl = _cuelist;
    return cl != null && _loadedCueIndex >= 0 && _loadedCueIndex < cl.cues.length
        ? cl.cues[_loadedCueIndex]
        : null;
  }

  /// The slots the loaded cue holds (red tiles, white for an empty slot, like
  /// the reference app). A pure-FX cue holds every patched fixture (as LOAD
  /// selects them).
  Set<int> _loadedSlots(ShowModel model) {
    final cue = _loadedCue;
    return cue == null ? const {} : _loadedSlotsOf(cue, model);
  }

  /// The fixtures [cue] holds: its own list (from the LPU's records, or
  /// RECORD); for cues saved before that list, the slots with values, and a
  /// pure-FX cue every patched fixture.
  Set<int> _loadedSlotsOf(Cue cue, ShowModel model) {
    if (cue.slots.isNotEmpty) return cue.slots;
    final slots = {
      for (final k in cue.channels.keys)
        if (int.tryParse(k.split(':').first) case final int s) s,
    };
    if (slots.isEmpty && (cue.fxIntensity.active || cue.fxPosition.active || cue.fxColour.active)) {
      return {for (final f in model.fixtures) if (f.isPatched) f.slot};
    }
    return slots;
  }

  Widget _buildFixturesSection(ShowModel model) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 6, 0, 4),
          child: Text('FIXTURES', style: appHeader),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 0, 2),
            child: AppPanel(
              padding: const EdgeInsets.all(4),
              child: FixtureGrid(
                fixtures: model.fixtures,
                selected: _selectedFixtures,
                square: false,
                recorded: _loadedSlots(model),
                titleSize: 11,
                onToggle: (slot) => _setFixture(slot, !_selectedFixtures.contains(slot)),
                onSet: _setFixture,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right sidebar: RENAME/CONDITION/DELAY/FADE at top, LOAD/RECORD/CLEAR at bottom
  // ---------------------------------------------------------------------------
  Widget _buildRightSidebar() {
    return Container(
      width: 98,
      color: AppColors.background,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      // Two joined groups of tall buttons, like the reference app (and OPTIONS).
      child: Column(
        children: [
          AppButtonGroup(axis: Axis.vertical, children: [
          _SideBtn('RENAME', onTap: _selectedCueIndices.length == 1 ? () => _showRenameDialog() : null),
        _SideBtn('CONDITION', onTap: _selectedCueIndices.isEmpty ? null : () {
            final show = Provider.of<ShowModel>(context, listen: false);
            final cl = _cuelist!;
            setState(() {
              for (final i in _selectedCueIndices) {
                if (i < cl.cues.length) {
                  cl.cues[i].condition = cl.cues[i].condition == CueCondition.follow
                      ? CueCondition.always
                      : CueCondition.follow;
                }
              }
            });
            // Marks the show modified; writes the cues to the LPU when
            // connected (was only changed in the app).
            for (final i in _selectedCueIndices) {
              if (i < cl.cues.length) show.cueChanged(_selectedCuelist, i);
            }
          }),
          _SideBtn('DELAY', onTap: _selectedCueIndices.isEmpty ? null : _showDelayDialog),
          _SideBtn('FADE', onTap: _selectedCueIndices.isEmpty ? null : _showFadeDialog),
          ]),
          const Spacer(),
          AppButtonGroup(axis: Axis.vertical, children: [
          _SideBtn('LOAD', onTap: _selectedCueIndices.length == 1 ? _loadProgrammer : null),
          _SideBtn('RECORD', onTap: _selectedCueIndices.length == 1 ? _recordProgrammer : null),
          // CLEAR: the values and FX back to default, the fixtures stay
          // selected. CLEAR ALL: everything, the selection too.
          _SideBtn('CLEAR', onTap: _clearValues),
          _SideBtn('CLEAR ALL', onTap: _clearProgrammer),
          ]),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom panel
  // ---------------------------------------------------------------------------
  // Like the reference app: one navy panel. The button row lines up with what it
  // belongs to: home / Fine / FX (position) over the pan / tilt pad, the
  // colour-mode button and FX (colour) over the colour channels, FX
  // (intensity) over In / Sh. The colour-mode button cycles: the R G B A W
  // faders -> a colour square -> a colour wheel (in their place).
  static const _faderKeys = [
    'R', 'G', 'B', 'A', 'W', 'In', 'Sh', 'Col', 'Go', //
    'Rota', 'Prism', 'Iris', 'Focus', 'Zoom', 'Frost', 'Custom', 'Custom2',
  ];
  static const _colourKeys = {'R', 'G', 'B', 'A', 'W'};

  Widget _buildBottomPanel() {
    final enabled = _getEnabledChannels(context.read<ShowModel>());
    final position = enabled.contains('Pan') || enabled.contains('Tilt');
    final rgb = enabled.contains('R') || enabled.contains('G') || enabled.contains('B');
    return Container(
      // Taller on a tall (phone) screen, like the reference app; 250 at 1024 high.
      height: 250 + ((MediaQuery.of(context).size.height - 1024) * 0.3).clamp(0.0, 300.0),
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      child: AppPanel(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(builder: (context, box) {
          const gap = 4.0;
          final pad = (box.maxWidth * 0.2).floorToDouble();
          final unit = (box.maxWidth - pad - gap) / _faderKeys.length; // one fader
          final loaded = _loadedCue;
          Widget btn(String label, double width, VoidCallback? onTap,
                  {IconData? icon, bool lit = false, bool red = false}) =>
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: AppButton(label,
                    icon: icon,
                    lit: lit,
                    width: width - 2,
                    onTap: onTap,
                    outline: red ? const Color(0xFFE02828) : null),
              );
          final colourArea = switch (_colourMode) {
            1 => ColourSquare(r: _attrs['R'] ?? 0, g: _attrs['G'] ?? 0, b: _attrs['B'] ?? 0, onChanged: _setRgb),
            2 => ColourWheel(r: _attrs['R'] ?? 0, g: _attrs['G'] ?? 0, b: _attrs['B'] ?? 0, onChanged: _setRgb),
            _ => null,
          };
          return Column(children: [
            Row(children: [
              btn('', pad * 0.2, !position ? null : _homePosition, icon: Icons.home),
              btn('Fine', pad * 0.25, !position ? null : () => setState(() => _fineMode = !_fineMode),
                  lit: _fineMode),
              // Red: the loaded cue has this FX (like the reference app).
              btn('FX', pad * 0.25, !position ? null : () => _showFxDialog(FxCategory.position),
                  lit: _fx.position.active, red: loaded?.fxPosition.active ?? false),
              // POSITIONS: the stored positions (always: managing them needs no selection)
              btn('POS', pad * 0.3, _openPositions),
              const SizedBox(width: gap),
              btn('', unit, () => setState(() => _colourMode = (_colourMode + 1) % 3), icon: Icons.sync),
              btn('FX', unit * 4, !rgb ? null : () => _showFxDialog(FxCategory.colour),
                  lit: _fx.colour.active, red: loaded?.fxColour.active ?? false),
              btn('FX', unit * 2, !enabled.contains('In') ? null : () => _showFxDialog(FxCategory.intensity),
                  lit: _fx.intensity.active, red: loaded?.fxIntensity.active ?? false),
            ]),
            const SizedBox(height: gap),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: pad,
                  child: PositionPad(
                    pan: _pan,
                    tilt: _tilt,
                    fine: _fineMode,
                    // Same rule as the faders: only when a selected fixture
                    // has pan / tilt.
                    onChanged: !position ? null : _setPosition,
                  ),
                ),
                const SizedBox(width: gap),
                if (colourArea != null)
                  SizedBox(
                    width: unit * _colourKeys.length,
                    child: Padding(padding: const EdgeInsets.all(8), child: Center(child: colourArea)),
                  ),
                for (final k in _faderKeys)
                  if (colourArea == null || !_colourKeys.contains(k))
                    SizedBox(width: unit, child: _fader(k, enabled.contains(k))),
              ]),
            ),
          ]);
        }),
      ),
    );
  }

  void _homePosition() {
    setState(() {
      _pan = 128;
      _tilt = 128;
      _attrs['Pan'] = 128;
      _attrs['Tilt'] = 128;
      _touch(const ['Pan']);
    });
    _sendSliders(const ['Pan']);
  }

  void _setPosition(double pan, double tilt) {
    setState(() {
      _pan = pan;
      _tilt = tilt;
      _attrs['Pan'] = pan;
      _attrs['Tilt'] = tilt;
      _touch(const ['Pan']);
      _loadedCueIndex = _selectedCueIndices.isNotEmpty ? _selectedCueIndices.first : _loadedCueIndex;
    });
    _sendSliders(const ['Pan']);
  }

  /// A colour picked on the square / wheel: R G B together.
  void _setRgb(double r, double g, double b) {
    setState(() {
      _attrs['R'] = r;
      _attrs['G'] = g;
      _attrs['B'] = b;
      _touch(colourKeys);
    });
    _sendSliders(const ['R', 'G', 'B']);
  }

  Widget _fader(String k, bool enabled) => LedFader(
        label: k,
        value: enabled ? (_attrs[k] ?? 0) : 0,
        colour: switch (k) {
          'R' => const Color(0xFFE02020),
          'G' => const Color(0xFF20C020),
          'B' => const Color(0xFF3050E0),
          _ => const Color(0xFF9A9A9A),
        },
        onChanged: !enabled
            ? null
            : (val) {
                setState(() {
                  _attrs[k] = val;
                  _touch([k]);
                });
                _sendSliders([k]);
              },
      );

  // The union of the channels of the selected patched fixtures (a patched
  // fixture with an unknown channel set counts as having all). Empty slots
  // and no selection enable nothing.
  Set<String> get _allChannels => {..._attrs.keys, 'Pan', 'Tilt'};

  Set<String> _getEnabledChannels(ShowModel model) {
    if (_selectedFixtures.isEmpty) return const {};
    final enabled = <String>{};
    for (final slot in _selectedFixtures) {
      FixturePatch? fp;
      try { fp = model.fixtures.firstWhere((f) => f.slot == slot); } catch (_) {}
      // An empty slot can be selected (and recorded) but adds no channels:
      // alone it enables nothing, like the reference app.
      if (fp == null || !fp.isPatched) continue;
      if (fp.channels.isEmpty) return _allChannels; // patched, channels unknown
      enabled.addAll(fp.channels);
    }
    return enabled;
  }

  // ---------------------------------------------------------------------------
  // FX dialog
  // ---------------------------------------------------------------------------
  void _showFxDialog(FxCategory cat) {
    final slot = _fx.slot(cat);
    final waveforms = _waveformsFor(cat);
    String selectedWaveform = slot.waveform;
    double size  = slot.size;
    double speed = slot.speed;
    double phase = slot.phase;
    // Like the reference app the LPU follows the dialog live; Ok keeps it, Cancel
    // (or tapping outside) puts the old generator back.
    var applied = false;
    void live() => _sendFx(cat, selectedWaveform, size, speed, phase);

    // Like the reference app: the waveforms on the left, Size / Speed / Phase
    // faders, X (no FX) / Ok / Cancel below.
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogPanel(
          title: _labelFor(cat),
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 350,
            height: 300,
            child: Column(children: [
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: 172,
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final w in waveforms)
                          GestureDetector(
                            onTap: () {
                              setD(() => selectedWaveform = w);
                              live();
                            },
                            child: Container(
                              height: 45,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: selectedWaveform == w ? const Color(0xFF8A8A8A) : Colors.transparent,
                                border: const Border(bottom: BorderSide(color: Color(0xFF4A4A4A))),
                              ),
                              child: Text(w, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 14)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  for (final (label, value, min, set) in [
                    ('Size', size, 0.0, (double v) => size = v),
                    ('Speed', speed, -100.0, (double v) => speed = v),
                    ('Phase', phase, 0.0, (double v) => phase = v),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(3, 6, 3, 0),
                        child: WindowFader(
                          label: label,
                          value: value,
                          min: min,
                          max: 100,
                          onChanged: (v) {
                            setD(() => set(v));
                            live();
                          },
                        ),
                      ),
                    ),
                  const SizedBox(width: 6),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
                child: Row(children: [
                  DialogButton('X', width: 76, onTap: () {
                    setD(() {
                      selectedWaveform = 'None';
                      size = 0;
                      speed = 0;
                      phase = 0;
                    });
                    live();
                  }),
                  const Spacer(),
                  DialogButton('Ok', onTap: () {
                    setState(() {
                      slot.waveform = selectedWaveform;
                      slot.size = size;
                      slot.speed = speed;
                      slot.phase = phase;
                      _touchFx(cat);
                    });
                    applied = true;
                    Navigator.pop(ctx);
                  }),
                  const SizedBox(width: 8),
                  DialogButton('Cancel', onTap: () => Navigator.pop(ctx)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ).then((_) {
      if (!applied) _sendFx(cat, slot.waveform, slot.size, slot.speed, slot.phase);
    });
  }

  // ---------------------------------------------------------------------------
  // Other dialogs
  // ---------------------------------------------------------------------------
  // RENAME CUE / ENTER FADE / ENTER DELAY: the reference app's text dialogs.
  void _showRenameDialog() {
    final cl = _cuelist;
    final cue = _getSelectedCue();
    if (cl == null || cue == null) return;
    final number = '${cue.number}';
    final unnamed = cue.label == 'Cue $number';
    showDialog(
      context: context,
      // X puts the default back: the number (an unnamed cue shows it).
      builder: (_) => NameDialog(
        title: 'RENAME CUE',
        initial: unnamed ? number : cue.label,
        clearTo: number,
        onOk: (name) {
          setState(() => cue.label = name.isEmpty || name == number ? 'Cue $number' : name);
          context.read<ShowModel>().cueChanged(_selectedCuelist, cl.cues.indexOf(cue));
        },
      ),
    );
  }

  /// A time typed like the reference app shows it ("2.5s", "3", "1,5 s"), or null.
  static double? _parseSeconds(String s) {
    final v = double.tryParse(s.toLowerCase().replaceAll('s', '').replaceAll(',', '.').trim());
    return v == null || v < 0 ? null : v;
  }

  void _showTimeDialog(String title, double initial, void Function(Cue cue, double seconds) apply) {
    final cl = _cuelist;
    if (cl == null || _selectedCueIndices.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => NameDialog(
        title: title,
        initial: _seconds(initial),
        clearTo: '0s', // X: the default time
        onOk: (text) {
          final v = _parseSeconds(text);
          if (v == null) return; // not a time: nothing changes
          final show = context.read<ShowModel>();
          setState(() {
            for (final i in _selectedCueIndices) {
              if (i < cl.cues.length) apply(cl.cues[i], v);
            }
          });
          // Marks the show modified; writes the cues to the LPU when connected.
          for (final i in _selectedCueIndices) {
            show.cueChanged(_selectedCuelist, i);
          }
        },
      ),
    );
  }

  void _showFadeDialog() => _showTimeDialog('ENTER FADE', _getSelectedCue()?.fadeIn ?? 0, (cue, s) {
        cue.fadeIn = s;
        cue.fadeOut = s;
      });

  void _showDelayDialog() =>
      _showTimeDialog('ENTER DELAY', _getSelectedCue()?.delay ?? 0, (cue, s) => cue.delay = s);
}

// ---------------------------------------------------------------------------
// Side button
// ---------------------------------------------------------------------------

class _SideBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _SideBtn(this.label, {this.onTap});

  // The app's one button, tall. No onTap = disabled.
  @override
  Widget build(BuildContext context) => AppButton(label, onTap: onTap, height: 44);
}
