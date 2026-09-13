import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_secure_storage.dart';

/// The device id sent with every login and verification.
///
/// The seat is bound to it, so it must be stable, and the server refuses
/// anything that does not match `^[A-Za-z0-9._:-]{8,128}$` with
/// `DEVICE_REQUIRED`. The literal `'unknown'` used to be sent when the native
/// side failed — which bound every such student to the same "device".
///
/// Order: the native id (Keychain-backed; identifierForVendor on iOS, a salted
/// hash of the hardware UUID on macOS) → a random UUID v4 generated once and
/// kept in the secure store → (only if the store itself fails) the same random
/// UUID for the rest of this process.
class DeviceIdentity {
  const DeviceIdentity._();

  static const _channel = MethodChannel('com.lockclass/anti_capture');
  static const _kFallbackId = 'amo_fallback_device_id';

  /// What the worker accepts.
  static final RegExp pattern = RegExp(r'^[A-Za-z0-9._:-]{8,128}$');

  static String? _cached;
  static Future<String>? _pending;

  static Future<String> get() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _resolve();
  }

  static Future<String> _resolve() async {
    try {
      final native = await _channel.invokeMethod<String>('getDeviceId');
      if (native != null && pattern.hasMatch(native)) {
        return _cached = native;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[DeviceIdentity] native id unavailable: $e');
    }

    try {
      final stored = await AppSecureStorage.instance.read(key: _kFallbackId);
      if (stored != null && pattern.hasMatch(stored)) {
        return _cached = stored;
      }
    } catch (_) {}

    final generated = uuidV4();
    try {
      await AppSecureStorage.instance.write(key: _kFallbackId, value: generated);
    } catch (_) {}
    return _cached = generated;
  }

  /// A random RFC 4122 version-4 UUID.
  @visibleForTesting
  static String uuidV4() {
    final random = Random.secure();
    final b = List<int>.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
