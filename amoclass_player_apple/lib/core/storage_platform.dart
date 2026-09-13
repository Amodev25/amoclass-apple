import 'package:flutter/services.dart';

/// Free space on the volume holding a path, so an import can refuse up front
/// instead of failing half-way through copying a multi-gigabyte lecture.
///
/// Backed by the `com.lockclass/storage` channel: MainActivity.kt on Android,
/// AmoPlatformPlugin.m on iOS and macOS.
class StoragePlatform {
  static const _native = MethodChannel('com.lockclass/storage');

  /// Bytes available at [path], or null when that cannot be told. Callers
  /// treat null as "unknown" and let the import go ahead.
  static Future<int?> freeBytes(String path) async {
    try {
      final value = await _native.invokeMethod<num>('freeBytes', {
        'path': path,
      });
      return value?.toInt();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
