import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Bridge to the native amo_stream library for in-process AES-CTR decryption.
///
/// Registers the "amo://" custom protocol with mpv so that .amo files
/// are decrypted inside the player process — no HTTP server, no temp files.
class AmoNativeBridge {
  static const _channel = MethodChannel('com.lockclass/amo_stream');

  /// A native yes/no read leniently. Objective-C boxes a C comparison
  /// (`@(ret == 0)`) as an int, which the channel delivers as 1/0; a strict
  /// `invokeMethod<bool>` threw on that and turned a stored key into "no key".
  @visibleForTesting
  static bool channelBool(Object? value) =>
      value == true || (value is num && value != 0);

  /// Register the amo:// protocol with the current mpv player instance.
  /// Must be called after Player() is created but before opening media.
  static Future<bool> registerProtocol(Player player) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        final mpvHandle = await platform.handle;

        final result = await _channel.invokeMethod<Object?>('registerProtocol', {
          'mpvHandle': mpvHandle,
        });
        if (kDebugMode) {
          debugPrint('[AmoNativeBridge] registerProtocol: $result');
        }
        return channelBool(result);
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

  /// Hand the course content key (64 hex digits, computed by the server) to
  /// the native decryptor. Call before playback.
  ///
  /// Returns false when the key is malformed or the native side is missing —
  /// and in that case the native side holds NO key, so a caller must not start
  /// playback on a false.
  static Future<bool> setContentKey(String contentKey) async {
    try {
      final ok = await _channel.invokeMethod<Object?>('setContentKey', {
        'contentKey': contentKey,
      });
      return channelBool(ok);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] setContentKey error: $e');
      }
      return false;
    }
  }

  /// Clear the content key from native memory (logout / course switch).
  static Future<void> clearContentKey() async {
    try {
      await _channel.invokeMethod('clearContentKey');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AmoNativeBridge] clearContentKey error: $e');
      }
    }
  }
}
