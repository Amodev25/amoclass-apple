import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
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
///   blocked. The native side instead watches the screen's `isCaptured` and
///   covers the window while a recording is running. That is detection, not
///   prevention: frames can leak in the instant before the shield appears, and
///   a still screenshot is not caught at all.
///
/// Treat [isSupported] as "is real prevention available", which is why it is
/// false on iOS even though [enableProtection] still does useful work there.
class AntiCapture {
  static const _channel = MethodChannel('com.lockclass/anti_capture');

  /// Whether the window is protected RIGHT NOW, as reported by the native
  /// side — not whether protection was requested. Always false on iOS, where
  /// nothing is prevented. The player shows its "recording blocked" badge
  /// only while this is true.
  static final ValueNotifier<bool> protectedNow = ValueNotifier<bool>(false);

  /// Enable anti-screen capture.
  ///
  /// On macOS this prevents capture outright. It can be called before the
  /// window exists: the native side remembers the request and applies it when
  /// the window appears, so call it again after the first frame to refresh
  /// [protectedNow]. On iOS it installs the capture-detection shield, labelled
  /// with [message] (the localized text; English when omitted).
  static Future<bool> enableProtection({String? message}) async {
    bool ok;
    try {
      ok =
          await _channel.invokeMethod<bool>('enableProtection', {
            'message': ?message,
          }) ??
          false;
    } catch (e) {
      ok = false;
    }
    await refreshState();
    return ok;
  }

  /// Disable anti-screen capture.
  static Future<bool> disableProtection() async {
    bool ok;
    try {
      ok = await _channel.invokeMethod<bool>('disableProtection') ?? false;
    } catch (e) {
      ok = false;
    }
    await refreshState();
    return ok;
  }

  /// Re-reads the real protection state into [protectedNow].
  static Future<void> refreshState() async {
    if (!Platform.isMacOS) {
      protectedNow.value = false;
      return;
    }
    try {
      protectedNow.value =
          await _channel.invokeMethod<bool>('isProtected') ?? false;
    } catch (_) {
      protectedNow.value = false;
    }
  }

  /// True only where the platform can actually PREVENT a capture.
  ///
  /// iOS returns false on purpose: the shield is a mitigation, not a guarantee,
  /// and the UI must not promise the student's content cannot be recorded.
  static bool isSupported() => Platform.isMacOS;
}
