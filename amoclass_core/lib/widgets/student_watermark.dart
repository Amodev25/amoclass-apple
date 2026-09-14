import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The student's name and password drawn over a lesson (video or PDF), so a
/// phone recording of the screen names the account it came from.
///
/// Showing the password is the owner's decision (2026-09-14): a seat works on
/// one device only, so a leaked password cannot open the course elsewhere, and
/// a visible password makes a recording impossible to disown.
///
/// Placement: it drifts across the frame at a calm, constant speed and never
/// stops (owner, 2026-09-14), bouncing off the edges on two different periods
/// so its path covers the frame instead of retracing one line. A still or
/// fixed-corner mark is cropped out in one edit. It never accepts touches, so
/// the player's controls underneath keep working. Put it as the LAST child of
/// the lesson's [Stack] so nothing — controls, overlays, fullscreen chrome —
/// draws over it.
class StudentWatermark extends StatefulWidget {
  const StudentWatermark({
    super.key,
    required this.name,
    this.password,
    this.horizontalCrossing = const Duration(seconds: 19),
    this.verticalCrossing = const Duration(seconds: 13),
    this.opacity = 0.85,
  });

  final String name;

  /// Null or empty for a session stored before passwords were kept; the name
  /// alone is drawn until the next login or re-verify stores it.
  final String? password;

  /// How long one edge-to-edge pass takes on each axis. Different on purpose.
  final Duration horizontalCrossing;
  final Duration verticalCrossing;

  final double opacity;

  @override
  State<StudentWatermark> createState() => _StudentWatermarkState();
}

class _StudentWatermarkState extends State<StudentWatermark>
    with SingleTickerProviderStateMixin {
  /// Where on each path this session starts, so two recordings of the same
  /// lesson do not show the mark in the same place at the same moment.
  final double _phaseX = math.Random().nextDouble() * 2;
  final double _phaseY = math.Random().nextDouble() * 2;

  final ValueNotifier<Duration> _elapsed = ValueNotifier(Duration.zero);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    // Deliberately ignores MediaQuery.disableAnimations: the movement is the
    // protection, not decoration.
    _ticker = createTicker((elapsed) => _elapsed.value = elapsed)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  /// A bounce between the edges of 85% of the frame: -0.85 → 0.85 → -0.85,
  /// one pass per [crossing], moving at the same speed the whole way.
  static double _bounce(Duration elapsed, Duration crossing, double phase) {
    final passes = elapsed.inMicroseconds / crossing.inMicroseconds + phase;
    final p = passes % 2.0;
    final t = p <= 1.0 ? p : 2.0 - p;
    return t * 1.7 - 0.85;
  }

  @override
  Widget build(BuildContext context) {
    final password = widget.password?.trim() ?? '';
    final shortest = MediaQuery.maybeOf(context)?.size.shortestSide ?? 400;
    final fontSize = (shortest * 0.021).clamp(10.0, 16.0);
    final style = TextStyle(
      color: const Color(0xFF000000),
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.25,
      decoration: TextDecoration.none,
      // Black text with a thin white outline (owner, 2026-09-14): lessons move
      // between dark video and white slides, and neither colour alone reads on
      // both. The outline is eight crisp shadows rather than a second stroked
      // Text, so each line stays one widget.
      shadows: const [
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(-1, -1)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(0, -1)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(1, -1)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(-1, 0)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(1, 0)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(-1, 1)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(0, 1)),
        Shadow(color: Color(0xFFFFFFFF), offset: Offset(1, 1)),
      ],
    );

    final mark = RepaintBoundary(
      child: Opacity(
        opacity: widget.opacity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.name, style: style, textAlign: TextAlign.center),
            if (password.isNotEmpty)
              // Passwords are Latin in practice; forcing LTR keeps an Arabic
              // UI from reordering digits and symbols.
              Text(
                password,
                style: style,
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
              ),
          ],
        ),
      ),
    );

    return IgnorePointer(
      child: ValueListenableBuilder<Duration>(
        valueListenable: _elapsed,
        // The text is built once; each frame only moves it.
        child: mark,
        builder: (context, elapsed, child) => Align(
          alignment: Alignment(
            _bounce(elapsed, widget.horizontalCrossing, _phaseX),
            _bounce(elapsed, widget.verticalCrossing, _phaseY),
          ),
          child: child,
        ),
      ),
    );
  }
}
