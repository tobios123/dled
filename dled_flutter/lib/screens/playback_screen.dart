import 'dart:async';
import 'dart:math';
// Newer Flutter SDKs have their own RepeatMode; ours is the playback repeat mode.
import 'package:flutter/gestures.dart' show LongPressGestureRecognizer, PointerScrollEvent, TapGestureRecognizer;
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:provider/provider.dart';
import '../core/knob.dart';
import '../models/show_model.dart';
import 'patch_screen.dart';
import 'edit_screen.dart';
import '../widgets/dialogs.dart';
import '../widgets/app_button.dart';
import '../widgets/app_theme.dart';

class PlaybackScreen extends StatefulWidget {
  const PlaybackScreen({super.key});

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen> {
  // Armed action: null = normal Go mode.
  // 'edit' | 'release' | 'rename' | 'props' | 'swap'
  String? _armedAction;
  // For SWAP: index of the first selected slot (-1 = none yet)
  int _swapFirst = -1;

  // The fader bar row: 0-7 (each row = 8 consecutive cuelist slots)
  int _faderRow = 0;

  final Set<int> _flashingSlots = {};
  // Tracks slots whose cuelist WE started via FLASH (so we can release on lift)
  final Set<int> _flashStartedSlots = {};

  // Ctrl + touchpad slide: pixels slid since the last row step.
  double _panRows = 0;
  static const _panPerRow = 40.0;

  void _stepRow(int step) {
    final row = (_faderRow + step).clamp(0, 7);
    if (row != _faderRow) setState(() => _faderRow = row);
  }

  // 3-finger drag tracking
  int _activePointers = 0;
  double _dragStartY = 0;
  int _dragStartRow = 0;

  // Fader and knob values come from the model: the LPU's when connected,
  // the app's offline (fader full until moved, like the LPU's default).
  double _getFader(int slot) {
    final model = context.read<ShowModel>();
    return slot < model.cuelists.length ? model.shownLevel(model.cuelists[slot]) : 1.0;
  }

  // liveSpeed is -1.0..+1.0; the knob widget expects 0.0..1.0. In between
  // the knob's curve (core/knob.dart): very fine around normal speed.
  double _getKnob(int slot) {
    final model = context.read<ShowModel>();
    return slot < model.cuelists.length ? (knobFromSpeed(model.cuelists[slot].liveSpeed) + 1.0) / 2.0 : 0.5;
  }

  // The model sends both to the LPU when connected.
  void _setFader(int slot, double v) => context.read<ShowModel>().setPlaybackLevel(slot, v);

  void _setKnob(int slot, double v) =>
      context.read<ShowModel>().setPlaybackSpeed(slot, speedFromKnob(v * 2.0 - 1.0));
  // Maps slot -> active pointer ID, so only the originating pointer can end the flash
  final Map<int, int> _flashPointers = {};

  void _flashStart(int slot, int pointerId) {
    final m = context.read<ShowModel>();
    if (slot >= m.cuelists.length) return;
    final cl = m.cuelists[slot];
    if (cl.cues.isEmpty) return;
    // Connected, FLASH always goes to the LPU: on a running playback it is
    // full while held, whatever the fader says (like the reference app,
    // 2026-10-29). Offline only an idle playback is started (no DMX here).
    final starts = cl.state != PlaybackState.playing;
    if (!starts && !m.liveConnected) return;
    setState(() {
      _flashingSlots.add(slot);
      if (starts) _flashStartedSlots.add(slot);
      _flashPointers[slot] = pointerId;
    });
    m.flashPress(cl.id);
  }

  void _flashEnd(int slot, int pointerId) {
    // Ignore if this pointer didn't start the flash
    if (_flashPointers[slot] != pointerId) return;
    final wasStarted = _flashStartedSlots.contains(slot);
    setState(() {
      _flashingSlots.remove(slot);
      _flashStartedSlots.remove(slot);
      _flashPointers.remove(slot);
    });
    final m = context.read<ShowModel>();
    // the LPU always gets FLASH up (it releases only what FLASH started);
    // offline only a playback FLASH started is released
    if (!wasStarted && !m.liveConnected) return;
    if (slot < m.cuelists.length) {
      m.flashRelease(m.cuelists[slot].id);
    }
  }

  void _armAction(String action) {
    setState(() {
      if (_armedAction == action) {
        // Toggle off: disarm
        _armedAction = null;
        _swapFirst = -1;
      } else {
        _armedAction = action;
        _swapFirst = -1;
      }
    });
  }

  // Connected, a tile is the LPU's GO button: pressed and let go separately,
  // so Flash and Solo run while it is held (2026-10-30) and the LPU's own 1 s
  // hold releases. Only the pointer that pressed it lets go.
  final Map<int, int> _goPointers = {};

  void _onCellDown(int slot, int pointer) {
    final m = context.read<ShowModel>();
    if (_armedAction != null || !m.liveConnected || slot >= m.cuelists.length) return;
    final cl = m.cuelists[slot];
    if (cl.label.isEmpty && cl.cues.isEmpty) return;
    if (_goPointers.containsKey(slot)) return;
    _goPointers[slot] = pointer;
    m.goButton(cl.id, true);
  }

  void _onCellUp(int slot, int pointer) {
    if (_goPointers[slot] != pointer) return;
    _goPointers.remove(slot);
    final m = context.read<ShowModel>();
    if (slot < m.cuelists.length) m.goButton(m.cuelists[slot].id, false);
  }

  // Long press (releaseHold, 0.8 s) on a running playback releases it, like
  // the reference app: holding (yellow) and also while a fade or delay runs
  // (green, 2026-10-29); the release fades with the cue's fade time, or goes
  // at once without one. Not while a mode is armed; on an idle or releasing
  // playback it does nothing.
  void _onCellLongPress(int slotIndex) {
    if (_armedAction != null) return;
    final m = context.read<ShowModel>();
    if (m.liveConnected || slotIndex >= m.cuelists.length) return; // connected: the LPU's own hold
    final cl = m.cuelists[slotIndex];
    if (cl.state == PlaybackState.playing) m.releaseCuelist(cl.id);
  }

  // Called when a cuelist cell is tapped
  void _onCellTap(int slotIndex) {
    final m = context.read<ShowModel>();
    final cl = slotIndex < m.cuelists.length ? m.cuelists[slotIndex] : null;

    switch (_armedAction) {
      case 'edit':
        setState(() { _armedAction = null; });
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => EditScreen(cuelistIndex: slotIndex)))
            .then((_) { if (mounted) setState(() {}); });
        break;

      case 'release':
        setState(() { _armedAction = null; });
        if (cl != null) m.releaseCuelist(cl.id);
        break;

      case 'rename':
        setState(() { _armedAction = null; });
        if (cl == null) return;
        showDialog(
          context: context,
          builder: (_) => NameDialog(
            title: 'RENAME PLAYBACK',
            initial: cl.label,
            onOk: (name) => m.renameCuelist(cl.id, name),
          ),
        );
        break;

      case 'props':
        setState(() { _armedAction = null; });
        if (cl == null) return;
        showDialog(
            context: context,
            builder: (_) => _PlaybackPropsDialog(cuelist: cl));
        break;

      case 'swap':
        if (_swapFirst < 0) {
          // First tap: remember this slot
          setState(() => _swapFirst = slotIndex);
        } else if (_swapFirst == slotIndex) {
          // Tap same slot: cancel
          setState(() { _armedAction = null; _swapFirst = -1; });
        } else {
          // Second tap: swap the whole playbacks, like the reference app
          m.swapCuelists(_swapFirst, slotIndex);
          setState(() { _armedAction = null; _swapFirst = -1; });
        }
        break;

      default:
        // Normal: Go
        // (connected: sent as the tile was pressed and let go, _onCellDown)
        if (!m.liveConnected && cl != null && (cl.label.isNotEmpty || cl.cues.isNotEmpty)) {
          m.goCuelist(cl.id);
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ShowModel>();
    final barSlots = List.generate(8, (i) => _faderRow * 8 + i);
    final locked = model.patchCollision;

    return Scaffold(
      backgroundColor: AppColors.background,
      // The 8 faders follow one row of tiles (tinted). Change it with a
      // 3-finger swipe (touch), by tapping between tiles, or on Windows with
      // Ctrl + mouse wheel / Ctrl + two-finger slide on the touchpad.
      body: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
            _stepRow(e.scrollDelta.dy > 0 ? 1 : (e.scrollDelta.dy < 0 ? -1 : 0));
          }
        },
        // A touchpad's two-finger slide arrives as pan / zoom, not as a wheel.
        onPointerPanZoomStart: (_) => _panRows = 0,
        onPointerPanZoomUpdate: (e) {
          if (!HardwareKeyboard.instance.isControlPressed) return;
          _panRows += e.localPanDelta.dy;
          while (_panRows.abs() >= _panPerRow) {
            // fingers up = like the wheel turned down = next row
            _stepRow(_panRows < 0 ? 1 : -1);
            _panRows -= _panRows.sign * _panPerRow;
          }
        },
        child: Stack(
        children: [
          Column(
            children: [
              _TopBar(
                armedAction: _armedAction,
                onArmAction: _armAction,
                locked: locked,
              ),
              Expanded(
                child: Listener(
                  onPointerDown: (_) => setState(() => _activePointers++),
                  onPointerUp: (_) => setState(() => _activePointers--),
                  onPointerCancel: (_) => setState(() => _activePointers--),
                  child: GestureDetector(
                    onVerticalDragStart: (d) {
                      if (_activePointers >= 3) {
                        _dragStartY = d.localPosition.dy;
                        _dragStartRow = _faderRow;
                      }
                    },
                    onVerticalDragUpdate: (d) {
                      if (_activePointers >= 3) {
                        final delta = d.localPosition.dy - _dragStartY;
                        final rowDelta = (delta / 60).round();
                        final newRow =
                            (_dragStartRow - rowDelta).clamp(0, 7);
                        if (newRow != _faderRow) {
                          setState(() => _faderRow = newRow);
                        }
                      }
                    },
                    // DMX collision in PATCH: no playback changes (reference app).
                    child: AbsorbPointer(
                      absorbing: locked,
                      child: _CuelistGrid(
                      model: model,
                      armedAction: _armedAction,
                      swapFirst: _swapFirst,
                      faderRow: _faderRow,
                      onCellTap: _onCellTap,
                      onCellLongPress: _onCellLongPress,
                      onCellDown: _onCellDown,
                      onCellUp: _onCellUp,
                      onRowTap: (row) => setState(() => _faderRow = row),
                    ),
                    ),
                  ),
                ),
              ),
              AbsorbPointer(
                absorbing: locked,
                child: _FaderSection(
                model: model,
                barSlots: barSlots,
                getFader: _getFader,
                getKnob: _getKnob,
                isFlashing: (s) => _flashingSlots.contains(s),
                onFaderChanged: _setFader,
                onKnobChanged: _setKnob,
                onFlashStart: (slot, pid) => _flashStart(slot, pid),
                onFlashEnd: (slot, pid) => _flashEnd(slot, pid),
              ),
              ),
            ],
          ),
          if (model.blackout)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.97),
                child: const Center(
                  child: Text('BLACKOUT',
                      style: TextStyle(
                          color: Colors.red,
                          fontSize: 64,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8)),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  final String? armedAction;
  final void Function(String) onArmAction;

  /// A DMX collision in PATCH: EDIT, RELEASE, RENAME, SWAP and PROPS are off.
  final bool locked;

  const _TopBar({
    required this.armedAction,
    required this.onArmAction,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) => AppTopBar(
        connected: context.watch<ShowModel>().liveConnected,
        left: [
          _NavBtn(
              label: 'PATCH',
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const PatchScreen(initialTab: 0)))),
          _NavBtn(
              label: 'OPTIONS',
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const PatchScreen(initialTab: 1)))),
        ],
        right: [
          _ArmBtn(label: 'EDIT', armed: armedAction == 'edit', onTap: locked ? null : () => onArmAction('edit')),
          _ReleaseBtn(
              armed: armedAction == 'release',
              onTap: locked ? null : () => onArmAction('release'),
              onHoldComplete: locked
                  ? null
                  : () {
                      context.read<ShowModel>().releaseAll();
                      // Disarm the release button highlight
                      if (armedAction == 'release') onArmAction('release');
                    }),
          _ArmBtn(label: 'RENAME', armed: armedAction == 'rename', onTap: locked ? null : () => onArmAction('rename')),
          _ArmBtn(label: 'SWAP', armed: armedAction == 'swap', onTap: locked ? null : () => onArmAction('swap')),
          _ArmBtn(label: 'PROPS', armed: armedAction == 'props', onTap: locked ? null : () => onArmAction('props')),
        ],
      );
}

