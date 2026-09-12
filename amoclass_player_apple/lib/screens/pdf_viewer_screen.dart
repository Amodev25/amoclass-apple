import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../core/decryption_service.dart';
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
  String? _tempPdfPath;

  final PdfViewerController _pdfViewerController = PdfViewerController();

  @override
  void initState() {
    super.initState();
    _decryptAndLoad();
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  Future<void> _cleanupTempFile() async {
    if (_tempPdfPath != null) {
      try {
        final f = File(_tempPdfPath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
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

      final tempPath = await DecryptionService.decryptToTempFile(
        widget.document.filePath,
        header,
      );

      if (mounted) {
        setState(() {
          _tempPdfPath = tempPath;
          _isDecrypting = false;
        });
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
              widget.document.name,
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
        child: Column(children: [Expanded(child: _buildBody())]),
      ),
    );
  }

  Widget _buildBody() {
    if (_isDecrypting) return _buildDecryptingState();
    if (_errorMessage != null) return _buildErrorState();

    return SfPdfViewer.file(
      File(_tempPdfPath!),
      controller: _pdfViewerController,
      canShowScrollHead: false,
      enableDoubleTapZooming: true,
      canShowScrollStatus: true,
      pageSpacing: 4,
      pageLayoutMode: PdfPageLayoutMode.continuous,
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
