import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';
import '../core/app_build.dart';
import '../core/app_update_gate.dart';

/// Tracks video playback progress for resume and watched indicators.
/// Supports syncing progress to/from the server for cross-device continuity.
///
/// Keys are `<serverCode>/<file name>` ([keyFor]) — never an absolute local
/// path, which would both leak the device's folder layout to the server and
/// never match on another device (contract §3.12).
class ProgressService {
  static Map<String, dynamic> _data = {};
  static String? _filePath;
  static bool _syncing = false;

  static Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _filePath = '${dir.path}/amo_progress.json';
    final file = File(_filePath!);
    if (await file.exists()) {
      try {
        _data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        _data = {};
      }
    }
    if (_migrateKeys()) await _save();
  }

  /// The progress key for the lesson at [filePath] in the active course.
  static String keyFor(String filePath) {
    final course = AuthService.loggedInServerCode ?? '';
    return '$course/${_basename(filePath)}';
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }

  /// True when [key] looks like a local path rather than a relative key.
  @visibleForTesting
  static bool isAbsoluteKey(String key) =>
      key.startsWith('/') ||
      key.startsWith(r'\') ||
      key.startsWith('amo://') ||
      RegExp(r'^[A-Za-z]:[/\\]').hasMatch(key);

  static final RegExp _importedPath = RegExp(
    r'[/\\]courses[/\\]([A-Za-z0-9_-]+)[/\\](?:.*[/\\])?([^/\\]+)$',
  );

  /// Rewrites keys written by earlier builds (absolute paths). A path inside
  /// `courses/<serverCode>/` keeps its progress under the new key; any other
  /// absolute key is dropped. Returns whether anything changed.
  static bool _migrateKeys() {
    var changed = false;
    for (final key in _data.keys.toList()) {
      if (!isAbsoluteKey(key)) continue;
      final value = _data.remove(key);
      changed = true;
      final match = _importedPath.firstMatch(key);
      if (match == null) continue;
      final newKey = '${match.group(1)}/${match.group(2)}';
      _data.putIfAbsent(newKey, () => value);
    }
    return changed;
  }

  /// Now, as UTC ISO-8601 with a trailing `Z`. The worker clamps an
  /// `updated_at` more than 5 minutes in the future, and a zone-less local
  /// time from a UTC+2/+3 device reads as exactly that.
  static String _nowUtc() => DateTime.now().toUtc().toIso8601String();

  /// [value] as a UTC instant. A string without a zone (written by earlier
  /// builds as local time) is read as local time and converted; null when
  /// unparseable.
  @visibleForTesting
  static DateTime? parseTimestamp(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  /// [value] re-expressed as UTC ISO-8601 with `Z`, or now when unparseable.
  static String _toUtcIso(Object? value) =>
      parseTimestamp(value)?.toIso8601String() ?? _nowUtc();

  /// Save current playback position for a file.
  static Future<void> savePosition(
    String key, {
    required int positionMs,
    required int durationMs,
  }) async {
    if (durationMs <= 0) return;
    final progress = positionMs / durationMs;
    _data[key] = {
      'positionMs': positionMs,
      'durationMs': durationMs,
      'progress': progress,
      'watched': progress >= 0.92,
      'timestamp': _nowUtc(),
    };
    await _save();
  }

  /// Mark a file as watched (e.g. when video completes).
  static Future<void> markWatched(String key, int durationMs) async {
    _data[key] = {
      'positionMs': durationMs,
      'durationMs': durationMs,
      'progress': 1.0,
      'watched': true,
      'timestamp': _nowUtc(),
    };
    await _save();
  }

  /// Get saved position in milliseconds. Returns 0 if none.
  static int getResumePosition(String key) {
    final entry = _data[key] as Map<String, dynamic>?;
    if (entry == null) return 0;
    final pos = entry['positionMs'] as int? ?? 0;
    if (entry['watched'] == true) return 0;
    if (pos < 3000) return 0;
    return pos;
  }

  /// Get progress fraction (0.0 – 1.0).
  static double getProgressFraction(String key) {
    final entry = _data[key] as Map<String, dynamic>?;
    if (entry == null) return 0.0;
    return (entry['progress'] as num?)?.toDouble() ?? 0.0;
  }

  /// Whether the file has been watched (>= 92% or marked complete).
  static bool isWatched(String key) {
    final entry = _data[key] as Map<String, dynamic>?;
    return entry?['watched'] == true;
  }

  /// Sync local progress with server. Merges by latest timestamp.
  /// Safe to call offline — silently fails without disrupting local data.
  /// A 401 is ignored here (the session checks send the student to
  /// re-verify); a 426 raises the update dialog.
  static Future<void> syncToServer() async {
    if (_syncing) return;
    // The token identifies the student now; without one there is nobody to
    // sync as, and the server would answer 401.
    final token = AuthService.activeSessionToken;
    if (token == null) return;

    _syncing = true;
    try {
      final items = <Map<String, dynamic>>[];
      _data.forEach((key, value) {
        if (isAbsoluteKey(key)) return;
        if (value is Map<String, dynamic>) {
          items.add({
            'file_key': key,
            'position_ms': value['positionMs'] ?? 0,
            'duration_ms': value['durationMs'] ?? 0,
            'progress': value['progress'] ?? 0.0,
            'watched': value['watched'] == true,
            'updated_at': _toUtcIso(value['timestamp']),
          });
        }
      });

      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('${AuthService.workerUrl}/api/progress'),
        );
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $token');
        req.headers.set(kAppBuildHeader, '$kAppBuild');
        req.write(jsonEncode({'items': items}));
        final response = await req.close();
        final body = await response.transform(utf8.decoder).join();

        if (response.statusCode == 426) {
          AppUpdateGate.report();
          return;
        }

        if (response.statusCode == 200) {
          final json = jsonDecode(body);
          final merged = json['merged'] as List<dynamic>?;

          if (merged != null) {
            for (final item in merged) {
              final fileKey = item['file_key'] as String;
              if (isAbsoluteKey(fileKey)) continue;
              // Compared as instants, not strings: a zone-less local value
              // and a UTC `Z` value do not sort correctly as text.
              final serverTime = parseTimestamp(item['updated_at']);
              if (serverTime == null) continue;
              final localEntry = _data[fileKey] as Map<String, dynamic>?;
              final localTime = parseTimestamp(localEntry?['timestamp']);

              if (localTime == null || serverTime.isAfter(localTime)) {
                _data[fileKey] = {
                  'positionMs': item['position_ms'],
                  'durationMs': item['duration_ms'],
                  'progress': item['progress'],
                  'watched': item['watched'] == true,
                  'timestamp': serverTime.toIso8601String(),
                };
              }
            }
            await _save();
          }
        }
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AMO] Progress sync failed: $e');
    } finally {
      _syncing = false;
    }
  }

  static Future<void> _save() async {
    if (_filePath == null) return;
    await File(_filePath!).writeAsString(jsonEncode(_data));
  }
}
