import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The small previews shown beside each item in the library lists.
///
/// Three tiers, cheapest first: a bounded in-memory LRU, plain files on disk,
/// and only when both miss, the caller's `produce` function. That last one is
/// the expensive part: decrypting a container and checking its HMAC, or a
/// network request. Before this existed every preview was produced on every
/// launch, for every item, before the library could appear.
///
/// Previews are stored UNENCRYPTED on purpose. One frame is not what the
/// product protects, and the item names beside it already sit in the library
/// index in clear. What has to hold instead is where they live: [directory]
/// must be app-private. Never Documents on iOS, which UIFileSharingEnabled
/// exposes in the Files app, and never shared storage on Android, where a
/// gallery would index them. Files are named `.thumb` so no media scanner
/// treats them as images.
class ThumbnailStore {
  ThumbnailStore({
    required this.directory,
    this.memoryEntries = 80,
    this.maxConcurrent = 3,
  });

  /// Resolved once per request, before any work starts, so a preview produced
  /// for one course can never be written into the next course's folder.
  final Future<Directory> Function() directory;

  /// Upper bound on previews held in memory.
  final int memoryEntries;

  /// How many `produce` calls may run at once. A fast fling through a long
  /// list must not start hundreds of decrypts or downloads together.
  final int maxConcurrent;

  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();

  /// Keys whose `produce` answered a definite "no preview" this session. Kept
  /// in memory only: the answer can change (new credentials, a re-upload).
  final Set<String> _missing = {};

  final Map<String, _Job> _jobs = {};
  final Queue<Completer<void>> _waiters = Queue();
  int _running = 0;

  /// Bumped by [clearMemory]. Work that started under an older generation
  /// finishes without touching the caches.
  int _generation = 0;

  static final RegExp _safe = RegExp(r'^[A-Za-z0-9_-]+$');

  /// A filename-safe id for [source], e.g. `idFor('l', '/path/video.amo')`.
  static String idFor(String prefix, String source) =>
      '$prefix${digest(source)}';

  /// A short, filename-safe digest of [value].
  static String digest(String value, [int length = 20]) =>
      sha1.convert(utf8.encode(value)).toString().substring(0, length);

  /// Returns the preview for [id] at [version], producing it if needed.
  ///
  /// [version] changes whenever the source changes (size, modification time,
  /// upload time), which retires the stored file. `produce` returns null for
  /// "this item has no preview"; it throws for a transient failure, which is
  /// not remembered, so the next request tries again.
  ///
  /// [stillWanted] is asked just before `produce` runs. When every caller
  /// waiting on the same preview has scrolled it away, the work is skipped.
  Future<Uint8List?> get(
    String id,
    String version,
    Future<Uint8List?> Function() produce, {
    bool Function()? stillWanted,
  }) {
    if (!_safe.hasMatch(id) || !_safe.hasMatch(version)) {
      throw ArgumentError('Thumbnail id and version must be filename-safe');
    }
    final key = '$id.$version';

    final hit = _memory.remove(key);
    if (hit != null) {
      _memory[key] = hit; // most recently used goes to the back
      return Future.value(hit);
    }
    if (_missing.contains(key)) return Future.value(null);

    final wanted = stillWanted ?? () => true;
    final running = _jobs[key];
    if (running != null) {
      running.wanters.add(wanted);
      return running.future;
    }

    final job = _Job([wanted]);
    _jobs[key] = job;
    job.future = _load(id, key, produce, job, _generation).whenComplete(() {
      if (identical(_jobs[key], job)) _jobs.remove(key);
    });
    return job.future;
  }

  Future<Uint8List?> _load(
    String id,
    String key,
    Future<Uint8List?> Function() produce,
    _Job job,
    int generation,
  ) async {
    final Directory dir;
    try {
      dir = await directory();
    } catch (_) {
      return null;
    }
    final file = File(_pathIn(dir, '$key.thumb'));

    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          if (generation == _generation) _remember(key, bytes);
          return bytes;
        }
      }
    } catch (_) {
      // Unreadable cache file: fall through and produce it again.
    }

    await _acquire();
    try {
      if (generation != _generation) return null;
      if (!job.wanters.any((w) => w())) return null;

      final Uint8List? bytes;
      try {
        bytes = await produce();
      } catch (_) {
        return null; // transient, not remembered
      }
      if (generation != _generation) return bytes;
      if (bytes == null || bytes.isEmpty) {
        _missing.add(key);
        return null;
      }
      _remember(key, bytes);
      await _write(dir, id, key, bytes);
      return bytes;
    } finally {
      _release();
    }
  }

  void _remember(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<void> _write(
    Directory dir,
    String id,
    String key,
    Uint8List bytes,
  ) async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      // Same write-then-rename as the library index: a preview is either the
      // old file or the whole new one, never half of one.
      final tmp = File(_pathIn(dir, '$key.thumb.tmp'));
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(_pathIn(dir, '$key.thumb'));
      await _deleteVersions(dir, id, keep: '$key.thumb');
    } catch (_) {
      // A full disk costs a preview, not the library.
    }
  }

  /// Forgets every stored version of [id], in memory and on disk. Call when
  /// the item itself leaves the library.
  Future<void> remove(String id) async {
    _memory.removeWhere((k, _) => k.startsWith('$id.'));
    _missing.removeWhere((k) => k.startsWith('$id.'));
    try {
      await _deleteVersions(await directory(), id);
    } catch (_) {}
  }

  /// Drops the in-memory tier and abandons work in progress. Call on course
  /// switch and logout. Files on disk are left alone; the owning service
  /// decides when those go.
  void clearMemory() {
    _generation++;
    _memory.clear();
    _missing.clear();
  }

  Future<void> _deleteVersions(Directory dir, String id, {String? keep}) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('$id.') && name != keep) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _acquire() {
    if (_running < maxConcurrent) {
      _running++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(); // the slot passes straight on
    } else {
      _running--;
    }
  }

  static String _pathIn(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';
}

class _Job {
  _Job(this.wanters);
  final List<bool Function()> wanters;
  late Future<Uint8List?> future;
}
