import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';

/// Tracks video playback progress for resume and watched indicators.
/// Supports syncing progress to/from the server for cross-device continuity.
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
  }

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
      'timestamp': DateTime.now().toIso8601String(),
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
      'timestamp': DateTime.now().toIso8601String(),
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
        if (value is Map<String, dynamic>) {
          items.add({
            'file_key': key,
            'position_ms': value['positionMs'] ?? 0,
            'duration_ms': value['durationMs'] ?? 0,
            'progress': value['progress'] ?? 0.0,
            'watched': value['watched'] == true,
            'updated_at':
                value['timestamp'] ?? DateTime.now().toIso8601String(),
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
        req.write(jsonEncode({'items': items}));
        final response = await req.close();

        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final json = jsonDecode(body);
          final merged = json['merged'] as List<dynamic>?;

          if (merged != null) {
            for (final item in merged) {
              final fileKey = item['file_key'] as String;
              final serverTimestamp = item['updated_at'] as String;
              final localEntry = _data[fileKey] as Map<String, dynamic>?;
              final localTimestamp = localEntry?['timestamp'] as String?;

              if (localTimestamp == null ||
                  serverTimestamp.compareTo(localTimestamp) > 0) {
                _data[fileKey] = {
                  'positionMs': item['position_ms'],
                  'durationMs': item['duration_ms'],
                  'progress': item['progress'],
                  'watched': item['watched'] == true,
                  'timestamp': serverTimestamp,
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
