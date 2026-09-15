import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The Lockclass mark: the word LOCK given a quarter turn and rebuilt as a
/// face. K on top, o and c as the eyes, L closing the jaw.
///
/// Drawn rather than shipped as an asset, for three reasons: it needs no
/// `flutter_svg` dependency, it stays sharp at every size on every DPI, and it
/// takes a [color] the way the web component takes `currentColor` — so one
/// widget serves a dark chip, a light sheet and a disabled state without a
/// second file.
///
/// The geometry is the web's `logo-mark.svg` verbatim, in its own design grid
/// (viewBox `12 2 96 116`). Do not "tidy" the numbers: the strokes are the four
/// letters at their real proportions, so moving one moves a letterform.
class LockMark extends StatelessWidget {
  const LockMark({super.key, this.size = 32, this.color, this.weight = 7.4});

  /// Width and height of the box the mark is drawn into. The mark is taller
  /// than it is wide, so it is fitted inside and centred.
  final double size;

  /// Defaults to the ambient icon colour, matching how an [Icon] behaves.
  final Color? color;

  /// Stroke width in design-grid units, so one value works at every [size].
  /// Small instances read better a little heavier: 6.6 above 48px, 7.4 around
  /// 32px, 9 at 20px and below.
  final double weight;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LockMarkPainter(color: resolved, weight: weight),
        isComplex: false,
      ),
    );
  }
}

class _LockMarkPainter extends CustomPainter {
  _LockMarkPainter({required this.color, required this.weight});

  final Color color;
  final double weight;

  // The design grid, straight from the SVG viewBox.
  static const double _vbX = 12;
  static const double _vbY = 2;
  static const double _vbW = 96;
  static const double _vbH = 116;

  @override
  void paint(Canvas canvas, Size size) {
    // Fit the grid inside the box and centre it, so a square [size] gives the
    // mark the same optical weight as an Icon of that size.
    final scale = math.min(size.width / _vbW, size.height / _vbH);
    canvas.save();
    canvas.translate(
      (size.width - _vbW * scale) / 2,
      (size.height - _vbH * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-_vbX, -_vbY);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = weight
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = true;

    // K: bar on top, arms descending to its ends.
    canvas.drawLine(const Offset(28, 16), const Offset(92, 16), paint);
    canvas.drawLine(const Offset(60, 16), const Offset(28, 46), paint);
    canvas.drawLine(const Offset(60, 16), const Offset(92, 46), paint);

    // o
    canvas.drawCircle(const Offset(41, 63), 14, paint);

    // c — the same circle with a 28 degree opening to the right. The SVG says
    // this as an elliptical arc between two points; the centre that arc implies
    // is (78.996, 63), and drawing it as a sweep keeps the gap exact.
    const gap = 28 * math.pi / 180;
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(78.996, 63), radius: 14),
      gap / 2, // start just below the 3 o'clock position
      2 * math.pi - gap, // all the way round, clockwise, minus the opening
      false,
      paint,
    );

    // L: foot along the bottom, riser at the right.
    final l = Path()
      ..moveTo(41, 105)
      ..lineTo(79, 105)
      ..lineTo(79, 81);
    canvas.drawPath(l, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_LockMarkPainter old) =>
      old.color != color || old.weight != weight;
}