// The top bar buttons: the app's one button (widgets/app_button.dart).
class _NavBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NavBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => AppButton(label, onTap: onTap);
}

// A mode button (EDIT, RENAME, SWAP, PROPS) waiting for the playback to act
// on is lit, so the user sees which mode is active.
class _ArmBtn extends StatelessWidget {
  final String label;
  final bool armed;
  final VoidCallback? onTap;
  const _ArmBtn({required this.label, required this.armed, required this.onTap});

  @override
  Widget build(BuildContext context) => AppButton(label, lit: armed, onTap: onTap);
}

// ---------------------------------------------------------------------------
// Release button: tap = arm/disarm, hold 0.5 s = release all (like the real
// app: no progress shown and the button does not light up while held)
// ---------------------------------------------------------------------------

class _ReleaseBtn extends StatelessWidget {
  final bool armed;
  final VoidCallback? onTap;
  final VoidCallback? onHoldComplete;
  const _ReleaseBtn({required this.armed, required this.onTap, required this.onHoldComplete});

  // Flutter's long press fires after exactly 0.5 s.
  @override
  Widget build(BuildContext context) =>
      AppButton('RELEASE', lit: armed, onTap: onTap, onLongPress: onHoldComplete);
}

// ---------------------------------------------------------------------------
// Playback Properties Dialog
// ---------------------------------------------------------------------------

