import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import '../services/library_service.dart';
import '../services/session_service.dart';
import '../services/progress_service.dart';
import '../services/remote_library_service.dart';
import '../core/decryption_service.dart';
import '../core/amo_native_bridge.dart';
import '../core/audio_output_platform.dart';
import '../core/storage_platform.dart';
import '../services/auth_service.dart';
import 'player_screen.dart';
import 'pdf_viewer_screen.dart';
import 'course_select_screen.dart';
import 're_verify_screen.dart';
import 'package:amo_core/amo_core.dart';

enum SortOption {
  nameAsc,
  nameDesc,
  dateNewest,
  dateOldest,
  sizeLargest,
  sizeSmallest,
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with TickerProviderStateMixin {
  List<VideoItem> _videos = [];
  bool _isLoading = true;
  bool _isImporting = false;
  String _searchQuery = '';
  String? _currentFolder;
  final SortOption _sortOption = SortOption.dateNewest;

  // Tab controller for Videos / Files
  late TabController _tabController;

  // Animation controllers
  late AnimationController _contentFadeController;
  late Animation<double> _contentFade;

  // Page controller for offline Videos / Files swipe
  late PageController _pageController;

  int _selectedTab = 0; // 0 = Videos, 1 = Files (used for offline only)
  bool _isOnlineTab = false; // Main toggle between Offline / Online

  // Online tab state
  RemoteCatalog _remoteCatalog = RemoteCatalog.empty();
  bool _remoteLoading = false;
  bool _remoteFetched = false;
  String _remoteCurrentFolder = '';
  final Map<int, double> _downloadProgress = {};
  final Map<int, bool> _downloadDone = {};
  final Map<int, CancelToken> _downloadCancelTokens = {};
  final Map<int, double> _partialProgress = {};

  // 24-hour periodic session check timer
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
    ); // 2 tabs now (Videos/Files)
    _contentFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1.0,
    );
    _contentFade = CurvedAnimation(
      parent: _contentFadeController,
      curve: Curves.easeInOut,
    );

    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) return;
      _animateTabSwitch(_tabController.index);
    });
    _pageController = PageController(initialPage: _selectedTab);

    _loadLibrary();
    _loadCachedOnlineCatalog();

    // 12-hour background check — fires for students who keep the app open all day
    _sessionTimer = Timer.periodic(
      const Duration(hours: 12),
      (_) => _periodicSessionCheck(),
    );
  }

  Future<void> _loadCachedOnlineCatalog() async {
    final cached = await RemoteLibraryService.loadCachedCatalog();
    if (cached.files.isNotEmpty && mounted) {
      final Map<int, bool> done = {};
      final Map<int, double> partials = {};
      for (final file in cached.files) {
        final localSize = await RemoteLibraryService.getLocalFileSize(
          file.displayName,
        );
        if (file.fileSize > 0) {
          if (localSize >= file.fileSize) {
            done[file.id] = true;
          } else if (localSize > 0) {
            partials[file.id] = localSize / file.fileSize;
          }
        } else if (localSize > 0) {
          done[file.id] = true;
        }
      }
      setState(() {
        _remoteCatalog = cached;
        _downloadDone.addAll(done);
        _partialProgress.addAll(partials);
        _remoteFetched = true;
      });
      // Background fetch for updates
      _fetchRemoteCatalog(silent: true);
    } else {
      _fetchRemoteCatalog();
    }
  }

  /// Background check every 12 hours — handles online (silent) and offline (counter).
  Future<void> _periodicSessionCheck() async {
    final check = await SessionService.periodicCheck();
    if (!mounted) return;
    SessionService.handleCheck(context, check);
  }

  /// The worker no longer accepts this course's session (401 /
  /// SESSION_INVALID): ask for the password again — never treat it as offline.
  Future<void> _sendActiveCourseToReVerify() async {
    final activeId = AuthService.loggedInStudentId;
    final stored = await SessionService.getStoredCourses();
    if (!mounted) return;
    final courses = stored.where((c) => c.studentId == activeId).toList();
    if (courses.isEmpty) {
      SessionService.showForceLogout(context, 'session_expired');
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ReVerifyScreen(
          courses: courses,
          notice: AmoL10n.of(context).srvSessionInvalid,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _animateTabSwitch(int newIndex) async {
    setState(() {
      _selectedTab = newIndex;
      _searchQuery = '';
      _currentFolder = null;
    });
    if (_pageController.hasClients &&
        _pageController.page?.round() != newIndex) {
      _pageController.animateToPage(
        newIndex,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    for (final token in _downloadCancelTokens.values) {
      token.cancel();
    }
    _tabController.dispose();
    _contentFadeController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadLibrary() async {
    setState(() => _isLoading = true);
    _videos = await LibraryService.loadLibrary();
    setState(() => _isLoading = false);
  }

  Future<void> _importVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: AmoL10n.of(context).libraryImportDialogTitle,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    if (!await _hasRoomFor(result.files)) {
      await _clearPickerCopies();
      return;
    }
    if (!mounted) return;

    setState(() => _isImporting = true);

    // ── Progress dialog ───────────────────────────────────────
    StateSetter? dlgSetState;
    var dlgProgress = 0.0;
    var dlgFileName = '';
    var dlgIndex = 0;
    final dlgTotal = result.files.length;
    var dlgClosed = false;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (_, ss) {
            dlgSetState = ss;
            return Dialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.upload_file_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AmoL10n.of(context).libraryImportingTitle,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (dlgTotal > 1) ...[
                      Text(
                        AmoL10n.of(
                          context,
                        ).libraryImportFileProgress(dlgIndex, dlgTotal),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      dlgFileName,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: dlgProgress > 0 ? dlgProgress : null,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${(dlgProgress * 100).toInt()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    // ── Import loop ───────────────────────────────────────────
    int imported = 0;
    int failed = 0;
    VideoItem? lastImported;

    for (int i = 0; i < result.files.length; i++) {
      final file = result.files[i];
      if (file.path == null) {
        failed++;
        continue;
      }

      dlgSetState?.call(() {
        dlgIndex = i + 1;
        dlgFileName = displayFileName(file.name);
        dlgProgress = 0.0;
      });

      try {
        final item = await LibraryService.addVideo(
          file.path!,
          onProgress: (p) {
            dlgSetState?.call(() => dlgProgress = p);
          },
        );
        if (item != null) {
          imported++;
          lastImported = item;
        } else {
          failed++;
        }
      } catch (e) {
        // Server code mismatch → show user-friendly dialog
        if (e is AmoWrongServerCodeException) {
          if (mounted) {
            if (!dlgClosed) {
              dlgClosed = true;
              dlgSetState = null;
              Navigator.of(context).pop();
            }
            setState(() => _isImporting = false);
            _showNotYourCourseDialog(displayFileName(file.name));
            unawaited(_clearPickerCopies());
            return;
          }
        }
        failed++;
      }
      await _discardPickerCopy(file.path!);
    }

    await _clearPickerCopies();

    if (mounted && !dlgClosed) {
      dlgClosed = true;
      dlgSetState = null;
      Navigator.of(context).pop();
    }

    if (!mounted) return;
    _videos = LibraryService.videos;

    // ── Auto-navigate to the correct tab + folder ──────────────
    if (lastImported != null) {
      final int targetTab = lastImported.isPdf ? 1 : 0;
      final String? targetFolder =
          (lastImported.folderName != null &&
              lastImported.folderName!.isNotEmpty)
          ? lastImported.folderName
          : null;

      if (targetTab != _selectedTab) {
        await _contentFadeController.reverse();
        if (!mounted) return;
        _tabController.index = targetTab;
        setState(() {
          _selectedTab = targetTab;
          _currentFolder = targetFolder;
          _searchQuery = '';
        });
        await _contentFadeController.forward();
      } else {
        setState(() {
          _currentFolder = targetFolder;
          _searchQuery = '';
        });
      }
    } else {
      setState(() => _isImporting = false);
    }

    setState(() => _isImporting = false);

    if (mounted) {
      final msg = imported > 0
          ? (failed > 0
                ? AmoL10n.of(
                    context,
                  ).libraryImportResultWithFailures(imported, failed)
                : AmoL10n.of(context).libraryImportResult(imported))
          : AmoL10n.of(context).libraryImportNoneValid;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: imported > 0
              ? AppColors.onlineAccent
              : AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  /// Room kept free beyond the files themselves: the index, previews, and the
  /// operating system's own margin.
  static const int _importHeadroomBytes = 200 * 1024 * 1024;

  /// Checks free space before any copying starts, so a large lecture is
  /// refused up front with a clear message rather than failing half-way.
  Future<bool> _hasRoomFor(List<PlatformFile> files) async {
    final sizes = files.map((f) => f.size).where((s) => s > 0).toList();
    if (sizes.isEmpty) return true;
    // A mobile picker has already copied every file (that space is used
    // already), and each copy is deleted as soon as its import finishes, so
    // at any moment the extra space needed is one file. Desktop pickers hand
    // back the originals, so every copy adds up.
    final onMobile = Platform.isIOS || Platform.isAndroid;
    final needed =
        (onMobile
            ? sizes.reduce((a, b) => a > b ? a : b)
            : sizes.fold<int>(0, (a, b) => a + b)) +
        _importHeadroomBytes;
    final free = await StoragePlatform.freeBytes(
      await LibraryService.getVideosDir(),
    );
    if (free == null || free >= needed) return true;
    if (mounted) _showNotEnoughSpaceDialog(needed, free);
    return false;
  }

  void _showNotEnoughSpaceDialog(int needed, int available) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          AmoL10n.of(context).libraryNotEnoughSpaceTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          AmoL10n.of(context).libraryNotEnoughSpaceBody(
            _formatSize(needed),
            _formatSize(available),
          ),
          style: const TextStyle(color: AppColors.mutedGray),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AmoL10n.of(context).actionOk),
          ),
        ],
      ),
    );
  }

  /// Deletes the picker's private copy of one file once its import is over,
  /// whatever the outcome, so a batch never holds every copy until the end.
  Future<void> _discardPickerCopy(String path) async {
    if (!await LibraryService.isPickerCopy(path)) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// Clears anything the picker left behind. Mobile only: desktop pickers
  /// make no copies.
  Future<void> _clearPickerCopies() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {}
  }

  void _showNotYourCourseDialog(String fileName) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(0),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.error.withValues(alpha: 0.4),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.error.withValues(alpha: 0.08),
                blurRadius: 30,
                spreadRadius: 4,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header gradient ────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.error.withValues(alpha: 0.15),
                      AppColors.folderAccentAlt.withValues(alpha: 0.08),
                    ],
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    // Shield icon
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.error.withValues(alpha: 0.15),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.shield_outlined,
                        color: AppColors.error,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AmoL10n.of(context).libraryNotYourCourseTitle,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Body ───────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Column(
                  children: [
                    // File name chip
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.insert_drive_file_outlined,
                            color: AppColors.mutedGray,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              fileName,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    Text(
                      AmoL10n.of(context).libraryNotYourCourseBody,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AmoL10n.of(context).libraryNotYourCourseContact,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Button ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error.withValues(alpha: 0.15),
                      foregroundColor: AppColors.error,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    child: Text(
                      AmoL10n.of(context).actionUnderstood,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playVideo(
    VideoItem video, {
    int playlistIndex = 0,
    double initialSpeed = 1.0,
  }) async {
    // Content gate: runs before opening ANY lesson, video or PDF. The local
    // offline policy (clock rollback, access end, offline open limit) applies
    // every time; the server round trip uses a 24h cache. A revoked / expired
    // / blocked account is caught here the next time the device is online.
    final gate = await SessionService.checkBeforeContent();
    if (!mounted) return;
    if (!SessionService.handleCheck(context, gate)) return;

    if (video.isPdf) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PdfViewerScreen(document: video)),
      );
      return;
    }

    // Headphone gate: if this course requires headphones, block VIDEO playback
    // unless wired/Bluetooth/USB headphones are connected. PDFs (handled above)
    // are never gated. Uses the cached flag (no request here) so it works
    // offline too; the flag is refreshed on the online Refresh button and the
    // periodic background check.
    if (AuthService.activeRequireHeadphones &&
        !await AudioOutputPlatform.headphonesConnected()) {
      if (mounted) await _showHeadphonesRequiredDialog();
      return;
    }

    // Verify header and HMAC before handing off to the native amo:// protocol.
    final header = await DecryptionService.parseHeader(video.filePath);
    if (header == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AmoL10n.of(context).errFileCorrupted)),
        );
      }
      return;
    }
    final hmacOk = await DecryptionService.verifyHmac(video.filePath, header);
    if (!hmacOk) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AmoL10n.of(context).errVerificationFailed)),
        );
      }
      return;
    }
    // The native decryptor must actually hold this course's key; a refused
    // key would only surface later as an unplayable stream.
    final keyOk = await AmoNativeBridge.setContentKey(
      AuthService.activeContentKey ?? '',
    );
    if (!mounted) return;
    if (!keyOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AmoL10n.of(context).errOpenFailedSupport)),
      );
      return;
    }
    final String videoPath = 'amo://${video.filePath}';

    // Build playlist: if video is in the offline library use it, otherwise
    // (online file) use a single-item playlist so the player gets a valid index.
    final videoItems = _filteredVideosTab.where((v) => v.isVideo).toList();
    final currentIdx = videoItems.indexOf(video);
    final List<String> playlistNames;
    final List<String> playlistPaths;
    // Names are display only (the player's title and "up next"); the paths
    // carry identity and the progress key.
    if (currentIdx >= 0) {
      playlistNames = videoItems.map((v) => v.displayName).toList();
      playlistPaths = videoItems.map((v) => v.filePath).toList();
    } else {
      playlistNames = [video.displayName];
      playlistPaths = [video.filePath];
    }

    if (!mounted) return;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          videoPath: videoPath,
          videoName: video.displayName,
          originalFilePath: video.filePath,
          playlistNames: playlistNames,
          playlistPaths: playlistPaths,
          currentIndex: currentIdx >= 0 ? currentIdx : 0,
          initialSpeed: initialSpeed,
        ),
      ),
    );

    // Refresh UI to show updated progress indicators
    if (mounted) setState(() {});

    // Handle auto-play next
    if (result != null && result['playNext'] == true) {
      final nextIndex = result['nextIndex'] as int? ?? 0;
      final nextSpeed = (result['speed'] as num?)?.toDouble() ?? 1.0;
      if (nextIndex < videoItems.length) {
        _playVideo(
          videoItems[nextIndex],
          playlistIndex: nextIndex,
          initialSpeed: nextSpeed,
        );
      }
    }
  }

  Future<void> _showHeadphonesRequiredDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        icon: const Icon(Icons.headphones, color: Colors.white, size: 48),
        title: Text(
          AmoL10n.of(context).playerHeadphonesRequiredTitle,
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          AmoL10n.of(context).playerHeadphonesRequiredBody,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'OK',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeVideo(VideoItem video) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          AmoL10n.of(context).libraryRemoveTitle,
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          AmoL10n.of(context).libraryRemoveBody(video.displayName),
          style: const TextStyle(color: AppColors.mutedGray),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AmoL10n.of(context).actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(AmoL10n.of(context).actionRemove),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await LibraryService.removeVideo(video.filePath);
      setState(() {
        _videos = LibraryService.videos;
      });
    }
  }

  // ── Filtering helpers ──────────────────────────────────────────────────────

  List<VideoItem> get _allVideos => _videos.where((v) => v.isVideo).toList();
  List<VideoItem> get _allFiles => _videos.where((v) => v.isPdf).toList();

  List<VideoItem> _applySorting(List<VideoItem> items) {
    final sorted = List<VideoItem>.from(items);
    switch (_sortOption) {
      case SortOption.nameAsc:
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case SortOption.nameDesc:
        sorted.sort(
          (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
        );
      case SortOption.dateNewest:
        sorted.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SortOption.dateOldest:
        sorted.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      case SortOption.sizeLargest:
        sorted.sort((a, b) => b.fileSize.compareTo(a.fileSize));
      case SortOption.sizeSmallest:
        sorted.sort((a, b) => a.fileSize.compareTo(b.fileSize));
    }
    return sorted;
  }

  List<VideoItem> get _filteredVideosTab {
    final List<VideoItem> source = _currentFolder != null
        ? LibraryService.videosInFolder(_currentFolder!)
        : LibraryService.rootVideos;
    List<VideoItem> result;
    if (_searchQuery.isEmpty) {
      result = source;
    } else {
      result = source
          .where(
            (v) => v.name.toLowerCase().contains(_searchQuery.toLowerCase()),
          )
          .toList();
    }
    return _applySorting(result);
  }

  List<VideoItem> get _filteredFilesTab {
    final List<VideoItem> source = _currentFolder != null
        ? LibraryService.documentsInFolder(_currentFolder!)
        : LibraryService.rootDocuments;
    List<VideoItem> result;
    if (_searchQuery.isEmpty) {
      result = source;
    } else {
      result = source
          .where(
            (v) => v.name.toLowerCase().contains(_searchQuery.toLowerCase()),
          )
          .toList();
    }
    return _applySorting(result);
  }

  List<String> get _filteredFolders {
    if (_currentFolder != null) return []; // no sub-folders
    final List<String> folders = _selectedTab == 0
        ? LibraryService.videoFolderNames
        : LibraryService.documentFolderNames;
    if (_searchQuery.isEmpty) return folders;
    return folders
        .where((f) => f.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  void _openFolder(String folderName) {
    setState(() {
      _currentFolder = folderName;
      _searchQuery = '';
    });
  }

  void _goBack() {
    setState(() {
      _currentFolder = null;
      _searchQuery = '';
    });
  }

  /// Navigate to course selection
  void _goToAnotherCourse() async {
    final storedCourses = await SessionService.getStoredCourses();
    if (!mounted) return;
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, _, _) =>
            CourseSelectScreen(storedCourses: storedCourses),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  /// Small square import button — floats over the bottom-right corner of the
  /// offline library instead of a full-width bar.
  Widget _buildImportButton() {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: AmoL10n.of(context).libraryImportFiles,
        child: InkWell(
          onTap: _isImporting ? null : _importVideo,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _isImporting
                  ? AppColors.pillUnselectedBg
                  : AppColors.iconChipBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isImporting
                    ? AppColors.border
                    : Colors.white.withValues(alpha: 0.2),
              ),
              boxShadow: _isImporting
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            alignment: Alignment.center,
            child: _isImporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.add_rounded, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDark,
      body: SafeArea(
        child: Column(
          children: [
            _buildTitleBar(),
            if (!_isOnlineTab) _buildSubTabBar(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _isLoading
                        ? _buildLoadingState()
                        : _isOnlineTab
                        ? FadeTransition(
                            opacity: _contentFade,
                            child: _buildOnlineTab(),
                          )
                        : _buildOfflinePageView(),
                  ),
                  if (!_isOnlineTab)
                    PositionedDirectional(
                      end: 16,
                      bottom: 16,
                      child: _buildImportButton(),
                    ),
                ],
              ),
            ),
            _buildMainToggle(),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ── Title bar ──────────────────────────────────────────────────────────────

  Widget _buildTitleBar() {
    return Container(
      height: 60,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          // Logo
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.iconChipBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: const LockMark(size: 20, color: Colors.white, weight: 9.0),
          ),
          const Spacer(),
          // Another Course button
          _buildIconButton(
            Icons.add_card_outlined,
            _goToAnotherCourse,
            tooltip: AmoL10n.of(context).libraryAnotherCourse,
          ),
          const LanguageToggle(fontSize: 11),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  /// Compact icon-only button used in the title bar
  Widget _buildIconButton(
    IconData icon,
    VoidCallback onTap, {
    String? tooltip,
  }) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  // ── Main Offline / Online Toggle (docked in the bottom bar) ───────────────

  Widget _buildMainToggle() {
    return Container(
      height: 56,
      decoration: const BoxDecoration(
        color: AppColors.scaffoldBg,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      alignment: Alignment.center,
      child: Container(
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.pillUnselectedBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: Stack(
          children: [
            // Sliding accent pill
            AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              // Directional: the two labels sit in a Row, which mirrors under
              // RTL, so a physical Alignment here would slide the pill away
              // from the item it is meant to be under.
              alignment: _isOnlineTab
                  ? const AlignmentDirectional(1.0, 0)
                  : const AlignmentDirectional(-1.0, 0),
              child: FractionallySizedBox(
                widthFactor: 0.5,
                child: Container(
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: _isOnlineTab ? AppColors.onlineAccent : Colors.white,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_isOnlineTab
                                    ? AppColors.onlineAccent
                                    : Colors.white)
                                .withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Buttons
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (_isOnlineTab) {
                        setState(() {
                          _isOnlineTab = false;
                          _searchQuery = '';
                          _currentFolder = null;
                        });
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(
                        AmoL10n.of(context).libraryOffline,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: !_isOnlineTab
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: !_isOnlineTab
                              ? Colors.black87
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (!_isOnlineTab) {
                        setState(() {
                          _isOnlineTab = true;
                          _searchQuery = '';
                        });
                        if (!_remoteFetched) {
                          _fetchRemoteCatalog();
                        }
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(
                        AmoL10n.of(context).libraryOnline,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _isOnlineTab
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: _isOnlineTab
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.38),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Sub Tab switcher (Videos / Files) for Offline ────────────────────────
  // Large & prominent — occupies the slot the Offline/Online toggle used to
  // sit in, styled to match (see _buildMainToggle, now docked at the bottom).

  Widget _buildSubTabBar() {
    final Color activeColor = _selectedTab == 0
        ? Colors.white
        : AppColors.filesTabAccent;
    return Container(
      height: 56,
      color: AppColors.surfaceDark,
      alignment: Alignment.center,
      child: Container(
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.pillUnselectedBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: Stack(
          children: [
            // Sliding accent pill
            AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              // Directional: the two labels sit in a Row, which mirrors under
              // RTL, so a physical Alignment here would slide the pill away
              // from the item it is meant to be under.
              alignment: _selectedTab == 1
                  ? const AlignmentDirectional(1.0, 0)
                  : const AlignmentDirectional(-1.0, 0),
              child: FractionallySizedBox(
                widthFactor: 0.5,
                child: Container(
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: activeColor,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color: activeColor.withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Buttons
            Row(
              children: [
                Expanded(
                  child: _buildSubTabButton(
                    0,
                    Icons.play_circle_fill_rounded,
                    AmoL10n.of(context).libraryTabVideos,
                  ),
                ),
                Expanded(
                  child: _buildSubTabButton(
                    1,
                    Icons.description_rounded,
                    AmoL10n.of(context).libraryTabFiles,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubTabButton(int index, IconData icon, String label) {
    final isSelected = _selectedTab == index;
    // Videos pill is white (needs dark text); Files pill is coral (needs white text)
    final Color selectedFg = index == 0 ? Colors.black87 : Colors.white;

    return GestureDetector(
      onTap: () {
        if (_selectedTab != index) {
          _tabController.index = index;
          _animateTabSwitch(index);
        }
      },
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? selectedFg
                  : Colors.white.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected
                    ? selectedFg
                    : Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Offline tab pager ─────────────────────────────────────────────────────

  /// Left deliberately un-reversed under RTL.
  ///
  /// A `PageView` inside an RTL `Directionality` already mirrors: page 0 sits on
  /// the right and a right-to-left swipe advances to page 1. That is what an
  /// Arabic reader expects, and it agrees with the tab indicator above, which
  /// aligns page 0 to the *start* edge. Forcing `reverse: true` here would make
  /// the pager and the indicator disagree — the bug this comment exists to
  /// prevent someone from introducing.
  Widget _buildOfflinePageView() {
    return PageView(
      controller: _pageController,
      physics: const ClampingScrollPhysics(),
      onPageChanged: (index) {
        if (_selectedTab != index) {
          setState(() {
            _selectedTab = index;
            _searchQuery = '';
            _currentFolder = null;
          });
          _tabController.index = index;
        }
      },
      children: [_buildVideosTab(), _buildFilesTab()],
    );
  }

  // ── Videos tab ────────────────────────────────────────────────────────────

  Widget _buildVideosTab() {
    final folders = _filteredFolders;
    final videos = _filteredVideosTab;
    final isInFolder = _currentFolder != null;
    final totalItems = folders.length + videos.length;

    if (totalItems == 0 && !isInFolder && _allVideos.isEmpty) {
      return _buildEmptyState(
        isFiles: false,
        message: AmoL10n.of(context).libraryNoVideos,
        sub: AmoL10n.of(context).libraryNoVideosHint,
      );
    }

    return _buildListLayout(
      folders: folders,
      items: videos,
      isInFolder: isInFolder,
      totalItems: totalItems,
      sectionLabel: isInFolder
          ? _currentFolder!
          : AmoL10n.of(context).libraryMyVideos,
      emptyInSearch: totalItems == 0 && _searchQuery.isNotEmpty,
    );
  }

  // ── Files (PDF) tab ───────────────────────────────────────────────────────

  Widget _buildFilesTab() {
    final folders = _filteredFolders;
    final files = _filteredFilesTab;
    final isInFolder = _currentFolder != null;
    final totalItems = folders.length + files.length;

    if (totalItems == 0 && !isInFolder && _allFiles.isEmpty) {
      return _buildEmptyState(
        isFiles: true,
        message: AmoL10n.of(context).libraryNoFiles,
        sub: AmoL10n.of(context).libraryNoFilesHint,
      );
    }

    return _buildListLayout(
      folders: folders,
      items: files,
      isInFolder: isInFolder,
      totalItems: totalItems,
      sectionLabel: isInFolder
          ? _currentFolder!
          : AmoL10n.of(context).libraryMyFiles,
      emptyInSearch: totalItems == 0 && _searchQuery.isNotEmpty,
    );
  }

  // ── Online tab (R2 cloud content) ─────────────────────────────────────────

  Future<void> _fetchRemoteCatalog({bool silent = false}) async {
    if (_remoteLoading) return;
    if (!silent) setState(() => _remoteLoading = true);
    try {
      final catalog = await RemoteLibraryService.fetchCatalog();
      final Map<int, bool> done = {};
      final Map<int, double> partials = {};
      for (final file in catalog.files) {
        final localSize = await RemoteLibraryService.getLocalFileSize(
          file.displayName,
        );
        if (file.fileSize > 0) {
          if (localSize >= file.fileSize) {
            done[file.id] = true;
          } else if (localSize > 0) {
            partials[file.id] = localSize / file.fileSize;
          }
        } else if (localSize > 0) {
          done[file.id] = true;
        }
      }
      if (mounted) {
        setState(() {
          _remoteCatalog = catalog;
          _downloadDone.addAll(done);
          _remoteFetched = true;
          _remoteCurrentFolder = '';
          _partialProgress
            ..clear()
            ..addAll(partials);
        });
      }
      // A manual Refresh (online tab) also re-fetches the per-course headphone
      // setting, so a teacher's toggle is picked up here without re-login and
      // applies to BOTH online and offline videos. Skipped on silent/background
      // fetches to save requests; the 12h periodic check is the backstop.
      if (!silent) await SessionService.refreshActiveRequireHeadphones();
    } catch (e) {
      if (mounted) {
        setState(() => _remoteLoading = false);
        final msg = e.toString().replaceFirst('Exception: ', '');
        // Stale session: student or server code no longer valid — force re-login.
        // Matched on the worker's code, because `msg` is localized.
        final code = e is AmoServerException ? e.code : null;
        if (code == 'APP_UPDATE_REQUIRED') return; // dialog already shown
        if (code == 'SESSION_INVALID') {
          await _sendActiveCourseToReVerify();
          return;
        }
        if (code == 'STUDENT_NOT_FOUND' || code == 'INVALID_LOGIN') {
          SessionService.showForceLogout(context, 'session_expired');
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AmoL10n.of(context).cloudLoadFailed(msg)),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _downloadRemoteFile(RemoteFile file) async {
    if (_downloadProgress.containsKey(file.id)) return;
    final cancelToken = CancelToken();
    _downloadCancelTokens[file.id] = cancelToken;
    setState(
      () => _downloadProgress[file.id] = _partialProgress[file.id] ?? 0.0,
    );
    try {
      await RemoteLibraryService.downloadFile(
        file: file,
        cancelToken: cancelToken,
        onProgress: (p) {
          // Ignore late progress callbacks that arrive after the user paused
          // (cancelled) the download — otherwise a stale "downloading" row with
          // no cancel token can be re-inserted.
          if (cancelToken.isCancelled) return;
          if (mounted) {
            setState(() {
              _downloadProgress[file.id] = p;
              _partialProgress[file.id] = p;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _downloadProgress.remove(file.id);
          _partialProgress.remove(file.id);
          _downloadDone[file.id] = true;
          _downloadCancelTokens.remove(file.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AmoL10n.of(
                context,
              ).cloudDownloadedToLibrary(displayFileName(file.displayName)),
            ),
            backgroundColor: AppColors.onlineAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadProgress.remove(file.id);
          _downloadCancelTokens.remove(file.id);
        });
        if (e is InsufficientStorageException) {
          _showNotEnoughSpaceDialog(e.neededBytes, e.availableBytes);
          return;
        }
        final code = e is AmoServerException ? e.code : null;
        if (code == 'APP_UPDATE_REQUIRED') return; // dialog already shown
        if (code == 'SESSION_INVALID') {
          await _sendActiveCourseToReVerify();
          return;
        }
        if (!cancelToken.isCancelled) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AmoL10n.of(
                  context,
                ).cloudDownloadFailed(e.toString().split(':').last.trim()),
              ),
              backgroundColor: AppColors.error,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              margin: const EdgeInsets.all(16),
            ),
          );
        }
      }
    }
  }

  /// Up ONE folder level in the online tab ('' is the cloud root).
  void _remoteFolderUp() {
    final slash = _remoteCurrentFolder.lastIndexOf('/');
    setState(() {
      _remoteCurrentFolder = slash < 0
          ? ''
          : _remoteCurrentFolder.substring(0, slash);
    });
  }

  Widget _buildOnlineTab() {
    List<RemoteFile> visibleFiles = _remoteCurrentFolder.isEmpty
        ? _remoteCatalog.rootFiles
        : _remoteCatalog.filesInFolder(_remoteCurrentFolder);
    List<String> visibleFolders = _remoteCurrentFolder.isEmpty
        ? _remoteCatalog.rootFolders
        : _remoteCatalog.subFolders(_remoteCurrentFolder);

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      visibleFiles = _remoteCatalog.files
          .where((f) => f.displayName.toLowerCase().contains(q))
          .toList();
      visibleFolders = _remoteCatalog.folders
          .where((f) => f.split('/').last.toLowerCase().contains(q))
          .toList();
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          color: AppColors.scaffoldBg,
          child: Row(
            children: [
              if (_remoteCurrentFolder.isNotEmpty) ...[
                IconButton(
                  onPressed: _remoteFolderUp,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: Icon(Icons.adaptive.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  _remoteCurrentFolder.isEmpty
                      ? ''
                      : _remoteCurrentFolder.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _remoteLoading ? null : _fetchRemoteCatalog,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.onlineAccent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.onlineAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: _remoteLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: AppColors.onlineAccent,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.refresh_rounded,
                          color: AppColors.onlineAccent,
                          size: 18,
                        ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: !_remoteFetched
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: AppColors.onlineAccent.withValues(alpha: 0.07),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.onlineAccent.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                        child: const Icon(
                          Icons.cloud_download_rounded,
                          color: AppColors.onlineAccent,
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        AmoL10n.of(context).cloudNotFetchedTitle,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        AmoL10n.of(context).cloudNotFetchedBody,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),
                      GestureDetector(
                        onTap: _fetchRemoteCatalog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 13,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppColors.onlineAccent,
                                AppColors.onlineGradientEnd,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.onlineAccent.withValues(
                                  alpha: 0.28,
                                ),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.refresh_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                AmoL10n.of(context).cloudLoadContent,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : visibleFiles.isEmpty && visibleFolders.isEmpty
              ? Center(
                  child: Text(
                    AmoL10n.of(context).cloudEmptyFolder,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 15,
                    ),
                  ),
                )
              // Built lazily: only rows on screen exist, so only their
              // previews are fetched. The old Column built every row, and
              // started every row's preview request, the moment a folder
              // opened.
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(24),
                      sliver: DecoratedSliver(
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        sliver: SliverList.builder(
                          itemCount:
                              visibleFolders.length + visibleFiles.length,
                          itemBuilder: (context, index) =>
                              index < visibleFolders.length
                              ? _buildOnlineFolderRow(visibleFolders[index])
                              : _buildOnlineFileRow(
                                  visibleFiles[index - visibleFolders.length],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  // ── Online folder row (unified container child) ───────────────────────────

  Widget _buildOnlineFolderRow(String folder) {
    final name = folder.split('/').last;
    final count = _remoteCatalog.filesInFolder(folder).length;
    return _AnimatedListItem(
      child: GestureDetector(
        onTap: () => setState(() => _remoteCurrentFolder = folder),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              const Text('📁', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      AmoL10n.of(context).cloudFolderFileCount(count),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withValues(alpha: 0.3),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Online file row (unified container child) ─────────────────────────────

  Widget _buildOnlineFileRow(RemoteFile file) {
    final isDownloading = _downloadProgress.containsKey(file.id);
    final isDone = _downloadDone[file.id] == true;
    final hasPartial = _partialProgress.containsKey(file.id);
    final isPaused = !isDownloading && !isDone && hasPartial;
    final progress = isDownloading
        ? (_downloadProgress[file.id] ?? 0.0)
        : (_partialProgress[file.id] ?? 0.0);

    return _AnimatedListItem(
      child: GestureDetector(
        onTap: isDone
            ? () async {
                final localPath = await RemoteLibraryService.findLocalFile(
                  file,
                );
                if (localPath == null) return;
                final header = await DecryptionService.parseHeader(localPath);
                if (header == null) {
                  await File(
                    localPath,
                  ).delete().catchError((_) => File(localPath));
                  if (mounted) {
                    setState(() {
                      _downloadDone.remove(file.id);
                      _partialProgress.remove(file.id);
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AmoL10n.of(context).errFileCorruptedRedownload,
                        ),
                        backgroundColor: AppColors.error,
                      ),
                    );
                  }
                  return;
                }
                final tempVideo = VideoItem(
                  filePath: localPath,
                  name: file.displayName,
                  originalExtension: header.originalExtension,
                  fileSize: file.fileSize,
                  originalSize: header.originalSize,
                  thumbnail: null,
                  folderName: file.folderPath,
                  contentType: header.contentType,
                );
                _playVideo(tempVideo);
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  // A PDF's preview can look just like a video frame, so PDFs
                  // (and only PDFs) carry a small corner badge.
                  Stack(
                    children: [
                      _RemoteThumbnail(
                        file: file,
                        fallbackEmoji: file.isVideo && !file.isPdf
                            ? '🎬'
                            : '📄',
                      ),
                      if (file.isPdf)
                        const PositionedDirectional(
                          end: 2,
                          bottom: 2,
                          child: PdfBadge(),
                        ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // RemoteFile.displayName is the full stored file
                          // name (the catalogue's `display_name`).
                          displayFileName(file.displayName),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          file.sizeLabel,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (isDownloading)
                    GestureDetector(
                      onTap: () {
                        _downloadCancelTokens[file.id]?.cancel();
                        setState(() {
                          _downloadProgress.remove(file.id);
                          _downloadCancelTokens.remove(file.id);
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Icon(
                          Icons.pause,
                          color: AppColors.error,
                          size: 16,
                        ),
                      ),
                    )
                  else if (isPaused)
                    GestureDetector(
                      onTap: () => _downloadRemoteFile(file),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    )
                  else if (!isDone)
                    GestureDetector(
                      onTap: () => _downloadRemoteFile(file),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: const Icon(
                          Icons.cloud_download_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                ],
              ),
              if (isDownloading || isPaused) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isPaused
                          ? AppColors.pausedDownload
                          : AppColors.onlineAccent,
                    ),
                    minHeight: 4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared list layout ────────────────────────────────────────────────────

  Widget _buildListLayout({
    required List<String> folders,
    required List<VideoItem> items,
    required bool isInFolder,
    required int totalItems,
    required String sectionLabel,
    required bool emptyInSearch,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              if (isInFolder) ...[
                _buildBackButton(),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _goBack,
                  child: Text(
                    AmoL10n.of(context).libraryTitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.chevron_right,
                    color: Colors.white.withValues(alpha: 0.3),
                    size: 18,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.folder,
                      color: AppColors.folderAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _currentFolder!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ] else
                Text(
                  sectionLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const SizedBox(width: 10),
              _buildCountChip(
                isInFolder
                    ? (_selectedTab == 0
                          ? AmoL10n.of(context).libraryVideoCount(items.length)
                          : AmoL10n.of(context).libraryFileCount(items.length))
                    : AmoL10n.of(context).libraryItemCount(totalItems),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: emptyInSearch
                ? _buildSearchEmpty()
                : totalItems == 0
                ? _buildEmptyState(
                    isFiles: _selectedTab == 1,
                    message: isInFolder
                        ? (_selectedTab == 0
                              ? AmoL10n.of(context).libraryNoVideosInFolder
                              : AmoL10n.of(context).libraryNoFilesInFolder)
                        : _selectedTab == 0
                        ? AmoL10n.of(context).libraryNoVideos
                        : AmoL10n.of(context).libraryNoFiles,
                    sub: AmoL10n.of(context).libraryEmptyFolderHint,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ListView.separated(
                        itemCount: folders.length + items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          if (index < folders.length) {
                            return _buildFolderCard(
                              folders[index],
                              unified: true,
                            );
                          }
                          return _buildVideoCard(
                            items[index - folders.length],
                            unified: true,
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _goBack,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.arrow_back, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _buildCountChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSearchEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 56,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 16),
          Text(
            AmoL10n.of(context).libraryNoResults(_searchQuery),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  // ── Header helpers ─────────────────────────────────────────────────────────

  // ── States ─────────────────────────────────────────────────────────────────

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text(
            AmoL10n.of(context).libraryLoading,
            style: TextStyle(color: AppColors.mutedGray),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required bool isFiles,
    required String message,
    required String sub,
  }) {
    final color = isFiles ? AppColors.pdfAccent : Colors.white;
    final icon = isFiles
        ? Icons.description_outlined
        : Icons.video_library_outlined;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.7, end: 1.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.elasticOut,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.08),
              ),
              child: Icon(icon, size: 64, color: color.withValues(alpha: 0.4)),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sub,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: _importVideo,
            icon: const Icon(Icons.add, size: 18),
            label: Text(AmoL10n.of(context).libraryImportFiles),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              // NOT always white: on the Videos tab `color` IS white, so a
              // white foreground made the label and the + invisible — the
              // button rendered as a blank white pill. Match the Sign In
              // button, which is black-on-white.
              foregroundColor: isFiles ? Colors.white : Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  // ── Cards ──────────────────────────────────────────────────────────────────

  Widget _buildFolderCard(String folderName, {bool unified = false}) {
    // Use the correct service depending on which tab is active
    final itemsInFolder = _selectedTab == 0
        ? LibraryService.videosInFolder(folderName)
        : LibraryService.documentsInFolder(folderName);
    final count = itemsInFolder.length;
    final previewPath = itemsInFolder.isNotEmpty
        ? itemsInFolder.first.filePath
        : null;

    return _AnimatedListItem(
      key: ValueKey('folder_$folderName'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openFolder(folderName),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 76,
            decoration: unified
                ? null
                : BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.folderAccent.withValues(alpha: 0.22),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadiusDirectional.horizontal(
                    start: Radius.circular(12),
                  ),
                  child: SizedBox(
                    width: 110,
                    height: 76,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AsyncThumbnail(
                          cacheKey: previewPath ?? '',
                          load: (wanted) => previewPath == null
                              ? Future.value(null)
                              : LibraryService.getThumbnail(
                                  previewPath,
                                  stillWanted: wanted,
                                ),
                          builder: (context, bytes) => bytes == null
                              ? Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        AppColors.folderAccent.withValues(
                                          alpha: 0.12,
                                        ),
                                        AppColors.folderAccentAlt.withValues(
                                          alpha: 0.03,
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : Opacity(
                                  opacity: 0.35,
                                  child: Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    errorBuilder: (_, _, _) =>
                                        _buildFolderIconBg(),
                                  ),
                                ),
                        ),
                        Center(child: _buildFolderIconBg()),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            _buildMiniChip(
                              AmoL10n.of(context).libraryFolderTag,
                              Icons.folder,
                              AppColors.folderAccent,
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _selectedTab == 0
                                  ? Icons.video_library
                                  : Icons.insert_drive_file,
                              size: 10,
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _selectedTab == 0
                                  ? AmoL10n.of(context).libraryVideoCount(count)
                                  : AmoL10n.of(context).libraryFileCount(count),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.38),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 14),
                  child: Icon(
                    Icons.chevron_right,
                    color: Colors.white.withValues(alpha: 0.28),
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderIconBg() {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.folderAccent.withValues(alpha: 0.18),
      ),
      child: const Icon(Icons.folder, color: AppColors.folderAccent, size: 20),
    );
  }

  Widget _buildVideoCard(VideoItem video, {bool unified = false}) {
    final isPdf = video.isPdf;
    final accent = isPdf ? AppColors.pdfAccent : Colors.white;

    return _AnimatedListItem(
      key: ValueKey('video_${video.filePath}'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _playVideo(video),
          borderRadius: BorderRadius.circular(12),
          highlightColor: accent.withValues(alpha: 0.06),
          splashColor: accent.withValues(alpha: 0.08),
          child: Container(
            height: 76,
            decoration: unified
                ? null
                : BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.videoCardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
            child: Row(
              children: [
                // Thumbnail / PDF icon area
                ClipRRect(
                  borderRadius: const BorderRadiusDirectional.horizontal(
                    start: Radius.circular(12),
                  ),
                  child: SizedBox(
                    width: 110,
                    height: 76,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (isPdf)
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  AppColors.pdfAccentAlt.withValues(
                                    alpha: 0.13,
                                  ),
                                  AppColors.pdfThumbBg,
                                ],
                              ),
                            ),
                          )
                        else
                          AsyncThumbnail(
                            cacheKey: video.filePath,
                            load: (wanted) => LibraryService.getThumbnail(
                              video.filePath,
                              stillWanted: wanted,
                            ),
                            builder: (context, bytes) => bytes == null
                                ? _buildPlaceholderThumb()
                                : Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    errorBuilder: (_, _, _) =>
                                        _buildPlaceholderThumb(),
                                  ),
                          ),
                        // Overlay gradient
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: AlignmentDirectional.centerStart.resolve(
                                Directionality.of(context),
                              ),
                              end: AlignmentDirectional.centerEnd.resolve(
                                Directionality.of(context),
                              ),
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.3),
                              ],
                            ),
                          ),
                        ),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(alpha: 0.85),
                              boxShadow: [
                                BoxShadow(
                                  color: accent.withValues(alpha: 0.3),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Icon(
                              isPdf ? Icons.picture_as_pdf : Icons.play_arrow,
                              color: isPdf ? Colors.white : Colors.black,
                              size: 17,
                            ),
                          ),
                        ),
                        // Progress bar
                        if (!isPdf) ...[
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Builder(
                              builder: (_) {
                                final progressKey = ProgressService.keyFor(
                                  video.filePath,
                                );
                                final progress =
                                    ProgressService.getProgressFraction(
                                      progressKey,
                                    );
                                if (progress <= 0) {
                                  return const SizedBox.shrink();
                                }
                                final watched = ProgressService.isWatched(
                                  progressKey,
                                );
                                return Container(
                                  height: 3,
                                  color: Colors.black38,
                                  // Physical on purpose. A media progress
                                  // bar tracks a timeline, and timelines run
                                  // left-to-right in every locale; every major
                                  // player keeps this LTR in Arabic.
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: progress.clamp(0.0, 1.0),
                                    child: Container(
                                      color: watched
                                          ? AppColors.onlineAccent
                                          : Colors.white,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                        // Watched badge
                        if (!isPdf &&
                            ProgressService.isWatched(
                              ProgressService.keyFor(video.filePath),
                            ))
                          PositionedDirectional(
                            top: 4,
                            end: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.onlineAccent,
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Info
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          video.displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            _buildMiniChip(
                              isPdf ? 'PDF' : 'ENCRYPTED',
                              isPdf ? Icons.picture_as_pdf : Icons.lock,
                              accent,
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.storage,
                              size: 10,
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatSize(video.fileSize),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.38),
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              video.originalExtension.toUpperCase(),
                              style: TextStyle(
                                color: accent.withValues(alpha: 0.5),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // Remove button
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _removeVideo(video),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.more_vert,
                          color: Colors.white.withValues(alpha: 0.38),
                          size: 17,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniChip(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 8, color: color.withValues(alpha: 0.85)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.85),
              fontSize: 8,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderThumb() {
    return Container(
      color: AppColors.surface,
      child: Center(
        child: Icon(
          Icons.movie,
          size: 26,
          color: Colors.white.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}

// ── Online-tab thumbnail (lazy, decrypted preview) ──────────────────────────

/// Shows the decrypted thumbnail for a not-yet-downloaded remote file, lazily
/// fetched via [RemoteLibraryService.fetchThumbnail]. Falls back to an emoji
/// icon while loading or when the file has no usable preview.
class _RemoteThumbnail extends StatefulWidget {
  final RemoteFile file;
  final String fallbackEmoji;
  const _RemoteThumbnail({required this.file, required this.fallbackEmoji});

  @override
  State<_RemoteThumbnail> createState() => _RemoteThumbnailState();
}

class _RemoteThumbnailState extends State<_RemoteThumbnail> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A lazily built list recycles rows, so this state can be handed a
    // different file.
    if (oldWidget.file.id != widget.file.id) {
      _thumb = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.file.id;
    bool current() => mounted && widget.file.id == id;
    final thumb = await RemoteLibraryService.fetchThumbnail(
      widget.file,
      stillWanted: current,
    );
    if (thumb == null || !current()) return;
    setState(() => _thumb = thumb);
  }

  @override
  Widget build(BuildContext context) {
    const double size = 44;
    if (_thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          _thumb!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _fallback(size),
        ),
      );
    }
    return _fallback(size);
  }

  Widget _fallback(double size) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(widget.fallbackEmoji, style: const TextStyle(fontSize: 22)),
    );
  }
}

// ── PDF badge (online tab) ──────────────────────────────────────────────────

/// Small rounded chip marking a PDF on its thumbnail. Videos get none.
class PdfBadge extends StatelessWidget {
  const PdfBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.pdfAccent,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 3),
        ],
      ),
      child: const Icon(Icons.picture_as_pdf, color: Colors.white, size: 11),
    );
  }
}

// ── List item wrapper (scale-on-press feedback) ───────────────────────────

class _AnimatedListItem extends StatefulWidget {
  final Widget child;
  const _AnimatedListItem({super.key, required this.child});

  @override
  State<_AnimatedListItem> createState() => _AnimatedListItemState();
}

class _AnimatedListItemState extends State<_AnimatedListItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ── Decryption dialog ──────────────────────────────────────────────────────

// _DecryptionDialog removed: dead code (never instantiated). On Android, video
// plays via the in-process amo:// protocol and PDFs decrypt in pdf_viewer_screen;
// nothing decrypted a whole video to a temp file through this dialog.
