import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The student's name and password drawn over a lesson (video or PDF), so a
/// phone recording of the screen names the account it came from.
///
/// Showing the password is the owner's decision (2026-09-14): a seat works on
/// one device only, so a leaked password cannot open the course elsewhere, and
/// a visible password makes a recording impossible to disown.
///
/// Placement: it jumps to a new random spot every [interval] (a fixed corner
/// is cropped out in one edit) and never accepts touches, so the player's
/// controls underneath keep working. Put it as the LAST child of the lesson's
/// [Stack] so nothing — controls, overlays, fullscreen chrome — draws over it.
class StudentWatermark extends StatefulWidget {
  const StudentWatermark({
    super.key,
    required this.name,
    this.password,
    this.interval = const Duration(seconds: 25),
    this.opacity = 0.45,
  });

  final String name;

  /// Null or empty for a session stored before passwords were kept; the name
  /// alone is drawn until the next login or re-verify stores it.
  final String? password;

  final Duration interval;
  final double opacity;

  @override
  State<StudentWatermark> createState() => _StudentWatermarkState();
}

class _StudentWatermarkState extends State<StudentWatermark> {
  final _random = math.Random();
  Timer? _timer;
  Alignment _alignment = const Alignment(-0.6, -0.6);

  @override
  void initState() {
    super.initState();
    _alignment = _nextAlignment();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() => _alignment = _nextAlignment());
    });
  }

  @override
  void didUpdateWidget(StudentWatermark old) {
    super.didUpdateWidget(old);
    if (old.interval != widget.interval) {
      _timer?.cancel();
      _timer = Timer.periodic(widget.interval, (_) {
        if (mounted) setState(() => _alignment = _nextAlignment());
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Anywhere inside 85% of the frame, and never the spot it just left.
  Alignment _nextAlignment() {
    Alignment next;
    do {
      next = Alignment(
        _random.nextDouble() * 1.7 - 0.85,
        _random.nextDouble() * 1.7 - 0.85,
      );
    } while ((next.x - _alignment.x).abs() + (next.y - _alignment.y).abs() <
        0.6);
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final password = widget.password?.trim() ?? '';
    final media = MediaQuery.maybeOf(context);
    final shortest = media?.size.shortestSide ?? 400;
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

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedAlign(
          alignment: _alignment,
          duration: (media?.disableAnimations ?? false)
              ? Duration.zero
              : const Duration(milliseconds: 700),
          curve: Curves.easeInOut,
          child: Opacity(
            opacity: widget.opacity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.name, style: style, textAlign: TextAlign.center),
                if (password.isNotEmpty)
                  // Passwords are Latin in practice; forcing LTR keeps an
                  // Arabic UI from reordering digits and symbols.
                  Text(
                    password,
                    style: style,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
