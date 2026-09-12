import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Focus Mode platform integration for Apple platforms.
///
/// This is where the Apple port diverges most from Android, and the difference
/// is a platform limit rather than missing work:
///
/// * **macOS** can approximate the lock. The native side sets kiosk
///   `NSApplicationPresentationOptions` — Dock and menu bar hidden, Cmd+Tab,
///   force quit and log-out blocked. It is weaker than Android's lock task:
///   process switching is only blocked when the app is NOT sandboxed, so a
///   sandboxed (App Store) build silently loses part of the lock.
///
/// * **iOS cannot do this at all.** An app cannot pin itself. Guided Access is
///   turned on by the student, and Single App Mode needs a supervised device
///   under MDM — neither is reachable from application code, and attempting to
///   fake it is a common App Store rejection. Every lock call below is a no-op
///   on iOS and [isSupported] is false, so the UI can hide the feature instead
///   of showing a lock that does not lock.
class FocusModePlatform {
  static const _channel = MethodChannel('com.lockclass/focus_mode');

  /// True only where the app can actually enforce a lock. False on iOS.
  static bool get isSupported => Platform.isMacOS;

  /// Neither Apple platform lets an app toggle Do Not Disturb. A Focus is set
  /// by the user, or via Focus Filters that the user must approve.
  static bool get supportsDnd => false;

  /// Full lock: kiosk presentation options (macOS only).
  static Future<void> lockApp() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('startLockTask');
    } catch (_) {}
  }

  /// Full unlock: restore the previous presentation options.
  static Future<void> unlockApp() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('stopLockTask');
    } catch (_) {}
  }

  /// Emergency unlock: drop the kiosk options but keep Focus Mode's own state,
  /// so the student can step out temporarily.
  static Future<void> emergencyUnlock() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('emergencyStart');
    } catch (_) {}
  }

  /// Re-lock after an emergency unlock.
  static Future<void> emergencyRelock() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('emergencyEnd');
    } catch (_) {}
  }

  // ── Do Not Disturb: unavailable on both platforms ────────────────────────

  static Future<void> enableDnd() async {}

  static Future<void> disableDnd() async {}

  static Future<bool> hasDndPermission() async => false;

  static Future<void> requestDndPermission() async {}
}
