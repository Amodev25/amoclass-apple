import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../core/decryption_service.dart';
import '../services/auth_service.dart';
import 'package:amo_core/amo_core.dart';

class PdfViewerScreen extends StatefulWidget {
  final VideoItem document;

  const PdfViewerScreen({super.key, required this.document});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  bool _isDecrypting = true;
  String? _errorMessage;

  /// The decrypted document. Held in memory only — nothing decrypted is ever
  /// written to disk — and zeroed when the screen closes.
  Uint8List? _pdfBytes;

  final PdfViewerController _pdfViewerController = PdfViewerController();

  bool _loadStarted = false;

  // Started here, not in initState: _decryptAndLoad reads AmoL10n.of(context)
  // before its first await, and an inherited-widget lookup during initState
  // throws (debug builds), which left the screen stuck on an uncaught error.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadStarted) return;
    _loadStarted = true;
    _decryptAndLoad();
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    _releaseBytes();
    super.dispose();
  }

  void _releaseBytes() {
    final bytes = _pdfBytes;
    _pdfBytes = null;
    if (bytes != null) DecryptionService.wipe(bytes);
  }

  Future<void> _decryptAndLoad() async {
    // Resolved before the first await: every message below is set after one,
    // and reading an inherited widget off a context that may have been
    // unmounted in the meantime is exactly what use_build_context_synchronously
    // is warning about. `_setError` already no-ops when unmounted.
    final l10n = AmoL10n.of(context);

    setState(() {
      _isDecrypting = true;
      _errorMessage = null;
    });

    try {
      final header = await DecryptionService.parseHeader(
        widget.document.filePath,
      );
      if (header == null) {
        _setError(l10n.errFileCorruptedRetryImport);
        return;
      }

      final bytes = await DecryptionService.decryptToMemory(
        widget.document.filePath,
        header,
      );

      if (!mounted) {
        DecryptionService.wipe(bytes);
        return;
      }
      final previous = _pdfBytes;
      setState(() {
        _pdfBytes = bytes;
        _isDecrypting = false;
      });
      if (previous != null && !identical(previous, bytes)) {
        DecryptionService.wipe(previous);
      }
    } on AmoWrongCourseException {
      _setError(l10n.errWrongCourseSwitch);
    } on AmoFileCorruptedException {
      _setError(l10n.errFileCorruptedRetryImport);
    } on AmoDecryptionException {
      _setError(l10n.errOpenFailedSupport);
    } catch (e) {
      _setError(l10n.pdfLoadFailed);
    }
  }

  void _setError(String msg) {
    if (mounted) {
      setState(() {
        _isDecrypting = false;
        _errorMessage = msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back, color: Colors.white),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.document.displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              AmoL10n.of(context).pdfTitle,
              style: TextStyle(
                color: Colors.white.withAlpha(100),
                fontSize: 10,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_in, color: Colors.white70),
            onPressed: () {
              _pdfViewerController.zoomLevel =
                  _pdfViewerController.zoomLevel + 0.5;
            },
          ),
          IconButton(
            icon: const Icon(Icons.zoom_out, color: Colors.white70),
            onPressed: () {
              _pdfViewerController.zoomLevel =
                  (_pdfViewerController.zoomLevel - 0.5).clamp(1.0, 5.0);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(children: [Expanded(child: _buildBody())]),
            // Student name + password watermark (owner decision 2026-09-14),
            // LAST so the document never draws over it.
            ?_buildWatermark(),
          ],
        ),
      ),
    );
  }

  /// Null (nothing drawn) when no student is signed in.
  Widget? _buildWatermark() {
    final name = AuthService.loggedInStudentName;
    if (name == null || name.trim().isEmpty) return null;
    return StudentWatermark(name: name, password: AuthService.activePassword);
  }

  Widget _buildBody() {
    if (_isDecrypting) return _buildDecryptingState();
    if (_errorMessage != null) return _buildErrorState();
    final bytes = _pdfBytes;
    if (bytes == null) return _buildErrorState();

    return SfPdfViewer.memory(
      bytes,
      controller: _pdfViewerController,
      canShowScrollHead: false,
      enableDoubleTapZooming: true,
      canShowScrollStatus: true,
      pageSpacing: 4,
      pageLayoutMode: PdfPageLayoutMode.continuous,
      // No copying lesson text out, and no links that leave the protected
      // viewer (contract §3.9).
      enableTextSelection: false,
      enableHyperlinkNavigation: false,
      canShowHyperlinkDialog: false,
    );
  }

  Widget _buildDecryptingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 24),
          Text(
            AmoL10n.of(context).pdfUnlocking,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 48),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _decryptAndLoad,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(AmoL10n.of(context).actionRetry),
            ),
          ],
        ),
      ),
    );
  }
}
