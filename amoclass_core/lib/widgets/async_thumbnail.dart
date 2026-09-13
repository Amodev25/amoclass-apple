import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Loads a preview when the row is actually built and hands the bytes to
/// [builder]. `null` means "not loaded yet, or there is none". The builder
/// draws the placeholder for that case, so the row never waits on the preview.
///
/// Inside a lazily built list only the rows on screen exist, so only their
/// previews are requested. When a row scrolls away before its turn comes,
/// the `stillWanted` callback passed to [load] turns false and the store skips
/// the work.
class AsyncThumbnail extends StatefulWidget {
  const AsyncThumbnail({
    super.key,
    required this.cacheKey,
    required this.load,
    required this.builder,
  });

  /// Identifies the preview. A new value starts a new load. Needed because a
  /// recycled row can be handed a different item.
  final Object cacheKey;

  final Future<Uint8List?> Function(bool Function() stillWanted) load;

  final Widget Function(BuildContext context, Uint8List? bytes) builder;

  @override
  State<AsyncThumbnail> createState() => _AsyncThumbnailState();
}

class _AsyncThumbnailState extends State<AsyncThumbnail> {
  Uint8List? _bytes;
  Object? _request;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AsyncThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _bytes = null;
      _start();
    }
  }

  @override
  void dispose() {
    _request = null;
    super.dispose();
  }

  void _start() {
    final request = Object();
    _request = request;
    bool current() => mounted && identical(_request, request);
    widget.load(current).then((bytes) {
      if (bytes == null || !current()) return;
      setState(() => _bytes = bytes);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _bytes);
}
