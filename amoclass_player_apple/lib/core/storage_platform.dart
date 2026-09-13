import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thrown before a download starts when the volume cannot hold it.
class InsufficientStorageException implements Exception {
  final int neededBytes;
  final int availableBytes;

  const InsufficientStorageException(this.neededBytes, this.availableBytes);

  @override
  String toString() =>
      'InsufficientStorageException: need $neededBytes, have $availableBytes';
}

/// Free space and backup exclusion for the folders that hold course content.
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

  static final Set<String> _excluded = {};

  /// Marks the directory at [path] as excluded from iCloud backup (iOS) and
  /// Time Machine (macOS). Everything beneath it is excluded with it.
  ///
  /// Lesson files are re-downloadable and tied to this device's seat, so they
  /// must not ride along in a backup restored elsewhere. Best effort: a failure
  /// is not a reason to refuse the download. Idempotent and cached, so it is
  /// cheap to call every time the directory is ensured.
  static Future<void> excludeFromBackup(String path) async {
    if (!(Platform.isIOS || Platform.isMacOS)) return;
    if (_excluded.contains(path)) return;
    try {
      final ok = await _native.invokeMethod<bool>('excludeFromBackup', {
        'path': path,
      });
      if (ok == true) _excluded.add(path);
    } catch (_) {}
  }
}
