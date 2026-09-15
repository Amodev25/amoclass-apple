import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';
import 'library_service.dart';
import '../core/app_update_gate.dart';
import '../core/decryption_service.dart';
import '../core/storage_platform.dart';

/// A remote file as returned by the teacher's cloud storage.
class RemoteFile {
  final int id;
  final String displayName;
  final String folderPath;
  final int fileSize;
  final String contentType;

  /// 'video' or 'pdf', from the catalogue's `kind` (read from the file header
  /// when it was uploaded). Rows cached before the field existed read 'video'.
  final String kind;
  final bool isActive;
  final String uploadedAt;

  const RemoteFile({
    required this.id,
    required this.displayName,
    required this.folderPath,
    required this.fileSize,
    required this.contentType,
    this.kind = 'video',
    required this.isActive,
    required this.uploadedAt,
  });

  factory RemoteFile.fromJson(Map<String, dynamic> j) => RemoteFile(
    id: (j['id'] as num).toInt(),
    displayName: j['display_name'] as String? ?? '',
    folderPath: (j['folder_path'] as String?) ?? '',
    fileSize: (j['file_size'] as num?)?.toInt() ?? 0,
    contentType: j['content_type'] as String? ?? 'application/octet-stream',
    kind: j['kind'] as String? ?? 'video',
    isActive: ((j['is_active'] as num?)?.toInt() ?? 1) == 1,
    uploadedAt: j['uploaded_at'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'folder_path': folderPath,
    'file_size': fileSize,
    'content_type': contentType,
    'kind': kind,
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

  /// Whether this file is a PDF lesson. The catalogue's [kind] decides; a PDF
  /// content type or a `.pdf` name (`notes.pdf`, `notes.pdf.amo`) also counts,
  /// for rows the server sent before it knew the kind.
  bool get isPdf {
    if (kind == 'pdf') return true;
    if (contentType.toLowerCase().contains('pdf')) return true;
    final parts = displayName.toLowerCase().split('.');
    if (parts.length < 2) return false;
    if (parts.last == 'pdf') return true;
    return parts.length >= 3 && parts[parts.length - 2] == 'pdf';
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

  /// Folder under Application Support that holds every course's downloads.
  static const String onlineFolderName = 'AmoOnlineFiles';

  /// Room kept free beyond the download itself.
  static const int _downloadHeadroomBytes = 100 * 1024 * 1024;

  static Future<File> _getCatalogCacheFile() async {
    // Inside the course's own folder (Application Support), never Documents:
    // on iOS Documents is visible in the Files app and backed up.
    final dir = await LibraryService.courseDataPath();
    return File('$dir/amo_catalog.json');
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

  /// Turns a worker refusal into an [AmoServerException] with its code.
  /// A 426 also raises the blocking update dialog; a 401 always carries
  /// `SESSION_INVALID`, so callers send the course to re-verify.
  static AmoServerException _refusal(int status, Map<String, dynamic>? body) {
    final strings = LocaleService.instance.strings;
    if (AppUpdateGate.isUpdateRequired(status, body)) {
      AppUpdateGate.report();
      return AmoServerException(
        strings.srvAppUpdateRequired,
        'APP_UPDATE_REQUIRED',
      );
    }
    if (status == 401) {
      return AmoServerException(strings.srvSessionInvalid, 'SESSION_INVALID');
    }
    final code = body?['code'];
    return AmoServerException(
      body == null
          ? strings.errServerStatus(status)
          : localizeServerError(strings, body),
      code is String ? code : null,
    );
  }

  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  // ─── Fetch catalog ────────────────────────────────────────────────────────

  /// Fetches the full file listing from the server and caches it.
  /// Throws on network errors or non-200 responses so callers can show
  /// a meaningful error message. Returns an empty catalog when the server
  /// responds successfully but the course has no files.
  static Future<RemoteCatalog> fetchCatalog() async {
    final serverCode = AuthService.loggedInServerCode;
    final workerUrl = AuthService.workerUrl;

    if (AuthService.activeSessionToken == null || serverCode == null) {
      return RemoteCatalog.empty();
    }

    late final dynamic responseData;
    late final int statusCode;
    try {
      final response = await _dio.get(
        '$workerUrl/storage/files',
        // `serverCode` still picks WHICH course; who is asking comes from the
        // token, which is why studentId is gone from the query.
        queryParameters: {'serverCode': serverCode},
        options: Options(
          headers: AuthService.workerHeaders,
          validateStatus: (_) => true,
        ),
      );
      statusCode = response.statusCode ?? 0;
      responseData = response.data;
    } on DioException catch (e) {
      throw Exception(e.message ?? LocaleService.instance.strings.errNetwork);
    }

    // Dio returns a Map when Content-Type is application/json, a String otherwise.
    final responseMap = _asMap(responseData);

    if (statusCode != 200 || responseMap?['success'] != true) {
      throw _refusal(statusCode, responseMap);
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
  ///
  /// Returns null when signed out or on a transport failure. A refusal from
  /// the worker throws [AmoServerException] with its code, so a download can
  /// say why (and a 401 can send the course to re-verify).
  static Future<String?> getDownloadUrl(int fileId) async {
    if (AuthService.activeSessionToken == null) return null;

    final Response<dynamic> response;
    try {
      response = await _dio.get(
        '${AuthService.workerUrl}/storage/download-url',
        // Both the student and the course come from the token. `serverCode`
        // used to be sent here and was never checked server-side, which is
        // precisely why it is not sent any more.
        queryParameters: {'fileId': fileId},
        options: Options(
          headers: AuthService.workerHeaders,
          validateStatus: (_) => true,
        ),
      );
    } catch (_) {
      return null;
    }

    final status = response.statusCode ?? 0;
    final body = _asMap(response.data);
    if (status == 200 && body?['success'] == true) {
      final url = body!['downloadUrl'];
      return url is String ? url : null;
    }
    if (status >= 500 || status == 0) return null;
    throw _refusal(status, body);
  }

  // ─── Where downloads live ─────────────────────────────────────────────────

  /// `<Application Support>/AmoOnlineFiles`, excluded from backup.
  static Future<Directory> onlineRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$onlineFolderName');
  }

  /// `AmoOnlineFiles/<courseId>/` for the active course — never one folder
  /// shared by every course (contract §3.8). A session restored from before
  /// course ids existed falls back to `code_<serverCode>` until its next
  /// verification supplies the id.
  static Future<Directory?> _activeCourseDir({bool create = false}) async {
    final courseId = AuthService.activeCourseId;
    final serverCode = AuthService.loggedInServerCode;
    final String name;
    if (courseId != null && courseId > 0) {
      name = '$courseId';
    } else if (serverCode != null &&
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(serverCode)) {
      name = 'code_$serverCode';
    } else {
      return null;
    }
    final root = await onlineRoot();
    final dir = Directory('${root.path}/$name');
    if (create) {
      if (!await dir.exists()) await dir.create(recursive: true);
      await StoragePlatform.excludeFromBackup(root.path);
    }
    return dir;
  }

  /// Removes what iOS builds before this change left in Documents, where the
  /// Files app showed it and iCloud backed it up: the shared download folder
  /// and the per-code catalog caches. Downloads are fetched again on demand.
  /// iOS only — on macOS (not sandboxed) Documents is the user's real folder.
  static Future<void> purgeLegacyDocuments() async {
    if (!Platform.isIOS) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final legacyDownloads = Directory('${docs.path}/$onlineFolderName');
      if (await legacyDownloads.exists()) {
        await legacyDownloads.delete(recursive: true);
      }
      await for (final entity in docs.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('amo_catalog_') && name.endsWith('.json')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ─── Check already downloaded ─────────────────────────────────────────────

  /// Returns the local file path if this remote file was completely
  /// downloaded, null otherwise. A partial download is not a playable file.
  static Future<String?> findLocalFile(RemoteFile file) async {
    try {
      final dir = await _activeCourseDir();
      if (dir == null) return null;
      final candidate = File('${dir.path}/${_sanitize(file.displayName)}');
      if (!await candidate.exists()) return null;
      if (file.fileSize > 0 && await candidate.length() < file.fileSize) {
        return null;
      }
      return candidate.path;
    } catch (_) {
      return null;
    }
  }

  // ─── Download file ────────────────────────────────────────────────────────

  /// Downloads a remote file directly from R2 and imports it into the local library.
  /// [onProgress] callback receives values from 0.0 to 1.0.
  ///
  /// Throws [InsufficientStorageException] before any byte is fetched when the
  /// volume cannot hold the rest of the file.
  static Future<String?> downloadFile({
    required RemoteFile file,
    required void Function(double progress) onProgress,
    CancelToken? cancelToken,
  }) async {
    // Step 1: choose download path (per course)
    final onlineDir = await _activeCourseDir(create: true);
    if (onlineDir == null) {
      throw Exception(LocaleService.instance.strings.errDownloadUrlFailed);
    }
    final destPath = '${onlineDir.path}/${_sanitize(file.displayName)}';
    final destFile = File(destPath);

    int downloadedBytes = 0;
    if (await destFile.exists()) {
      downloadedBytes = await destFile.length();
    }

    final complete = downloadedBytes == file.fileSize && file.fileSize > 0;

    // Step 2: free space for what is still missing
    if (!complete && file.fileSize > 0) {
      final needed =
          (file.fileSize - downloadedBytes).clamp(0, file.fileSize) +
          _downloadHeadroomBytes;
      final free = await StoragePlatform.freeBytes(onlineDir.path);
      if (free != null && free < needed) {
        throw InsufficientStorageException(needed, free);
      }
    }

    if (complete) {
      onProgress(1.0);
    } else {
      // Step 3: presigned URL, then download with progress and resume
      final url = await getDownloadUrl(file.id);
      if (url == null) {
        throw Exception(LocaleService.instance.strings.errDownloadUrlFailed);
      }

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

        // If server returns full file (200) instead of partial (206), start over
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
          throw Exception(LocaleService.instance.strings.errWrongCourseContent);
        }
      }
    } catch (e) {
      await destFile.delete().catchError((_) => destFile);
      throw Exception(LocaleService.instance.strings.errWrongCourseContent);
    }

    return destFile.path;
  }

  // ─── Thumbnail preview (online tab) ───────────────────────────────────────

  /// Bytes range-fetched for a preview on the fallback path: header + metadata
  /// + thumbnail. A thumbnail is one small JPEG/PNG frame, so 96 KB covers
  /// almost all files; any larger thumbnail simply falls back to an icon.
  static const int _thumbPreviewBytes = 96 * 1024;

  /// Whether the Worker has `/storage/thumbnail`. Unknown until it first
  /// answers. A Worker deployed before the route existed answers 404, and the
  /// app then uses the signed-URL path for the rest of the session.
  static bool? _thumbnailRoute;

  /// Returns the decrypted thumbnail for a remote file, or null if none.
  ///
  /// Kept in [LibraryService.thumbnails] like the offline tab's previews, so a
  /// folder opened again, or on the next launch, costs no network at all.
  /// When a preview does have to be fetched it takes one small request: the
  /// Worker returns just the encrypted header, metadata and thumbnail, and the
  /// data key never leaves the device.
  static Future<Uint8List?> fetchThumbnail(
    RemoteFile file, {
    bool Function()? stillWanted,
  }) {
    final course = AuthService.loggedInServerCode ?? '';
    return LibraryService.thumbnails.get(
      ThumbnailStore.idFor('r', '$course/${file.id}'),
      '${file.fileSize}-${ThumbnailStore.digest(file.uploadedAt, 12)}',
      () => _produceThumbnail(file),
      stillWanted: stillWanted,
    );
  }

  static Future<Uint8List?> _produceThumbnail(RemoteFile file) async {
    // Already downloaded → decrypt locally, no network needed.
    final localPath = await findLocalFile(file);
    if (localPath != null) {
      return DecryptionService.extractThumbnail(localPath);
    }
    final bytes = await _fetchPreviewBytes(file);
    if (bytes == null) return null;
    return DecryptionService.extractThumbnailFromBytes(bytes);
  }

  /// The encrypted prefix that holds the thumbnail. Null means the file has no
  /// preview. A transient failure throws, so it is not remembered as "none".
  /// A 401 is only a failed preview here; the session checks handle it.
  static Future<Uint8List?> _fetchPreviewBytes(RemoteFile file) async {
    if (_thumbnailRoute != false) {
      if (AuthService.activeSessionToken == null) {
        throw StateError('not signed in');
      }
      final response = await _dio.get<List<int>>(
        '${AuthService.workerUrl}/storage/thumbnail',
        queryParameters: {'fileId': file.id},
        options: Options(
          headers: AuthService.workerHeaders,
          responseType: ResponseType.bytes,
          validateStatus: (status) => status != null,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 200) {
        _thumbnailRoute = true;
        return Uint8List.fromList(response.data ?? const <int>[]);
      }
      if (status == 204) {
        _thumbnailRoute = true;
        return null;
      }
      if (status == 426) {
        AppUpdateGate.report();
        throw StateError('app update required');
      }
      if (status != 404) {
        throw StateError('thumbnail request failed: $status');
      }
      _thumbnailRoute = false; // older Worker: fall through to signed URL
    }

    final url = await getDownloadUrl(file.id);
    if (url == null) throw StateError('no download URL');

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=0-${_thumbPreviewBytes - 1}'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw StateError('preview range failed: ${response.statusCode}');
    }
    // Collect only up to _thumbPreviewBytes, then stop — bounds memory even
    // if the server ignores the Range header and starts a full-file body.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      builder.add(chunk);
      if (builder.length >= _thumbPreviewBytes) break;
    }
    return builder.toBytes();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static Future<int> getLocalFileSize(String displayName) async {
    try {
      final dir = await _activeCourseDir();
      if (dir == null) return 0;
      final file = File('${dir.path}/${_sanitize(displayName)}');
      if (await file.exists()) return await file.length();
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
