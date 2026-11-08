// fixture_grid.dart -- the 64-slot fixture grid of PATCH and EDIT (one look,
// one behaviour, like the reference app).
//
// Tap toggles a slot. Dragging selects a rectangle from the slot where the
// drag started to the slot under the pointer (1 -> 11 selects 1 2 3 and
// 9 10 11); starting on a selected slot deselects the rectangle instead.
// Slots that leave the rectangle while dragging go back to how they were.
// Every slot can be selected, patched or not (the reference app allows that too).

import 'package:flutter/material.dart';

import '../models/show_model.dart';
import 'app_theme.dart';

class FixtureGrid extends StatefulWidget {
  final List<FixturePatch> fixtures;
  final Set<int> selected;
  final ValueChanged<int> onToggle;
  final void Function(int slot, bool on) onSet;

  /// EDIT ([recorded] given, like the reference app): a selected slot gets a bold
  /// border, one in [recorded] (the loaded cue's fixtures) a thin one. The
  /// border is red for a recorded patched fixture, white otherwise: just
  /// selected, or an empty slot (never red). PATCH: selected = white.
  final Set<int>? recorded;

  /// Size of the number / name at the top of a tile.
  final double titleSize;

  /// Square tiles that scroll (PATCH), or 8 x 8 filling the space (EDIT).
  final bool square;
  const FixtureGrid({
    super.key,
    required this.fixtures,
    required this.selected,
    required this.onToggle,
    required this.onSet,
    this.recorded,
    this.titleSize = 14,
    this.square = true,
  });

  @override
  State<FixtureGrid> createState() => _FixtureGridState();
}

class _FixtureGridState extends State<FixtureGrid> {
  static const _cols = 8, _rows = 8, _gap = 4.0;
  final GlobalKey _gridKey = GlobalKey();
  int? _anchor;
  bool _dragDeselect = false;
  Set<int> _before = {};
  Set<int> _rect = {};

  int? _slotAt(Offset global, double cellW, double cellH) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global); // follows scrolling too
    final col = (local.dx / (cellW + _gap)).floor().clamp(0, _cols - 1);
    final row = (local.dy / (cellH + _gap)).floor().clamp(0, _rows - 1);
    return row * _cols + col;
  }

  void _dragTo(int slot) {
    final a = _anchor;
    if (a == null) return;
    final r0 = (a ~/ _cols) < (slot ~/ _cols) ? a ~/ _cols : slot ~/ _cols;
    final r1 = (a ~/ _cols) > (slot ~/ _cols) ? a ~/ _cols : slot ~/ _cols;
    final c0 = (a % _cols) < (slot % _cols) ? a % _cols : slot % _cols;
    final c1 = (a % _cols) > (slot % _cols) ? a % _cols : slot % _cols;
    final rect = {
      for (var r = r0; r <= r1; r++)
        for (var c = c0; c <= c1; c++) r * _cols + c,
    };
    for (final s in _rect.difference(rect)) {
      widget.onSet(s, _before.contains(s));
    }
    for (final s in rect) {
      widget.onSet(s, !_dragDeselect);
    }
    _rect = rect;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final cellW = (constraints.maxWidth - (_cols - 1) * _gap) / _cols;
        final cellH = widget.square ? cellW : (constraints.maxHeight - (_rows - 1) * _gap) / _rows;
        final bySlot = {for (final f in widget.fixtures) f.slot: f};
        final clash = collidingSlots(widget.fixtures);
        final grid = Wrap(
          key: _gridKey,
          spacing: _gap,
          runSpacing: _gap,
          children: List.generate(_cols * _rows, (i) {
            final sel = widget.selected.contains(i);
            final rec = widget.recorded?.contains(i) ?? false;
            final red = rec && (bySlot[i]?.isPatched ?? false);
            final edit = widget.recorded != null;
            return GestureDetector(
              onTap: () => widget.onToggle(i),
              onPanStart: (_) {
                _anchor = i;
                _before = {...widget.selected};
                _dragDeselect = widget.selected.contains(i);
                _rect = {};
                _dragTo(i);
              },
              onPanUpdate: (d) {
                final slot = _slotAt(d.globalPosition, cellW, cellH);
                if (slot != null) _dragTo(slot);
              },
              onPanEnd: (_) {
                _anchor = null;
                _rect = {};
              },
              child: Container(
                width: cellW,
                height: cellH,
                decoration: BoxDecoration(
                  color: sel ? const Color(0xFF243040) : AppColors.panel,
                  // Like the reference app: a thick border when selected, a light
                  // grey outline otherwise.
                  border: Border.all(
                      color: red
                          ? const Color(0xFFE02828)
                          : sel || rec
                              ? Colors.white
                              : const Color(0xFF5A5E66),
                      width: sel
                          ? (edit ? 3.5 : 2.5)
                          : rec
                              ? 1.5
                              : 1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _FixtureTileContent(
                    slot: i,
                    fixture: bySlot[i],
                    selected: sel,
                    flags: widget.square,
                    titleSize: widget.titleSize,
                    collides: clash.contains(i)),
              ),
            );
          }),
        );
        return widget.square ? SingleChildScrollView(child: grid) : grid;
      });
}

