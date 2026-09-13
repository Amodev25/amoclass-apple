import 'package:amo_core/amo_core.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../core/decryption_service.dart';
import 'auth_service.dart';

/// Manages the media library (encrypted videos and PDFs)
class LibraryService {
  /// Sanitize filename - remove path traversal attempts
  static String _sanitizeFileName(String name) {
    // Remove any directory separators
    name = name.replaceAll(RegExp(r'[/\\]'), '_');
    // Remove path traversal
    name = name.replaceAll('..', '_');
    // Remove null bytes
    name = name.replaceAll('\x00', '');
    // Remove other dangerous characters
    name = name.replaceAll(RegExp(r'[<>:"|?*]'), '_');
    // Ensure not empty
    if (name.trim().isEmpty) name = 'unnamed';
    return name;
  }

  static List<VideoItem> _items = [];
  static bool _loaded = false;
  static String? _libraryPath;
  static String? _appDataPath;

  /// Previews for both tabs, local and online. Kept on disk inside the
  /// course's app-private folder, so they are produced once per item rather
  /// than on every launch.
  static final ThumbnailStore thumbnails = ThumbnailStore(
    directory: getThumbnailsDir,
  );

  // ────────────── Cache clear (call on course switch / logout) ──
  static void clearCache() {
    _items = [];
    _loaded = false;
    _libraryPath = null;
    _appDataPath = null;
    thumbnails.clearMemory();
  }

