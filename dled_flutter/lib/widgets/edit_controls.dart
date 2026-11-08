// edit_controls.dart -- the controls of the EDIT page's bottom panel, drawn
// like the reference app: LED-segment channel faders, the colour square, the
// colour wheel and the pan / tilt pad.

import 'dart:math' as math;

import 'package:flutter/material.dart';

const _line = Color(0xFF8A8E96); // outline of the boxes
const _label = Color(0xFFB4B4B4);

/// One channel: a rounded box with its name, a column of LED segments (lit up
/// to the value) and the value (0-255) in a small box. Drag or tap in it to
/// set the value. Disabled (no selected fixture has the channel): an empty box.
class LedFader extends StatelessWidget {
  final String label;
  final double value; // 0-255
  final Color colour;
  final ValueChanged<double>? onChanged;
  const LedFader({super.key, required this.label, required this.value, required this.colour, this.onChanged});

  static const _top = 18.0, _bottom = 24.0; // label above, value box below

  void _set(Offset local, double height) {
    final span = height - _top - _bottom - 8;
    final f = 1 - (local.dy - _top - 4) / span;
    onChanged!(f.clamp(0.0, 1.0) * 255);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        onPanDown: enabled ? (d) => _set(d.localPosition, box.maxHeight) : null,
        onPanUpdate: enabled ? (d) => _set(d.localPosition, box.maxHeight) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(children: [
            Column(children: [
            SizedBox(
              height: _top,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, style: const TextStyle(color: _label, fontSize: 10)),
                ),
              ),
            ),
            Expanded(
              child: enabled
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                      child: CustomPaint(
                          size: Size.infinite, painter: _LedPainter(value / 255, colour)),
                    )
                  : const SizedBox(),
            ),
            SizedBox(
              height: _bottom,
              child: enabled
                  ? Container(
                      margin: const EdgeInsets.fromLTRB(2, 0, 2, 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: _line),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('${value.round()}', style: const TextStyle(color: _label, fontSize: 10)),
                      ),
                    )
                  : null,
            ),
            ]),
            // The handle, like the reference app: the value box's size and shape,
            // on the value box at 0 and sliding up to the top at 255.
            if (enabled)
              Positioned(
                left: 2,
                right: 2,
                height: _bottom - 3,
                top: (box.maxHeight - 2 - _bottom) - (box.maxHeight - 2 - _bottom - _top) * (value / 255).clamp(0.0, 1.0),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE6E6E6), width: 1.5),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _LedPainter extends CustomPainter {
  final double fraction;
  final Color colour;
  const _LedPainter(this.fraction, this.colour);

  // Like the reference app: the unlit segments only a dark tint of the colour
  // (2026-10-29: dark blue on blue was hard to read).
  @override
  void paint(Canvas canvas, Size size) {
    const seg = 3.0, gap = 2.0;
    final n = ((size.height + gap) / (seg + gap)).floor();
    final lit = (fraction * n).round();
    final on = Paint()..color = colour;
    final off = Paint()..color = Color.lerp(colour, Colors.black, 0.8)!;
    for (var i = 0; i < n; i++) {
      final y = size.height - (i + 1) * seg - i * gap;
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, seg), i < lit ? on : off);
    }
  }

  @override
  bool shouldRepaint(_LedPainter old) => old.fraction != fraction || old.colour != colour;
}

/// The colour of [hue] (0-360) at full saturation and brightness.
Color _hueColour(double hue) => HSVColor.fromAHSV(1, hue % 360, 1, 1).toColor();

/// The colour square: hue from left to right; white at the top, the pure
/// colour in the middle, black at the bottom. [r], [g], [b] are 0-255.
class ColourSquare extends StatelessWidget {
  final double r, g, b;
  final void Function(double r, double g, double b) onChanged;
  const ColourSquare({super.key, required this.r, required this.g, required this.b, required this.onChanged});

  static Color colourAt(double x, double y) {
    final pure = _hueColour(x * 360);
    return y <= 0.5 ? Color.lerp(Colors.white, pure, y / 0.5)! : Color.lerp(pure, Colors.black, (y - 0.5) / 0.5)!;
  }

  void _pick(Offset p, Size s) {
    final c = colourAt((p.dx / s.width).clamp(0.0, 0.999), (p.dy / s.height).clamp(0.0, 1.0));
    onChanged(c.r * 255, c.g * 255, c.b * 255);
  }

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(Color.fromARGB(255, r.round(), g.round(), b.round()));
    final x = hsv.hue / 360;
    final y = hsv.value < 0.999 ? 0.5 + (1 - hsv.value) / 2 : hsv.saturation / 2;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GestureDetector(
        onPanDown: (d) => _pick(d.localPosition, size),
        onPanUpdate: (d) => _pick(d.localPosition, size),
        child: CustomPaint(size: size, painter: _SquarePainter(Offset(x, y))),
      );
    });
  }
}

class _SquarePainter extends CustomPainter {
  final Offset at; // 0..1
  const _SquarePainter(this.at);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(colors: [for (var h = 0; h <= 360; h += 30) _hueColour(h.toDouble())])
              .createShader(rect));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0x00FFFFFF), Color(0x00000000), Colors.black],
            stops: [0, 0.5, 0.5, 1],
          ).createShader(rect));
    _marker(canvas, Offset(at.dx * size.width, at.dy * size.height));
  }

  @override
  bool shouldRepaint(_SquarePainter old) => old.at != at;
}

