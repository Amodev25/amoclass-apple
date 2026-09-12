import 'package:flutter/services.dart';

/// Detects whether headphones (wired / Bluetooth / USB) are an active audio
/// output. Used to gate video playback for courses with `requireHeadphones`.
///
/// Backed by a native MethodChannel implemented in
/// `android/app/src/main/kotlin/.../MainActivity.kt`.
class AudioOutputPlatform {
  static const _native = MethodChannel('com.lockclass/audio_output');

  /// True when private-listening hardware (wired / Bluetooth / USB headphones
  /// or headset) is connected as an active output.
  ///
  /// Fails OPEN: if the native side is missing or throws, returns true so a
  /// detection problem never wrongly blocks a student from their content.
  static Future<bool> headphonesConnected() async {
    try {
      return await _native.invokeMethod<bool>('headphonesConnected') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }
}