class _PlaybackPropsDialog extends StatefulWidget {
  final Cuelist cuelist;
  const _PlaybackPropsDialog({required this.cuelist});

  @override
  State<_PlaybackPropsDialog> createState() => _PlaybackPropsDialogState();
}

class _PlaybackPropsDialogState extends State<_PlaybackPropsDialog> {
  late bool _background;
  late bool _exclusive;
  late int _goMode;
  late int _repeat;

  @override
  void initState() {
    super.initState();
    _background = widget.cuelist.background;
    _exclusive = widget.cuelist.exclusive;
    _goMode = widget.cuelist.goMode.index;
    _repeat = widget.cuelist.repeatMode.index;
  }

  void _save() {
    final cl = widget.cuelist;
    final go = GoMode.values[_goMode], rep = RepeatMode.values[_repeat];
    // Only what changed (the model also sends it to the LPU when connected).
    context.read<ShowModel>().setCuelistProps(cl.id,
        background: _background != cl.background ? _background : null,
        exclusive: _exclusive != cl.exclusive ? _exclusive : null,
        goMode: go != cl.goMode ? go : null,
        repeatMode: rep != cl.repeatMode ? rep : null);
  }

  @override
  Widget build(BuildContext context) {
    return DialogPanel(
      title: 'PLAYBACK PROPERTIES',
      child: IntrinsicWidth(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row('Background', DialogCheckbox(value: _background,
              onChanged: (v) { setState(() => _background = v); _save(); })),
          const SizedBox(height: 10),
          _row('Exclusive', DialogCheckbox(value: _exclusive,
              onChanged: (v) { setState(() => _exclusive = v); _save(); })),
          const SizedBox(height: 14),
          _row('Go Mode', DialogSegments(options: const ['Go', 'Toggle', 'Flash', 'Solo'],
              selected: _goMode, onChanged: (i) { setState(() => _goMode = i); _save(); })),
          const SizedBox(height: 14),
          _row('Repeat', DialogSegments(options: const ['Loop', 'Bounce', 'Random', 'Off'],
              selected: _repeat, onChanged: (i) { setState(() => _repeat = i); _save(); })),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerRight,
            child: DialogButton('Close', onTap: () => Navigator.pop(context)),
          ),
        ],
      ),
      ),
    );
  }

  // Label right-aligned in front of its control, like the reference app.
  Widget _row(String label, Widget control) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 104,
          child: Text(label, textAlign: TextAlign.right, softWrap: false,
              style: const TextStyle(color: Color(0xFFD0D0D0), fontSize: 14)),
        ),
        const SizedBox(width: 12),
        control,
      ]);
}

