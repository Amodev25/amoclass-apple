import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Anti-Screen Capture Protection for Apple platforms.
///
/// The two platforms are NOT equivalent:
///
/// * **macOS** has a true analogue of Android's FLAG_SECURE. The native side
///   sets `NSWindowSharingNone`, so the window is excluded from screen sharing
///   and screen recording — the capture simply does not contain it.
///
/// * **iOS** has no such API. A screenshot or screen recording cannot be
///   blocked. The native side instead observes `UIScreen.isCaptured` and covers
///   the window while a recording is running. That is detection, not
///   prevention: frames can leak in the instant before the shield appears, and
///   a still screenshot is not caught at all.
///
/// Treat [isSupported] as "is real prevention available", which is why it is
/// false on iOS even though [enableProtection] still does useful work there.
class AntiCapture {
  static const _channel = MethodChannel('com.lockclass/anti_capture');

  /// Enable anti-screen capture.
  ///
  /// On macOS this prevents capture outright. On iOS it installs the
  /// capture-detection shield described above.
  static Future<bool> enableProtection() async {
    try {
      final result = await _channel.invokeMethod<bool>('enableProtection');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Disable anti-screen capture.
  static Future<bool> disableProtection() async {
    try {
      final result = await _channel.invokeMethod<bool>('disableProtection');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// True only where the platform can actually PREVENT a capture.
  ///
  /// iOS returns false on purpose: the shield is a mitigation, not a guarantee,
  /// and the UI must not promise the student's content cannot be recorded.
  static bool isSupported() => Platform.isMacOS;
}
