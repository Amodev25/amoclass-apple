import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/focus_mode_platform.dart';

/// Manages Focus Mode state, timers, and emergency breaks.
///
/// Singleton — access via [FocusModeService.instance].
class FocusModeService extends ChangeNotifier {
  static final FocusModeService instance = FocusModeService._();
  FocusModeService._();

  bool _isActive = false;
  bool _isEmergencyActive = false;
  bool _isDndEnabled = false;

  Duration _focusDuration = Duration.zero;
  Duration _emergencyDuration = const Duration(minutes: 5);
  DateTime? _focusStartTime;
  DateTime? _emergencyStartTime;

  Timer? _tickTimer;

  // ── Getters ────────────────────────────────────────────────────────────────

  bool get isActive => _isActive;
  bool get isEmergencyActive => _isEmergencyActive;
  bool get isDndEnabled => _isDndEnabled;
  Duration get emergencyDuration => _emergencyDuration;

  Duration get remainingFocusTime {
    if (!_isActive || _focusStartTime == null) return Duration.zero;
    final elapsed = DateTime.now().difference(_focusStartTime!);
    final remaining = _focusDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Duration get remainingEmergencyTime {
    if (!_isEmergencyActive || _emergencyStartTime == null)
      return Duration.zero;
    final elapsed = DateTime.now().difference(_emergencyStartTime!);
    final remaining = _emergencyDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> startFocusMode({
    required Duration duration,
    Duration emergencyDuration = const Duration(minutes: 5),
    bool enableDnd = false,
  }) async {
    _focusDuration = duration;
    _emergencyDuration = emergencyDuration;
    _focusStartTime = DateTime.now();
    _isActive = true;
    _isDndEnabled = enableDnd;

    await FocusModePlatform.lockApp();
    if (enableDnd) await FocusModePlatform.enableDnd();

    _startTicking();
    notifyListeners();
  }

  Future<void> startEmergency() async {
    if (!_isActive || _isEmergencyActive) return;
    _isEmergencyActive = true;
    _emergencyStartTime = DateTime.now();

    // Partial unlock: allow other apps but prevent killing the player
    await FocusModePlatform.emergencyUnlock();
    notifyListeners();
  }

  Future<void> endEmergency() async {
    _isEmergencyActive = false;
    _emergencyStartTime = null;

    if (_isActive) await FocusModePlatform.emergencyRelock();
    notifyListeners();
  }

  Future<void> stopFocusMode() async {
    _isActive = false;
    _isEmergencyActive = false;
    _focusStartTime = null;
    _emergencyStartTime = null;
    _tickTimer?.cancel();

    await FocusModePlatform.unlockApp();
    if (_isDndEnabled) await FocusModePlatform.disableDnd();
    _isDndEnabled = false;

    notifyListeners();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _startTicking() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (remainingFocusTime <= Duration.zero) {
        stopFocusMode();
        return;
      }
      if (_isEmergencyActive && remainingEmergencyTime <= Duration.zero) {
        endEmergency();
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }
}