/// How long a tile is held to release a holding playback.
const releaseHold = Duration(milliseconds: 800);

// ---------------------------------------------------------------------------
// 8x8 cuelist grid
// ---------------------------------------------------------------------------

class _CuelistGrid extends StatelessWidget {
  final ShowModel model;
  final String? armedAction;
  final int swapFirst;
  final int faderRow;
  final ValueChanged<int> onCellTap;
  final ValueChanged<int> onCellLongPress;
  final void Function(int slot, int pointer) onCellDown, onCellUp;
  final ValueChanged<int> onRowTap;

  const _CuelistGrid({
    required this.model,
    required this.armedAction,
    required this.swapFirst,
    required this.faderRow,
    required this.onCellTap,
    required this.onCellLongPress,
    required this.onCellDown,
    required this.onCellUp,
    required this.onRowTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF212123), // between the tiles
      child: Column(
        children: List.generate(8, (row) {
          return Expanded(
            child: GestureDetector(
              onTap: () => onRowTap(row),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 1),
                // The row the faders follow has a dark navy background (real
                // app); taps between tiles choose the row.
                color: row == faderRow ? const Color(0xFF151539) : Colors.transparent,
                child: Row(
                  children: List.generate(8, (col) {
                    final i = row * 8 + col;
                    final cl = i < model.cuelists.length
                        ? model.cuelists[i]
                        : null;
                    return Expanded(
                      // a tap, or a long press of [releaseHold] (the standard
                      // long press is fixed at 0.5 s)
                      child: Listener(
                        onPointerDown: (e) => onCellDown(i, e.pointer),
                        onPointerUp: (e) => onCellUp(i, e.pointer),
                        onPointerCancel: (e) => onCellUp(i, e.pointer),
                        child: RawGestureDetector(
                        gestures: {
                          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                              TapGestureRecognizer.new, (r) => r.onTap = () => onCellTap(i)),
                          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                              () => LongPressGestureRecognizer(duration: releaseHold),
                              (r) => r.onLongPress = () => onCellLongPress(i)),
                        },
                        child: cl == null
                            ? const SizedBox()
                            : _PlaybackTile(
                                slot: i,
                                cuelist: cl,
                                level: model.shownLevel(cl),
                                activeRow: row == faderRow,
                                swapFirst: armedAction == 'swap' && swapFirst == i,
                              ),
                      ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One playback tile
// ---------------------------------------------------------------------------

// Tile colours = the playback's state, like the reference app:
//   red     released (no active cue)
//   green   a cue's delay / fade is running (LPU cue phase 2)
//   yellow  the cue holds (phase 3)
//   orange  fading out after RELEASE (phase 4; only after a release)
// Empty slots are slate blue. Flat, with darker edges: (normal, in the row
// the faders follow - darker and bluish).
const _tileRed = (Color(0xFF711217), Color(0xFF470C32));
const _tileGreen = (Color(0xFF09722B), Color(0xFF06483E));
const _tileYellow = (Color(0xFF95660A), Color(0xFF5D402A));
const _tileOrange = (Color(0xFFB9480C), Color(0xFF742D2B));
const _tileEmpty = (Color(0xFF1E2E3E), Color(0xFF15213A));

/// The names on a tile, like the reference app: the playback's and the running
/// cue's when both fit in [width] x [height], else only the cue's. Without a
/// cue name (idle, or an unnamed cue) the playback's.
List<String> tileLines(String playback, String cue,
    {required double width, required double height, required double fontSize}) {
  if (cue.isEmpty) return [playback];
  double lines(String text) {
    final p = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize, height: 1.15)),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout(maxWidth: width);
    final h = p.height;
    p.dispose();
    return h;
  }

  return lines(playback) + lines(cue) <= height ? [playback, cue] : [cue];
}

class _PlaybackTile extends StatefulWidget {
  final int slot;
  final Cuelist cuelist;
  final double level; // 0..1, as the fader shows it
  final bool activeRow; // in the row the 8 faders follow
  final bool swapFirst; // first playback chosen for SWAP
  const _PlaybackTile({
    required this.slot,
    required this.cuelist,
    required this.level,
    required this.activeRow,
    required this.swapFirst,
  });

  @override
  State<_PlaybackTile> createState() => _PlaybackTileState();
}

class _PlaybackTileState extends State<_PlaybackTile> {
  // How long "Intensity xx %" / "Speed xx %" stays after a change.
  static const _show = Duration(milliseconds: 1500);
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  /// 'Intensity' / 'Speed' while it was changed less than [_show] ago.
  String? _changing(Cuelist cl) {
    final now = DateTime.now();
    final l = cl.levelChangedAt, s = cl.speedChangedAt;
    final latest = [l, s].whereType<DateTime>().fold<DateTime?>(
        null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (latest == null) return null;
    final left = _show - now.difference(latest);
    if (left <= Duration.zero) return null;
    _hide?.cancel();
    _hide = Timer(left, () {
      if (mounted) setState(() {});
    });
    return latest == s ? 'Speed' : 'Intensity';
  }

  @override
  Widget build(BuildContext context) {
    final cl = widget.cuelist;
    final hasContent = cl.label.isNotEmpty || cl.cues.isNotEmpty;
    final base = !hasContent
        ? _tileEmpty
        : switch (cl.state) {
            PlaybackState.releasing => _tileOrange,
            PlaybackState.playing => cl.fading ? _tileGreen : _tileYellow,
            _ => _tileRed,
          };
    final fill = widget.activeRow ? base.$2 : base.$1;
    final edge = Color.lerp(fill, Colors.black, 0.35)!;
    final active = cl.state == PlaybackState.playing || cl.state == PlaybackState.releasing;
    final changing = _changing(cl);
    // Text dimmer in the active row too, like the reference app.
    final textColour = Colors.white.withOpacity(
        hasContent ? (widget.activeRow ? 0.72 : 1.0) : (widget.activeRow ? 0.38 : 0.54));

    return Container(
      margin: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        // Flat, darkening over the last few pixels at the top and bottom.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [edge, fill, fill, edge],
          stops: const [0.0, 0.1, 0.9, 1.0],
        ),
        border: Border.all(
            color: widget.swapFirst ? const Color(0xFF4A8AEA) : edge,
            width: widget.swapFirst ? 2.5 : 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: CustomPaint(
        painter: _TileLevelPainter(level: widget.level, speed: cl.liveSpeed),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 2, 9, 2),
          // Text sized from the tile width, so names fit narrow tiles too
          // instead of breaking inside words (full size from ~75 px).
          child: LayoutBuilder(builder: (context, box) {
            final f = (box.maxWidth / 75).clamp(0.7, 1.0);
            return changing != null
              // While the fader / knob moves: what changed, instead of the name.
              ? Center(
                  child: Text(
                    changing == 'Speed'
                        ? 'Speed\n${(cl.liveSpeed * 100).round()}%'
                        : 'Intensity\n${(widget.level * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textColour, fontSize: 11 * f, height: 1.3),
                  ),
                )
              // Pinned to the top and bottom instead of stacked: low tiles
              // (short windows) can never overflow, the lines just get closer.
              : Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 2,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final line in tileLines(
                            cl.label.isNotEmpty ? cl.label : '${widget.slot + 1}',
                            active && cl.currentCueIndex >= 0 && cl.currentCueIndex < cl.cues.length
                                ? cl.cues[cl.currentCueIndex].label
                                : '',
                            width: box.maxWidth,
                            // above the cue counter (about one line of 11 * f)
                            height: box.maxHeight - 2 - 14 * f,
                            fontSize: 12 * f,
                          ))
                            Text(
                              line,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: textColour, fontSize: 12 * f, height: 1.15),
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Text(
                        cl.cues.isEmpty
                            ? '- / -'
                            : active
                                ? '${cl.currentCueIndex + 1} / ${cl.cues.length}'
                                : '- / ${cl.cues.length}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: textColour.withOpacity(0.85), fontSize: 11 * f),
                      ),
                    ),
                  ],
                );
          }),
        ),
      ),
    );
  }
}

// The small ticks on a tile's edges, like the reference app: left = intensity
// (lit from the bottom up to the fader level), right = speed (lit up from
// the middle for faster, down for slower; nothing at normal speed).
class _TileLevelPainter extends CustomPainter {
  final double level; // 0..1
  final double speed; // -1..1
  const _TileLevelPainter({required this.level, required this.speed});

  static const _ticks = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final lit = Paint()
      ..color = Colors.white.withOpacity(0.75)
      ..strokeWidth = 1;
    final dim = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 1;
    final top = size.height * 0.18, bottom = size.height * 0.82;
    final step = (bottom - top) / (_ticks - 1);
    final on = (level * _ticks).round();
    for (var t = 0; t < _ticks; t++) {
      final y = bottom - t * step;
      canvas.drawLine(Offset(3, y), Offset(7, y), t < on ? lit : dim);
    }
    final half = _ticks ~/ 2;
    final n = (speed.abs() * half).round();
    final mid = (top + bottom) / 2;
    for (var t = 1; t <= n; t++) {
      final y = speed > 0 ? mid - t * step : mid + t * step;
      canvas.drawLine(Offset(size.width - 7, y), Offset(size.width - 3, y), lit);
    }
  }

  @override
  bool shouldRepaint(_TileLevelPainter old) => old.level != level || old.speed != speed;
}

// ---------------------------------------------------------------------------
// Fader section
// ---------------------------------------------------------------------------
// Like the reference app: 8 strips, each in its own dark rounded panel with the
// LED, the speed knob with its LED ring, the fader and FLASH. Everything is
// drawn in code and sized from the space it gets, so it scales with the
// window (no fixed pictures).

class _FaderSection extends StatelessWidget {
  final ShowModel model;
  final List<int> barSlots;
  final double Function(int slot) getFader;
  final double Function(int slot) getKnob;
  final bool Function(int slot) isFlashing;
  final void Function(int slot, double v) onFaderChanged;
  final void Function(int slot, double v) onKnobChanged;
  final void Function(int slot, int pointerId) onFlashStart;
  final void Function(int slot, int pointerId) onFlashEnd;

  const _FaderSection({
    required this.model,
    required this.barSlots,
    required this.getFader,
    required this.getKnob,
    required this.isFlashing,
    required this.onFaderChanged,
    required this.onKnobChanged,
    required this.onFlashStart,
    required this.onFlashEnd,
  });

  @override
  Widget build(BuildContext context) {
    // A third of the window (reference app at 768 x 1024: ~330 px).
    final h = (MediaQuery.of(context).size.height * 0.33).clamp(200.0, 420.0);
    return Container(
      height: h,
      color: const Color(0xFF0C0C0C),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: barSlots.map((slot) {
          final cl = slot < model.cuelists.length ? model.cuelists[slot] : null;
          return Expanded(
            child: _FaderStrip(
              faderValue: getFader(slot),
              knobValue: getKnob(slot),
              flashing: isFlashing(slot),
              isPlaying: cl?.state == PlaybackState.playing,
              onFaderChanged: (v) => onFaderChanged(slot, v),
              onKnobChanged: (v) => onKnobChanged(slot, v),
              onFlashStart: (pid) => onFlashStart(slot, pid),
              onFlashEnd: (pid) => onFlashEnd(slot, pid),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _FaderStrip extends StatelessWidget {
  final double faderValue;
  final double knobValue;
  final bool flashing;
  final bool isPlaying;
  final ValueChanged<double> onFaderChanged;
  final ValueChanged<double> onKnobChanged;
  final void Function(int pointerId) onFlashStart;
  final void Function(int pointerId) onFlashEnd;

  const _FaderStrip({
    required this.faderValue,
    required this.knobValue,
    required this.flashing,
    required this.isPlaying,
    required this.onFaderChanged,
    required this.onKnobChanged,
    required this.onFlashStart,
    required this.onFlashEnd,
  });

  @override
  Widget build(BuildContext context) {
    final ledColor = flashing
        ? const Color(0xFF44FF44)
        : isPlaying
            ? const Color(0xFF4AA8FF)
            : const Color(0xFF1E3A55);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1.5), // same as the tiles: columns line up
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF242424), Color(0xFF161616)],
        ),
        border: Border.all(color: const Color(0xFF2E2E2E)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final knob = (box.maxWidth * 0.62).clamp(26.0, 64.0);
        return Column(
          children: [
            SizedBox(height: box.maxHeight * 0.025),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: ledColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: ledColor.withOpacity(0.8), blurRadius: flashing || isPlaying ? 8 : 2)
                ],
              ),
            ),
            SizedBox(height: box.maxHeight * 0.015),
            _RotaryKnob(value: knobValue, size: knob, onChanged: onKnobChanged),
            Expanded(child: _Fader(value: faderValue, onChanged: onFaderChanged)),
            _FlashButton(onFlashStart: onFlashStart, onFlashEnd: onFlashEnd),
          ],
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Fader: a cap in a slot with a scale on both sides, drawn in code (any size).
// Dragging moves it relative to where it was grabbed, so it never jumps.
// ---------------------------------------------------------------------------

class _Fader extends StatefulWidget {
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  const _Fader({required this.value, required this.onChanged});

  @override
  State<_Fader> createState() => _FaderState();
}

class _FaderState extends State<_Fader> {
  double _startValue = 0, _startY = 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final travel = _FaderPainter.travel(box.biggest);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            _startValue = widget.value;
            _startY = d.localPosition.dy;
          },
          onVerticalDragUpdate: (d) {
            if (travel <= 0) return;
            widget.onChanged((_startValue + (_startY - d.localPosition.dy) / travel).clamp(0.0, 1.0));
          },
          child: CustomPaint(size: box.biggest, painter: _FaderPainter(widget.value)),
        );
      });
}

class _FaderPainter extends CustomPainter {
  final double value;
  const _FaderPainter(this.value);

