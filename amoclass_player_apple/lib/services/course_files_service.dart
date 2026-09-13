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
