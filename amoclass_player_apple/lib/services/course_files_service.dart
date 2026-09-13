import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/decryption_service.dart';

/// What this device still holds for one course, so a student whose access has
/// ended can take the space back instead of carrying files nothing can play.
class CourseFilesService {
  static final RegExp _safeCode = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Every file stored for [serverCode]: the course folder (imports, index,
  /// previews) plus online downloads whose container header names that course.
  /// Online downloads share one folder across courses, which is why they are
  /// matched by header rather than by location.
  static Future<List<File>> filesFor(String serverCode) async {
    // The code becomes part of a path; anything but a plain code could point
    // outside the courses folder.
    if (!_safeCode.hasMatch(serverCode)) return const [];
    final files = <File>[];

    final courseDir = await _courseDir(serverCode);
    if (await courseDir.exists()) {
      await for (final entity in courseDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity);
      }
    }

    for (final dir in await _onlineDirs()) {
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final header = await DecryptionService.parseHeader(entity.path);
          if (header != null && header.serverCode == serverCode) {
            files.add(entity);
          }
        }
      } catch (_) {}
    }
    return files;
  }

  static Future<int> totalBytes(List<File> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  /// Deletes [files] and then the course folder itself.
  static Future<void> delete(String serverCode, List<File> files) async {
    if (!_safeCode.hasMatch(serverCode)) return;
    for (final file in files) {
      try {
        await file.delete();
      } catch (_) {}
    }
    try {
      final courseDir = await _courseDir(serverCode);
      if (await courseDir.exists()) await courseDir.delete(recursive: true);
    } catch (_) {}
    DecryptionService.clearHeaderCache();
    await _forgetServerCode(serverCode);
  }

  // ── Login code → course ───────────────────────────────────────────────────
  //
  // A student logs in with the course's short code, but files carry the
  // course's 12-character server code, and a refusal does not say which one
  // the short code belongs to. So the pairing is written down at each
  // successful login, and kept after sign-out: that is exactly when it is
  // needed.

  static const _loginCodesFile = 'course_login_codes.json';

  /// Records that [loginCode] opened [serverCodes].
  static Future<void> rememberLoginCode(
    String loginCode,
    Iterable<String> serverCodes,
  ) async {
    try {
      final codes = serverCodes.where(_safeCode.hasMatch).toSet();
      if (loginCode.isEmpty || codes.isEmpty) return;
      final map = await _readLoginCodes();
      map[loginCode] = ({...?map[loginCode], ...codes}).toList()..sort();
      await _writeLoginCodes(map);
    } catch (_) {}
  }

  /// The courses [loginCode] is known to open on this device. A 12-character
  /// code is already a server code (re-verify signs in with it).
  static Future<List<String>> serverCodesForLogin(String loginCode) async {
    try {
      final known = (await _readLoginCodes())[loginCode];
      if (known != null && known.isNotEmpty) return known;
    } catch (_) {}
    if (loginCode.length == 12 && _safeCode.hasMatch(loginCode)) {
      return [loginCode];
    }
    return const [];
  }

  static Future<void> _forgetServerCode(String serverCode) async {
    try {
      final map = await _readLoginCodes();
      var changed = false;
      for (final key in map.keys.toList()) {
        final codes = map[key]!;
        if (!codes.contains(serverCode)) continue;
        changed = true;
        final left = codes.where((c) => c != serverCode).toList();
        if (left.isEmpty) {
          map.remove(key);
        } else {
          map[key] = left;
        }
      }
      if (changed) await _writeLoginCodes(map);
    } catch (_) {}
  }

  static Future<File> _loginCodesPath() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/$_loginCodesFile');
  }

  static Future<Map<String, List<String>>> _readLoginCodes() async {
    final file = await _loginCodesPath();
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: [
              for (final code in entry.value as List)
                if (code is String) code,
            ],
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeLoginCodes(Map<String, List<String>> map) async {
    final file = await _loginCodesPath();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(map), flush: true);
    await tmp.rename(file.path);
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static Future<Directory> _courseDir(String serverCode) async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/courses/$serverCode');
  }

  /// Where the online tab saves downloads (see RemoteLibraryService).
  static Future<List<Directory>> _onlineDirs() async {
    final dirs = <Directory>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      dirs.add(Directory('${docs.path}/AmoOnlineFiles'));
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) dirs.add(Directory('${ext.path}/AmoOnlineFiles'));
      } catch (_) {}
    }
    return dirs;
  }
}
