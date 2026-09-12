import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Bridge to the native amo_stream library for in-process AES-CTR decryption.
///
/// Registers the "amo://" custom protocol with mpv so that .amo files
/// are decrypted inside the player process — no HTTP server, no temp files.
class AmoNativeBridge {
  static const _channel = MethodChannel('com.lockclass/amo_stream');

  /// Register the amo:// protocol with the current mpv player instance.
  /// Must be called after Player() is created but before opening media.
  static Future<bool> registerProtocol(Player player) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        final mpvHandle = await platform.handle;

        final result = await _channel.invokeMethod<bool>('registerProtocol', {
          'mpvHandle': mpvHandle,
        });
        if (kDebugMode) {
          debugPrint('[AmoNativeBridge] registerProtocol: $result');
        }
        return result ?? false;
      }
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] platform is not NativePlayer');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] registerProtocol error: $e');
      }
      return false;
    }
  }

  /// Set credentials for v2 key derivation (call before playback).
  static Future<void> setCredentials(
    String credential,
    String courseSecret,
  ) async {
    try {
      await _channel.invokeMethod('setCredentials', {
        'credential': credential,
        'courseSecret': courseSecret,
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] setCredentials error: $e');
      }
    }
  }

  /// Clear credentials from native memory (call on logout/course switch).
  static Future<void> clearCredentials() async {
    try {
      await _channel.invokeMethod('clearCredentials');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] clearCredentials error: $e');
      }
    }
  }
}