/// The colour wheel: hue around (red on the left, like the reference app), white in
/// the middle, the pure colour at the rim.
class ColourWheel extends StatelessWidget {
  final double r, g, b;
  final void Function(double r, double g, double b) onChanged;
  const ColourWheel({super.key, required this.r, required this.g, required this.b, required this.onChanged});

  // Screen angle (0 = right, clockwise) of a hue: red left, green upper right,
  // cyan right, blue lower right, magenta lower left.
  static double _angle(double hue) => (hue + 180) % 360 * math.pi / 180;

  void _pick(Offset p, Size s) {
    final c = s.center(Offset.zero);
    final radius = math.min(s.width, s.height) / 2;
    final d = p - c;
    final sat = (d.distance / radius).clamp(0.0, 1.0);
    final hue = (d.direction * 180 / math.pi - 180) % 360;
    final col = HSVColor.fromAHSV(1, hue, sat, 1).toColor();
    onChanged(col.r * 255, col.g * 255, col.b * 255);
  }

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(Color.fromARGB(255, r.round(), g.round(), b.round()));
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GestureDetector(
        onPanDown: (d) => _pick(d.localPosition, size),
        onPanUpdate: (d) => _pick(d.localPosition, size),
        child: CustomPaint(size: size, painter: _WheelPainter(hsv.hue, hsv.saturation)),
      );
    });
  }
}

class _WheelPainter extends CustomPainter {
  final double hue, saturation;
  const _WheelPainter(this.hue, this.saturation);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: c, radius: radius);
    canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = SweepGradient(colors: [
            // the hue at screen angle 0, 30, ... 360 degrees
            for (var a = 0; a <= 360; a += 30) _hueColour(a - 180.0),
          ]).createShader(rect));
    canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(rect));
    final a = ColourWheel._angle(hue);
    _marker(canvas, c + Offset(math.cos(a), math.sin(a)) * radius * saturation);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.hue != hue || old.saturation != saturation;
}

/// The picked point: a white rounded square, like the reference app.
void _marker(Canvas canvas, Offset at) => canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromCenter(center: at, width: 34, height: 34), const Radius.circular(6)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white);

/// The pan / tilt pad: a framed box; the dot is where pan / tilt are. Drag to
/// move; in fine mode the drag moves it slowly instead of jumping.
class PositionPad extends StatelessWidget {
  final double pan, tilt; // 0-255
  final bool fine;
  final void Function(double pan, double tilt)? onChanged;
  const PositionPad({super.key, required this.pan, required this.tilt, required this.fine, this.onChanged});

  void _move(Offset local, Offset? delta, Size s) {
    if (fine) {
      if (delta != null) {
        onChanged!((pan + delta.dx * 0.1).clamp(0.0, 255.0), (tilt - delta.dy * 0.1).clamp(0.0, 255.0));
      }
      return;
    }
    onChanged!((local.dx / s.width * 255).clamp(0.0, 255.0), ((1 - local.dy / s.height) * 255).clamp(0.0, 255.0));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GestureDetector(
        onPanDown: enabled ? (d) => _move(d.localPosition, null, size) : null,
        onPanUpdate: enabled ? (d) => _move(d.localPosition, d.delta, size) : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: enabled ? CustomPaint(size: size, painter: _PadPainter(pan / 255, 1 - tilt / 255)) : null,
        ),
      );
    });
  }
}

// Like the reference app: a 4 x 4 grid, a "+" where pan / tilt are, and the
// values (-100..100 around the centre, the reference app's scale) in boxes on the bottom edge (pan,
// following it sideways) and the right edge (tilt, following it up / down).
class _PadPainter extends CustomPainter {
  final double x, y; // 0..1, y down
  const _PadPainter(this.x, this.y);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFF5A5E66)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(size.width * i / 4, 0), Offset(size.width * i / 4, size.height), grid);
      canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), grid);
    }
    final p = Offset(x * size.width, y * size.height);
    final plus = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = 3;
    canvas.drawLine(p - const Offset(7, 0), p + const Offset(7, 0), plus);
    canvas.drawLine(p - const Offset(0, 7), p + const Offset(0, 7), plus);

    const w = 40.0, h = 34.0;
    _box(canvas, Rect.fromLTWH((p.dx - w / 2).clamp(2, size.width - w - 2), size.height - h - 2, w, h),
        '${(x * 200 - 100).round()}');
    _box(canvas, Rect.fromLTWH(size.width - w - 2, (p.dy - h / 2).clamp(2, size.height - h - 2), w, h),
        '${((1 - y) * 200 - 100).round()}');
  }

  void _box(Canvas canvas, Rect r, String value) {
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(6));
    canvas.drawRRect(rr, Paint()..color = const Color(0xFF151D26));
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = _line);
    final tp = TextPainter(
      text: TextSpan(
          text: value, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 11, fontFamily: 'DejaVuSans')),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_PadPainter old) => old.x != x || old.y != y;
}
