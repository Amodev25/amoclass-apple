import 'package:amo_core/amo_core.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../core/decryption_service.dart';
import 'auth_service.dart';
import 'remote_library_service.dart';

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

  /// In-memory thumbnail cache. Max 50 entries to bound memory usage.
  static const int _maxThumbnailCache = 50;
  static final Map<String, Uint8List> _thumbnailCache = {};

  // ────────────── Cache clear (call on course switch / logout) ──
  static void clearCache() {
    _items = [];
    _loaded = false;
    _libraryPath = null;
    _appDataPath = null;
    _thumbnailCache.clear();
    RemoteLibraryService.clearThumbnailCache();
  }

  /// Get a cached thumbnail, or decrypt and cache it.
  static Future<Uint8List?> getCachedThumbnail(String filePath) async {
    final cached = _thumbnailCache[filePath];
    if (cached != null) return cached;

    final thumb = await DecryptionService.extractThumbnail(filePath);
    if (thumb != null) {
      // Evict oldest entry if cache is full
      if (_thumbnailCache.length >= _maxThumbnailCache) {
        _thumbnailCache.remove(_thumbnailCache.keys.first);
      }
      _thumbnailCache[filePath] = thumb;
    }
    return thumb;
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

    try {
      final path = await _getLibraryPath();
      final file = File(path);
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final jsonList = jsonDecode(jsonStr) as List<dynamic>;
        _items = [];

        for (final json in jsonList) {
          try {
            final item = VideoItem.fromJson(json as Map<String, dynamic>);
            if (await File(item.filePath).exists()) {
              final thumb = await getCachedThumbnail(item.filePath);

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
                  thumbnail: thumb,
                  folderName: cleanFolder,
                  contentType: item.contentType,
                  addedAt: item.addedAt,
                ),
              );
            }
          } catch (_) {
            // Skip a single malformed entry instead of dropping the whole
            // library — one corrupt record must not look like "no videos".
            needsResave = true;
            continue;
          }
        }
      }
    } catch (e) {
      _items = [];
    }

    _loaded = true;

    // Persist the cleaned data so legacy folder names are gone for good.
    if (needsResave) await _saveLibrary();

    return _items;
  }

  static Future<void> _saveLibrary() async {
    final path = await _getLibraryPath();
    final file = File(path);
    final jsonList = _items.map((v) => v.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonList));
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

    final thumbnail = await getCachedThumbnail(filePath);
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
      thumbnail: thumbnail,
      folderName: folderName,
      contentType: header.contentType,
    );

    _items.add(item);
    await _saveLibrary();
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

  /// Remove an item from the library (doesn't delete the file)
  static Future<void> removeVideo(String filePath) async {
    _items.removeWhere((v) => v.filePath == filePath);
    await _saveLibrary();
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
