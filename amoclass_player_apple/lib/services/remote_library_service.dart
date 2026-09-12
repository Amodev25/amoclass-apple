import 'package:amo_core/amo_core.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';
import '../core/decryption_service.dart';

/// A remote file as returned by the teacher's cloud storage.
class RemoteFile {
  final int id;
  final String displayName;
  final String folderPath;
  final int fileSize;
  final String contentType;
  final bool isActive;
  final String uploadedAt;

  const RemoteFile({
    required this.id,
    required this.displayName,
    required this.folderPath,
    required this.fileSize,
    required this.contentType,
    required this.isActive,
    required this.uploadedAt,
  });

  factory RemoteFile.fromJson(Map<String, dynamic> j) => RemoteFile(
    id: (j['id'] as num).toInt(),
    displayName: j['display_name'] as String? ?? '',
    folderPath: (j['folder_path'] as String?) ?? '',
    fileSize: (j['file_size'] as num?)?.toInt() ?? 0,
    contentType: j['content_type'] as String? ?? 'application/octet-stream',
    isActive: ((j['is_active'] as num?)?.toInt() ?? 1) == 1,
    uploadedAt: j['uploaded_at'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'folder_path': folderPath,
    'file_size': fileSize,
    'content_type': contentType,
    'is_active': isActive ? 1 : 0,
    'uploaded_at': uploadedAt,
  };

  /// Whether this file looks like a video (based on extension/type).
  bool get isVideo {
    final ext = displayName.split('.').last.toLowerCase();
    return [
      'amo',
      'enc',
      'sec',
      'omx',
      'mp4',
      'mkv',
      'avi',
      'mov',
    ].contains(ext);
  }

  String get sizeLabel {
    if (fileSize == 0) return '—';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// The full catalog returned for a student's course.
class RemoteCatalog {
  final List<String> folders;
  final List<RemoteFile> files;

  const RemoteCatalog({required this.folders, required this.files});

  factory RemoteCatalog.empty() => const RemoteCatalog(folders: [], files: []);

  factory RemoteCatalog.fromJson(Map<String, dynamic> json) {
    return RemoteCatalog(
      folders: List<String>.from((json['folders'] as List?) ?? const []),
      files:
          (json['files'] as List<dynamic>?)
              ?.map((f) => RemoteFile.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    'folders': folders,
    'files': files.map((f) => f.toJson()).toList(),
  };

  /// Files in the root (no folder)
  List<RemoteFile> get rootFiles =>
      files.where((f) => f.folderPath.isEmpty).toList();

  /// Top-level folder names only
  List<String> get rootFolders =>
      folders.where((f) => !f.contains('/')).toList();

  /// Files inside a specific folder (direct children only)
  List<RemoteFile> filesInFolder(String folderPath) =>
      files.where((f) => f.folderPath == folderPath).toList();

  /// Sub-folders of a given folder path (direct children only)
  List<String> subFolders(String parent) => folders
      .where(
        (f) =>
            f.startsWith('$parent/') &&
            !f.substring(parent.length + 1).contains('/'),
      )
      .toList();
}

/// Service managing all R2 cloud storage operations on the student side.
class RemoteLibraryService {
  static final Dio _dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 30)),
  );

  static Future<File> _getCatalogCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final serverCode = AuthService.loggedInServerCode ?? 'default';
    return File('${dir.path}/amo_catalog_$serverCode.json');
  }

  /// Loads the previously cached catalog, if available.
  static Future<RemoteCatalog> loadCachedCatalog() async {
    try {
      final file = await _getCatalogCacheFile();
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        return RemoteCatalog.fromJson(
          jsonDecode(jsonString) as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    return RemoteCatalog.empty();
  }

  // ─── Fetch catalog ────────────────────────────────────────────────────────

  /// Fetches the full file listing from the server and caches it.
  /// Throws on network errors or non-200 responses so callers can show
  /// a meaningful error message. Returns an empty catalog when the server
  /// responds successfully but the course has no files.
  static Future<RemoteCatalog> fetchCatalog() async {
    final serverCode = AuthService.loggedInServerCode;
    final workerUrl = AuthService.workerUrl;
    final headers = AuthService.authHeaders;

    if (headers.isEmpty || serverCode == null) return RemoteCatalog.empty();

    late final dynamic responseData;
    late final int statusCode;
    try {
      final response = await _dio.get(
        '$workerUrl/storage/files',
        // `serverCode` still picks WHICH course; who is asking comes from the
        // token, which is why studentId is gone from the query.
        queryParameters: {'serverCode': serverCode},
        options: Options(headers: headers, validateStatus: (_) => true),
      );
      statusCode = response.statusCode ?? 0;
      responseData = response.data;
    } on DioException catch (e) {
      throw Exception(e.message ?? LocaleService.instance.strings.errNetwork);
    }

    // Dio returns a Map when Content-Type is application/json, a String otherwise.
    Map<String, dynamic>? responseMap;
    if (responseData is Map<String, dynamic>) {
      responseMap = responseData;
    } else if (responseData is String) {
      try {
        final decoded = jsonDecode(responseData);
        if (decoded is Map<String, dynamic>) responseMap = decoded;
      } catch (_) {}
    }

    if (statusCode != 200 || responseMap?['success'] != true) {
      throw AmoServerException(
        responseMap == null
            ? LocaleService.instance.strings.errServerStatus(statusCode)
            : localizeServerError(LocaleService.instance.strings, responseMap),
        responseMap?['code'] as String?,
      );
    }

    final data = responseMap!;
    final rawFiles = data['files'] as List<dynamic>;
    final rawFolders = data['folders'] as List<dynamic>;

    final catalog = RemoteCatalog(
      folders: rawFolders.map((f) => f.toString()).toList(),
      files: rawFiles
          .map((f) => RemoteFile.fromJson(f as Map<String, dynamic>))
          .toList(),
    );

    // Save to cache
    try {
      final file = await _getCatalogCacheFile();
      await file.writeAsString(jsonEncode(catalog.toJson()));
    } catch (_) {}

    return catalog;
  }

  // ─── Get download URL ─────────────────────────────────────────────────────

  /// Requests a short-lived (15-min) presigned R2 download URL for a file.
  static Future<String?> getDownloadUrl(int fileId) async {
    final workerUrl = AuthService.workerUrl;
    final headers = AuthService.authHeaders;

    if (headers.isEmpty) return null;

    try {
      final response = await _dio.get(
        '$workerUrl/storage/download-url',
        // Both the student and the course come from the token. `serverCode`
        // used to be sent here and was never checked server-side, which is
        // precisely why it is not sent any more.
        queryParameters: {'fileId': fileId},
        options: Options(headers: headers),
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        return response.data['downloadUrl'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ─── Check already downloaded ─────────────────────────────────────────────

  /// Returns the local file path if this remote file was already downloaded, null otherwise.
  static Future<String?> findLocalFile(RemoteFile file) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final candidate = File(
        '${dir.path}/AmoOnlineFiles/${_sanitize(file.displayName)}',
      );
      if (await candidate.exists()) return candidate.path;

      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final extCandidate = File(
            '${extDir.path}/AmoOnlineFiles/${_sanitize(file.displayName)}',
          );
          if (await extCandidate.exists()) return extCandidate.path;
        }
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  // ─── Download file ────────────────────────────────────────────────────────

  /// Downloads a remote file directly from R2 and imports it into the local library.
  /// [onProgress] callback receives values from 0.0 to 1.0.
  static Future<String?> downloadFile({
    required RemoteFile file,
    required void Function(double progress) onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      // Step 1: get presigned URL
      final url = await getDownloadUrl(file.id);
      if (url == null) {
        throw Exception(LocaleService.instance.strings.errDownloadUrlFailed);
      }

      // Step 2: choose download path
      final dir = await getApplicationDocumentsDirectory();
      final onlineDir = Directory('${dir.path}/AmoOnlineFiles');
      if (!await onlineDir.exists()) {
        await onlineDir.create(recursive: true);
      }
      final destPath = '${onlineDir.path}/${_sanitize(file.displayName)}';
      final destFile = File(destPath);

      int downloadedBytes = 0;
      if (await destFile.exists()) {
        downloadedBytes = await destFile.length();
      }

      if (downloadedBytes == file.fileSize && file.fileSize > 0) {
        onProgress(1.0);
      } else {
        // Step 3: download with progress and resumable support
        final response = await _dio.get<ResponseBody>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(minutes: 30),
            headers: downloadedBytes > 0
                ? {'Range': 'bytes=$downloadedBytes-'}
                : {},
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        if (response.statusCode == 416) {
          onProgress(1.0);
        } else if (response.statusCode == 200 || response.statusCode == 206) {
          final totalBytesStr =
              response.headers.value(Headers.contentLengthHeader) ?? '0';
          int lengthFromHeader = int.tryParse(totalBytesStr) ?? 0;

          // If server returns full file (200) instead of partial (206), discard existing logic
          if (response.statusCode == 200) {
            downloadedBytes = 0;
          }

          final totalExpectedBytes = lengthFromHeader + downloadedBytes;

          final raf = destFile.openSync(
            mode: downloadedBytes > 0 ? FileMode.append : FileMode.write,
          );
          int received = downloadedBytes;

          try {
            await for (var chunk in response.data!.stream) {
              raf.writeFromSync(chunk);
              received += chunk.length;
              if (totalExpectedBytes > 0) {
                onProgress(received / totalExpectedBytes);
              }
            }
          } finally {
            raf.closeSync();
          }
        } else {
          throw Exception(
            LocaleService.instance.strings.errDownloadHttp(
              response.statusCode ?? 0,
            ),
          );
        }
      }

      // Step 4: Security check - ensure it's for the correct course
      try {
        final header = await DecryptionService.parseHeader(destFile.path);
        if (header != null &&
            header.serverCode != null &&
            header.serverCode!.isNotEmpty) {
          final myCode = AuthService.loggedInServerCode;
          if (myCode == null || myCode != header.serverCode) {
            throw Exception(
              LocaleService.instance.strings.errWrongCourseContent,
            );
          }
        }
      } catch (e) {
        await destFile.delete().catchError((_) => destFile);
        throw Exception(LocaleService.instance.strings.errWrongCourseContent);
      }

      return destFile.path;
    } catch (e) {
      rethrow;
    }
  }

  // ─── Thumbnail preview (online tab) ───────────────────────────────────────

  /// Decrypted thumbnail previews keyed by file id. A cached null means
  /// "definitively no preview" (fetched OK but no embedded thumbnail or wrong
  /// key) and prevents repeat fetches. Transient failures are not cached.
  static final Map<int, Uint8List?> _thumbCache = {};

  /// Bytes range-fetched for a preview: header + metadata + thumbnail. A
  /// thumbnail is one small JPEG/PNG frame, so 96 KB covers almost all files in
  /// a single request; any larger thumbnail simply falls back to an icon.
  static const int _thumbPreviewBytes = 96 * 1024;

  /// Returns the decrypted thumbnail for a remote file, or null if none.
  ///
  /// If the file is already downloaded it is decrypted from disk; otherwise
  /// only the first [_thumbPreviewBytes] are range-fetched from R2 and
  /// decrypted in memory. The file stays encrypted at rest and the data key
  /// never leaves the device — same trust model as the offline tab.
  static Future<Uint8List?> fetchThumbnail(RemoteFile file) async {
    if (_thumbCache.containsKey(file.id)) return _thumbCache[file.id];

    // Already downloaded → decrypt locally, no network needed.
    final localPath = await findLocalFile(file);
    if (localPath != null) {
      final thumb = await DecryptionService.extractThumbnail(localPath);
      _thumbCache[file.id] = thumb;
      return thumb;
    }

    final url = await getDownloadUrl(file.id);
    if (url == null) return null; // transient — leave uncached for retry

    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${_thumbPreviewBytes - 1}'},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if (response.statusCode == 200 || response.statusCode == 206) {
        // Collect only up to _thumbPreviewBytes, then stop — bounds memory even
        // if the server ignores the Range header and starts a full-file body.
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream) {
          builder.add(chunk);
          if (builder.length >= _thumbPreviewBytes) break;
        }
        final thumb = DecryptionService.extractThumbnailFromBytes(
          builder.toBytes(),
        );
        _thumbCache[file.id] = thumb; // definitive result (may be null)
        return thumb;
      }
    } catch (_) {
      // Transient network error — leave uncached so it can be retried.
    }
    return null;
  }

  /// Clear cached previews (call on logout / course switch).
  static void clearThumbnailCache() => _thumbCache.clear();

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static Future<int> getLocalFileSize(String displayName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/AmoOnlineFiles/${_sanitize(displayName)}');
      if (await file.exists()) {
        return await file.length();
      }

      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final extFile = File(
          '${extDir.path}/AmoOnlineFiles/${_sanitize(displayName)}',
        );
        if (await extFile.exists()) return await extFile.length();
      }
    } catch (_) {}
    return 0;
  }

  static String _sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[/\\<>:"|?*]'), '_')
        .replaceAll('..', '_')
        .replaceAll('\x00', '');
  }
}