  static double capHeight(Size s) => (s.width * 0.30).clamp(14.0, 34.0);
  static double _margin(Size s) => capHeight(s) / 2 + s.height * 0.04;
  static double travel(Size s) => s.height - 2 * _margin(s);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final m = _margin(size), top = m, bottom = size.height - m;
    // scale: ticks on both sides, a longer one every fifth
    final tick = Paint()
      ..color = const Color(0xFF6A6A6A)
      ..strokeWidth = 1;
    final slotW = (size.width * 0.06).clamp(3.0, 6.0);
    final tickGap = slotW + size.width * 0.07;
    for (var i = 0; i <= 10; i++) {
      final y = bottom - (bottom - top) * i / 10;
      final len = size.width * (i % 5 == 0 ? 0.13 : 0.08);
      canvas.drawLine(Offset(cx - tickGap - len, y), Offset(cx - tickGap, y), tick);
      canvas.drawLine(Offset(cx + tickGap, y), Offset(cx + tickGap + len, y), tick);
    }
    // slot
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - slotW / 2, top - 4, cx + slotW / 2, bottom + 4), Radius.circular(slotW / 2)),
        Paint()..color = Colors.black);
    // cap
    final capW = (size.width * 0.56).clamp(22.0, 60.0);
    final capH = capHeight(size);
    final y = bottom - (bottom - top) * value.clamp(0.0, 1.0);
    final cap = Rect.fromCenter(center: Offset(cx, y), width: capW, height: capH);
    canvas.drawRRect(RRect.fromRectAndRadius(cap.shift(const Offset(0, 2)), const Radius.circular(3)),
        Paint()
          ..color = Colors.black54
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawRRect(
        RRect.fromRectAndRadius(cap, const Radius.circular(3)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF5A5A5A), Color(0xFF2A2A2A), Color(0xFF1A1A1A), Color(0xFF3A3A3A)],
            stops: [0.0, 0.45, 0.55, 1.0],
          ).createShader(cap));
    // grip lines and the light centre stripe
    final grip = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..strokeWidth = 1;
    for (final f in [0.22, 0.34, 0.66, 0.78]) {
      final gy = cap.top + cap.height * f;
      canvas.drawLine(Offset(cap.left + 3, gy), Offset(cap.right - 3, gy), grip);
    }
    canvas.drawLine(Offset(cap.left + 2, y), Offset(cap.right - 2, y),
        Paint()
          ..color = const Color(0xFFE8E8E8)
          ..strokeWidth = (capH * 0.08).clamp(1.5, 3.0));
  }

  @override
  bool shouldRepaint(_FaderPainter old) => old.value != value;
}

