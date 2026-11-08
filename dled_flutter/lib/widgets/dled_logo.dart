// DLED's logo: a solid "D" with a white dot (a lamp) in a hole in its
// middle, then "LED" in round letters cut into 8 lying lines. All drawn, no
// font. The light page draws the same logo as an SVG
// (light/src/index.html, #dlogo) and tool/make_light_icons.py draws the D
// for the app icons.
//
// Units: the logo is 16 high and [_width] wide. The D fills 0..14.5; the
// letters start at 16.5 (L at 0, E at 13, D at 26 from there), drawn as lines
// 2 x [_h] thick with round ends, then clipped to the 8 stripes.

import 'package:flutter/material.dart';

/// DLED's colour.
const dledCyan = Color(0xFF29B6F6);

const double _width = 16.5 + 38.6;

class DledLogo extends StatelessWidget {
  /// [fontSize]: the size of the text the logo stands in for; the logo is
  /// as high as its capitals.
  const DledLogo({super.key, this.fontSize = 20});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final h = fontSize * 0.75;
    return Semantics(
      label: 'DLED',
      excludeSemantics: true,
      child: CustomPaint(size: Size(h * _width / 16, h), painter: const _LogoPainter()),
    );
  }
}

const double _h = 1.43; // half the letters' line width
const double _r = 3.5; // corner radius of L and E
const double _rr = 2.5; // corner radius of the D's left side
const double _bigR = 6.57; // the D's round side
const int _rows = 8;
const double _rowH = 1.25;

Path _letters() {
  const cx = 12.6 - _h - _bigR;
  // L
  final p = Path()
    ..moveTo(_h, _h)
    ..lineTo(_h, 16 - _h - _r)
    ..arcToPoint(const Offset(_h + _r, 16 - _h), radius: const Radius.circular(_r), clockwise: false)
    ..lineTo(9.6, 16 - _h);
  // E
  const e = 13.0;
  p
    ..moveTo(e + 9.6, _h)
    ..lineTo(e + _h + _r, _h)
    ..arcToPoint(const Offset(e + _h, _h + _r), radius: const Radius.circular(_r), clockwise: false)
    ..lineTo(e + _h, 16 - _h - _r)
    ..arcToPoint(const Offset(e + _h + _r, 16 - _h), radius: const Radius.circular(_r), clockwise: false)
    ..lineTo(e + 9.6, 16 - _h)
    ..moveTo(e + _h, 8)
    ..lineTo(e + 8.6, 8);
  // D
  const d = 26.0;
  p
    ..moveTo(d + _h + _rr, _h)
    ..lineTo(d + cx, _h)
    ..arcToPoint(const Offset(d + cx, 16 - _h), radius: const Radius.circular(_bigR))
    ..lineTo(d + _h + _rr, 16 - _h)
    ..arcToPoint(const Offset(d + _h, 16 - _h - _rr), radius: const Radius.circular(_rr))
    ..lineTo(d + _h, _h + _rr)
    ..arcToPoint(const Offset(d + _h + _rr, _h), radius: const Radius.circular(_rr))
    ..close();
  return p;
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.height / 16);
    final cyan = Paint()..color = dledCyan;

    // the D: straight left side, half circle to the right, a hole with the dot
    const c = Offset(6.5, 8);
    final mark = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(0, 0)
      ..lineTo(6.5, 0)
      ..arcToPoint(const Offset(6.5, 16), radius: const Radius.circular(8))
      ..lineTo(0, 16)
      ..close()
      ..addOval(Rect.fromCircle(center: c, radius: 2.6));
    canvas.drawPath(mark, cyan);
    canvas.drawCircle(c, 1.7, Paint()..color = Colors.white);

    // LED, cut into the stripes
    final stripes = Path();
    const step = (16 - _rowH) / (_rows - 1);
    for (var i = 0; i < _rows; i++) {
      stripes.addRect(Rect.fromLTWH(16, i * step, 40, _rowH));
    }
    canvas.clipPath(stripes);
    canvas.translate(16.5, 0);
    canvas.drawPath(
        _letters(),
        Paint()
          ..color = dledCyan
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * _h
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}