  /// Preview for a local item.
  ///
  /// The first request decrypts it and checks the file's HMAC; later ones read
  /// the stored copy. A changed size or modification time produces it again.
  /// Playback does not rely on this check: it verifies the HMAC itself.
  static Future<Uint8List?> getThumbnail(
    String filePath, {
    bool Function()? stillWanted,
  }) async {
    final FileStat stat;
    try {
      stat = await File(filePath).stat();
    } catch (_) {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;
    return thumbnails.get(
      ThumbnailStore.idFor('l', filePath),
      '${stat.size}-${stat.modified.millisecondsSinceEpoch}',
      () => DecryptionService.extractThumbnail(filePath),
      stillWanted: stillWanted,
    );
  }

  /// Deletes every stored preview, for every course on this device. Called on
  /// logout: previews are plain images, so they must not outlive the session
  /// that was entitled to see them.
  static Future<void> purgeThumbnails() async {
    thumbnails.clearMemory();
    try {
      final appDir = await getApplicationSupportDirectory();
      final candidates = <Directory>[Directory('${appDir.path}/Thumbnails')];
      final courses = Directory('${appDir.path}/courses');
      if (await courses.exists()) {
        await for (final course in courses.list(followLinks: false)) {
          if (course is Directory) {
            candidates.add(Directory('${course.path}/Thumbnails'));
          }
        }
      }
      for (final dir in candidates) {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  // ────────────── Paths ──────────────────────────────────────

  static Future<String> _getAppDataPath() async {
    if (_appDataPath != null) return _appDataPath!;
    final appDir = await getApplicationSupportDirectory();
    // Per-course isolation: each course stores its files under courses/{serverCode}/
    final serverCode = AuthService.loggedInServerCode;
    if (serverCode != null && serverCode.isNotEmpty) {
      _appDataPath = '${appDir.path}/courses/$serverCode';
    } else {
      _appDataPath = appDir.path;
    }
    // Ensure directory exists
    final dir = Directory(_appDataPath!);
    if (!await dir.exists()) await dir.create(recursive: true);
    return _appDataPath!;
  }

  static Future<String> _getLibraryPath() async {
    if (_libraryPath != null) return _libraryPath!;
    final appDir = await _getAppDataPath();
    _libraryPath = '$appDir/amo_library.json';
    return _libraryPath!;
  }

  /// Returns the directory where videos are stored (copies of imported files)
  static Future<String> getVideosDir() async {
    final appDir = await _getAppDataPath();
    final dir = Directory('$appDir/Videos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Returns the directory where documents (PDFs) are stored
  static Future<String> getDocumentsDir() async {
    final appDir = await _getAppDataPath();
    final dir = Directory('$appDir/Documents');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Where previews are stored. Application Support, never Documents: on iOS
  /// Documents is visible in the Files app.
  static Future<Directory> getThumbnailsDir() async {
    final appDir = await _getAppDataPath();
    final dir = Directory('$appDir/Thumbnails');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ────────────── Load / Save ────────────────────────────────

  /// Auto-generated folder names used in old versions — treated as no folder.
  static const _legacyAutoFolders = {'Videos', 'Documents'};

  /// Strips the old auto-folder name from a JSON map (migration helper).
  static String? _migratedFolder(String? raw) {
    if (raw == null || _legacyAutoFolders.contains(raw)) return null;
    return raw;
  }

  static Future<List<VideoItem>> loadLibrary() async {
    if (_loaded) return _items;

    bool needsResave = false;
    List<dynamic>? jsonList;

    try {
      final file = File(await _getLibraryPath());
      if (await file.exists()) {
        try {
          jsonList = jsonDecode(await file.readAsString()) as List<dynamic>;
        } catch (_) {
          // The index is unreadable. This used to leave the library empty,
          // and the next import then saved that empty list over the index:
          // every earlier item gone for good, its file still on disk. Move
          // the broken file aside instead and rebuild from the files, which
          // each carry their own name, folder and course in the header.
          await _setAside(file);
        }
      }
    } catch (_) {}

    if (jsonList == null) {
      _items = await _rebuildFromDisk();
      needsResave = _items.isNotEmpty;
    } else {
      final parsed = <VideoItem>[];
      for (final json in jsonList) {
        try {
          parsed.add(VideoItem.fromJson(json as Map<String, dynamic>));
        } catch (_) {
          // Skip a single malformed entry instead of dropping the whole
          // library — one corrupt record must not look like "no videos".
          needsResave = true;
        }
      }

      // Nothing here opens the files themselves: previews load later, only
      // for the rows on screen. Existence checks run together.
      final exists = await Future.wait(
        parsed.map((item) => File(item.filePath).exists()),
      );

      _items = [];
      for (int i = 0; i < parsed.length; i++) {
        if (!exists[i]) continue;
        final item = parsed[i];

        // ── Migration: clear legacy auto-folder names ──────────
        final cleanFolder = _migratedFolder(item.folderName);
        if (cleanFolder != item.folderName) needsResave = true;

        _items.add(
          VideoItem(
            filePath: item.filePath,
            name: item.name,
            originalExtension: item.originalExtension,
            fileSize: item.fileSize,
            originalSize: item.originalSize,
            folderName: cleanFolder,
            contentType: item.contentType,
            addedAt: item.addedAt,
          ),
        );
      }
    }

    _loaded = true;

    // Persist the cleaned data so legacy folder names are gone for good.
    if (needsResave) await _saveLibrary();

    return _items;
  }

  /// Keeps an unreadable index next to the new one rather than deleting it.
  static Future<void> _setAside(File index) async {
    final aside =
        '${index.path}.unreadable-'
        '${DateTime.now().millisecondsSinceEpoch}';
    try {
      await index.rename(aside);
    } catch (_) {
      try {
        await index.copy(aside);
      } catch (_) {}
    }
  }

  /// Recreates the index from what is actually on disk.
  static Future<List<VideoItem>> _rebuildFromDisk() async {
    final myCode = AuthService.loggedInServerCode;
    final items = <VideoItem>[];
    for (final dirPath in [await getVideosDir(), await getDocumentsDir()]) {
      try {
        await for (final entity in Directory(dirPath).list()) {
          if (entity is! File) continue;
          final header = await DecryptionService.parseHeader(entity.path);
          if (header == null) continue;
          final code = header.serverCode;
          if (code != null && code.isNotEmpty && code != myCode) continue;
          final stat = await entity.stat();
          items.add(
            VideoItem(
              filePath: entity.path,
              name: header.videoName,
              originalExtension: header.originalExtension,
              fileSize: stat.size,
              originalSize: header.originalSize,
              folderName:
                  (header.folderName != null && header.folderName!.isNotEmpty)
                  ? header.folderName
                  : null,
              contentType: header.contentType,
              addedAt: stat.modified,
            ),
          );
        }
      } catch (_) {}
    }
    items.sort((a, b) => a.addedAt.compareTo(b.addedAt));
    return items;
  }

  static Future<void> _pendingSave = Future.value();

  /// Saves are queued so two of them never write the same temp file at once.
  static Future<void> _saveLibrary() {
    final next = _pendingSave.catchError((_) {}).then((_) => _writeIndex());
    _pendingSave = next;
    return next;
  }

  /// Writes the whole index to a temp file, then renames it over the real
  /// one. A rename is atomic, so if the app is killed mid-save the index on
  /// disk is the complete old version or the complete new one — never a
  /// truncated file.
  static Future<void> _writeIndex() async {
    final path = await _getLibraryPath();
    final tmp = File('$path.tmp');
    final jsonList = _items.map((v) => v.toJson()).toList();
    await tmp.writeAsString(jsonEncode(jsonList), flush: true);
    await tmp.rename(path);
  }

  // ────────────── Import ─────────────────────────────────────

  /// Add a file to the library. Copies it into the appropriate folder.
  /// [onProgress] receives 0.0–1.0 as the file is copied; omit for no tracking.
  static Future<VideoItem?> addVideo(
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    // Avoid duplicates by source path.
    if (_items.any((v) => v.filePath == filePath)) {
      return _items.firstWhere((v) => v.filePath == filePath);
    }

    final header = await DecryptionService.parseHeader(filePath);
    if (header == null) return null;

    // ── Server code gate ─────────────────────────────────────────────────────
    // If the file carries a server code, the logged-in code must match.
    if (header.serverCode != null && header.serverCode!.isNotEmpty) {
      final myCode = AuthService.loggedInServerCode;
      if (myCode == null || myCode != header.serverCode) {
        throw AmoWrongServerCodeException(
          LocaleService.instance.strings.libraryWrongServerCode(
            header.serverCode!,
            myCode ?? 'none',
          ),
        );
      }
    }

    final fileSize = await File(filePath).length();

    // Only use folder name if explicitly set in the encryptor header
    final isPdf = header.isPdf;
    final String? folderName =
        (header.folderName != null && header.folderName!.isNotEmpty)
        ? header.folderName!
        : null;

    // Copy file into organised directory to keep library self-contained
    final String targetDir = isPdf
        ? await getDocumentsDir()
        : await getVideosDir();

    final String rawFileName = filePath.split('/').last;
    final String fileName = _sanitizeFileName(rawFileName);
    final String destPath = '$targetDir/$fileName';

    // Only copy if not already inside the app data folder
    String storedPath = filePath;
    if (!filePath.startsWith(await _getAppDataPath())) {
      final destFile = File(destPath);
      if (!await destFile.exists()) {
        await _copyWithProgress(File(filePath), destFile, onProgress);
      } else {
        onProgress?.call(1.0);
      }
      storedPath = destPath;
    }

    final item = VideoItem(
      filePath: storedPath,
      name: header.videoName,
      originalExtension: header.originalExtension,
      fileSize: fileSize,
      originalSize: header.originalSize,
      folderName: folderName,
      contentType: header.contentType,
    );

    _items.add(item);
    await _saveLibrary();

    // Pay for the preview (and its HMAC check) now, while the import dialog
    // is up anyway, rather than on the library's first paint.
    if (!isPdf) await getThumbnail(storedPath);
    return item;
  }

  /// Chunked file copy with optional progress callbacks (0.0–1.0).
  static Future<void> _copyWithProgress(
    File source,
    File dest,
    void Function(double)? onProgress,
  ) async {
    final total = await source.length();
    if (total == 0) {
      await source.copy(dest.path);
      onProgress?.call(1.0);
      return;
    }
    final sink = dest.openWrite();
    int received = 0;
    double lastReported = 0.0;
    try {
      // addStream applies backpressure so all chunks are not buffered at once.
      await sink.addStream(
        source.openRead().map((chunk) {
          received += chunk.length;
          final p = received / total;
          // Throttle: report every 1 % or at completion.
          if (onProgress != null && (p - lastReported >= 0.01 || p >= 1.0)) {
            lastReported = p;
            onProgress(p);
          }
          return chunk;
        }),
      );
      await sink.flush();
      await sink.close();
    } catch (e) {
      // Clean up the partial destination so the next import attempt re-copies.
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Whether [path] is a private copy a mobile file picker made for this
  /// import, and therefore safe to delete once the import has its own copy.
  ///
  /// file_picker copies every pick into `cacheDir/file_picker/` on Android and
  /// into `NSTemporaryDirectory()` on iOS. Desktop pickers return the
  /// student's original file, which is never deleted.
  static Future<bool> isPickerCopy(String path) async {
    try {
      if (Platform.isAndroid) {
        final cache = (await getTemporaryDirectory()).path;
        return path.startsWith('$cache/file_picker/');
      }
      if (Platform.isIOS) {
        var tmp = Directory.systemTemp.path;
        if (!tmp.endsWith('/')) tmp = '$tmp/';
        return tmp.length > 8 && tmp.contains('/tmp/') && path.startsWith(tmp);
      }
    } catch (_) {}
    return false;
  }

  /// Remove an item from the library (doesn't delete the file)
  static Future<void> removeVideo(String filePath) async {
    _items.removeWhere((v) => v.filePath == filePath);
    await _saveLibrary();
    await thumbnails.remove(ThumbnailStore.idFor('l', filePath));
  }

  // ────────────── Query ──────────────────────────────────────

  static List<VideoItem> get videos => List.unmodifiable(_items);

  static List<VideoItem> get allVideos =>
      _items.where((v) => v.isVideo).toList();

  static List<VideoItem> get allDocuments =>
      _items.where((v) => v.isPdf).toList();

  /// Folder names that contain **video** items only
  static List<String> get videoFolderNames {
    final folders = <String>{};
    for (final v in _items.where((x) => x.isVideo)) {
      if (v.folderName != null && v.folderName!.isNotEmpty) {
        folders.add(v.folderName!);
      }
    }
    return folders.toList()..sort();
  }

  /// Folder names that contain **document / PDF** items only
  static List<String> get documentFolderNames {
    final folders = <String>{};
    for (final v in _items.where((x) => x.isPdf)) {
      if (v.folderName != null && v.folderName!.isNotEmpty) {
        folders.add(v.folderName!);
      }
    }
    return folders.toList()..sort();
  }

  /// Legacy: all folder names (kept for compatibility)
  static List<String> get folderNames => videoFolderNames;

  /// All video items inside a specific folder
  static List<VideoItem> videosInFolder(String folderName) {
    return _items
        .where((v) => v.isVideo && v.folderName == folderName)
        .toList();
  }

  /// All PDF items inside a specific folder
  static List<VideoItem> documentsInFolder(String folderName) {
    return _items.where((v) => v.isPdf && v.folderName == folderName).toList();
  }

  /// Video items that are NOT in any named folder
  static List<VideoItem> get rootVideos {
    return _items
        .where(
          (v) => v.isVideo && (v.folderName == null || v.folderName!.isEmpty),
        )
        .toList();
  }

  /// Document items that are NOT in any named folder
  static List<VideoItem> get rootDocuments {
    return _items
        .where(
          (v) => v.isPdf && (v.folderName == null || v.folderName!.isEmpty),
        )
        .toList();
  }
}