// ---------------------------------------------------------------------------
// Flash button: isolated StatefulWidget to hold pointer state independently
// of parent rebuilds. Tracks the down-pointer by ID; only that pointer can
// end the flash, preventing spurious releases on Windows mouse events.
// ---------------------------------------------------------------------------

class _FlashButton extends StatefulWidget {
  final void Function(int pointerId) onFlashStart;
  final void Function(int pointerId) onFlashEnd;

  const _FlashButton({
    required this.onFlashStart,
    required this.onFlashEnd,
  });

  @override
  State<_FlashButton> createState() => _FlashButtonState();
}

class _FlashButtonState extends State<_FlashButton> {
  int? _activePointer;

  @override
  Widget build(BuildContext context) {
    final down = _activePointer != null;
    return Listener(
      onPointerDown: (e) {
        if (_activePointer != null) return; // already pressed
        setState(() { _activePointer = e.pointer; });
        widget.onFlashStart(e.pointer);
      },
      onPointerUp: (e) {
        if (_activePointer != e.pointer) return;
        setState(() { _activePointer = null; });
        widget.onFlashEnd(e.pointer);
      },
      onPointerCancel: (e) {
        if (_activePointer != e.pointer) return;
        setState(() { _activePointer = null; });
        widget.onFlashEnd(e.pointer);
      },
      // Rounded and outlined, like the reference app.
      child: Container(
        height: 36,
        margin: const EdgeInsets.fromLTRB(6, 2, 6, 8),
        decoration: BoxDecoration(
          color: down ? const Color(0xFF3A3A3A) : const Color(0xFF1C1C1C),
          border: Border.all(color: down ? const Color(0xFFB0B0B0) : const Color(0xFF6A6A6A)),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('FLASH',
              style: TextStyle(color: down ? Colors.white : const Color(0xFFB4B4B4), fontSize: 13)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rotary knob (speed): a dark knob with a pointer, inside a ring of LED dots;
// the dot at the knob's position is lit (top = normal speed).
// ---------------------------------------------------------------------------

class _RotaryKnob extends StatefulWidget {
  final double value; // 0..1, 0.5 = normal speed
  final double size;
  final ValueChanged<double> onChanged;
  const _RotaryKnob({required this.value, required this.size, required this.onChanged});

  @override
  State<_RotaryKnob> createState() => _RotaryKnobState();
}

class _RotaryKnobState extends State<_RotaryKnob> {
  double _startY = 0;
  double _startValue = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: (d) {
        _startY = d.localPosition.dy;
        _startValue = widget.value;
      },
      onVerticalDragUpdate: (d) {
        final delta = (_startY - d.localPosition.dy) / 100.0;
        widget.onChanged((_startValue + delta).clamp(0.0, 1.0));
      },
      child: CustomPaint(
          size: Size.square(widget.size),
          painter: _KnobPainter(widget.value)),
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double value;
  _KnobPainter(this.value);

  static const _dots = 21;
  static const _start = 2.356; // 135 degrees: the ring runs over 270 degrees
  static const _sweep = 4.712;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringR = size.width / 2 - 2;
    final knobR = ringR * 0.72;
    // LED ring
    final lit = (value * (_dots - 1)).round();
    final dotR = (size.width * 0.03).clamp(1.0, 2.2);
    for (var i = 0; i < _dots; i++) {
      final a = _start + _sweep * i / (_dots - 1);
      final p = center + Offset(cos(a), sin(a)) * ringR;
      final on = i == lit;
      if (on) {
        canvas.drawCircle(p, dotR * 2.2,
            Paint()
              ..color = const Color(0xAA4AA8FF)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
      canvas.drawCircle(p, dotR, Paint()..color = on ? const Color(0xFF8FCBFF) : const Color(0xFF4A4A4A));
    }
    // knob
    canvas.drawCircle(center.translate(0, 2), knobR,
        Paint()
          ..color = Colors.black54
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    final rect = Rect.fromCircle(center: center, radius: knobR);
    canvas.drawCircle(
        center,
        knobR,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0xFF5A5A5A), Color(0xFF1A1A1A)],
            center: Alignment(-0.3, -0.3),
          ).createShader(rect));
    canvas.drawCircle(center, knobR,
        Paint()
          ..color = const Color(0xFF0A0A0A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    // pointer
    final a = _start + _sweep * value;
    canvas.drawLine(center + Offset(cos(a), sin(a)) * knobR * 0.35,
        center + Offset(cos(a), sin(a)) * knobR * 0.85,
        Paint()
          ..color = const Color(0xFFDDDDDD)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.value != value;
}