// One cell of the 64-slot patch grid, laid out like the reference app:
//   name (or slot number when unnamed), centred
//   manufacturer / model / mode
//   flags (P invert pan, T invert tilt, S swap, D virtual dimmer, '-' off) ... address
class _FixtureTileContent extends StatelessWidget {
  final int slot;
  final FixturePatch? fixture;
  final bool selected;

  /// The bottom row (flags, address): PATCH only; the real EDIT tile has none.
  final bool flags;
  final double titleSize;

  /// Its DMX channels overlap another fixture's: the address in red, bold.
  final bool collides;
  const _FixtureTileContent(
      {required this.slot,
      required this.fixture,
      required this.selected,
      this.flags = true,
      this.titleSize = 14,
      this.collides = false});

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    // Like the reference app the name *is* the number until a name is set.
    final title = f != null && f.label.isNotEmpty ? f.label : '${slot + 1}';
    final main = selected ? Colors.white : Colors.white70;
    final dim = selected ? Colors.white70 : Colors.white54;
    // Long text shrinks down to [minSize] (like the reference app), then gets "...".
    Widget line(String s,
            {double size = 11, double minSize = 7.5, Color? color, TextAlign align = TextAlign.left}) =>
        _FitText(s, size: size, minSize: minSize, align: align, color: color ?? dim);
    final flags = f == null
        ? '----'
        : '${f.invertPan ? 'P' : '-'}${f.invertTilt ? 'T' : '-'}'
            '${f.swapPanTilt ? 'S' : '-'}${f.virtualDimmer ? 'D' : '-'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(5, 3, 5, 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line(title, size: titleSize, minSize: 8, color: main, align: TextAlign.center),
          Expanded(
            child: f == null
                ? const SizedBox()
                : _TileInfo(lines: [
                    (f.manufacturer, 2),
                    (f.model, 3),
                    if (f.mode.isNotEmpty) (f.mode, 1),
                  ], color: dim),
          ),
          if (this.flags)
            Row(children: [
              Expanded(child: line(flags, color: main)),
              if (f != null)
                collides
                    ? Text('${f.address}',
                        style: const TextStyle(color: Color(0xFFFF2020), fontSize: 13, fontWeight: FontWeight.bold, height: 1.1))
                    : line('${f.address}', color: main),
            ]),
        ],
      ),
    );
  }
}

// The middle of a patch tile: manufacturer / model / mode, each allowed a few
// lines. Uses the largest font size (11 down to 7) at which everything fits
// the space between the title and the bottom row; only if even the smallest
// size does not fit, lines end in "...".
class _TileInfo extends StatelessWidget {
  final List<(String, int)> lines; // text, max lines
  final Color color;
  const _TileInfo({required this.lines, required this.color});

  static const double _max = 11, _min = 7;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final base = DefaultTextStyle.of(context).style; // the app font (measured like drawn)
        final scaler = MediaQuery.textScalerOf(context);
        TextStyle style(double s) => base.merge(TextStyle(color: color, fontSize: s, height: 1.1));
        bool fits(double s) {
          var h = 0.0;
          for (final (text, maxLines) in lines) {
            final tp = TextPainter(
                text: TextSpan(text: text, style: style(s)),
                maxLines: maxLines,
                textDirection: TextDirection.ltr,
                textScaler: scaler)
              ..layout(maxWidth: c.maxWidth);
            if (tp.didExceedMaxLines) return false;
            h += tp.height;
          }
          return h <= c.maxHeight;
        }

        var s = _max;
        while (s > _min && !fits(s)) {
          s -= 0.5;
        }
        // Cut off at the bottom when even the smallest size is too big (no
        // overflow warning: the lines may be taller than the space).
        return ClipRect(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (text, maxLines) in lines)
                  Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style(s)),
              ],
            ),
          ),
        );
      });
}

// One line of text that takes the largest font size between [minSize] and
// [size] at which it still fits the width. If it does not fit even at
// [minSize], the middle is replaced by "..." like the reference app
// ("Compact Par 18 Tri" -> "Compact...18 Tri").
class _FitText extends StatelessWidget {
  final String text;
  final double size, minSize;
  final TextAlign align;
  final Color color;
  const _FitText(this.text,
      {required this.size, required this.minSize, required this.align, required this.color});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        // Measure with the app font (DefaultTextStyle), exactly as it is drawn.
        final base = DefaultTextStyle.of(context).style;
        TextStyle style(double s) => base.merge(TextStyle(color: color, fontSize: s, height: 1.15));
        final scaler = MediaQuery.textScalerOf(context);
        double width(String t, double s) => (TextPainter(
                text: TextSpan(text: t, style: style(s)),
                maxLines: 1,
                textDirection: TextDirection.ltr,
                textScaler: scaler)
              ..layout())
            .width;
        var s = size;
        while (s > minSize && width(text, s) > c.maxWidth) {
          s -= 0.5;
        }
        if (s < minSize) s = minSize;
        var shown = text;
        if (width(text, s) > c.maxWidth) {
          // Keep as many characters as fit, split over the start and the end.
          for (var keep = text.length - 1; keep >= 2; keep--) {
            final head = (keep + 1) ~/ 2;
            final t = '${text.substring(0, head)}...${text.substring(text.length - (keep - head))}';
            if (width(t, s) <= c.maxWidth) {
              shown = t;
              break;
            }
          }
        }
        return Text(shown,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            textAlign: align,
            style: style(s));
      });
}

