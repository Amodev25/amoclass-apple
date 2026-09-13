import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:amo_core/amo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:amo_player_apple/services/library_service.dart';

/// Points path_provider at a throwaway directory, so LibraryService writes its
/// index where the test can look at it.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

Uint8List _bytes(int n) => Uint8List.fromList(List.filled(4, n));

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lockclass_test_');
    PathProviderPlatform.instance = _FakePaths(root.path);
    LibraryService.clearCache();
  });

  tearDown(() async {
    LibraryService.clearCache();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  group('library index', () {
    test('an unreadable index is set aside, never overwritten', () async {
      final index = File('${root.path}/amo_library.json');
      await index.writeAsString('[{"filePath": "trunc'); // killed mid-write

      final items = await LibraryService.loadLibrary();
      expect(items, isEmpty);

      // The next save (here: a removal) must not destroy the original bytes.
      await LibraryService.removeVideo('/nowhere');
      final aside = root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('amo_library.json.unreadable-'))
          .toList();
      expect(aside, hasLength(1));
      expect(await aside.single.readAsString(), '[{"filePath": "trunc');
    });

    test('saves go through a temp file and leave a complete index', () async {
      final video = File('${root.path}/Videos/a.amo');
      await video.create(recursive: true);
      final index = File('${root.path}/amo_library.json');
      await index.writeAsString(
        jsonEncode([
          {
            'filePath': video.path,
            'name': 'Lesson A',
            'originalExtension': 'mp4',
            'fileSize': 10,
            'originalSize': 10,
            'contentType': 'video',
            'addedAt': '2026-01-01T00:00:00.000',
          },
          {
            'filePath': '${root.path}/Videos/gone.amo',
            'name': 'Missing file',
            'originalExtension': 'mp4',
            'fileSize': 10,
            'originalSize': 10,
            'contentType': 'video',
            'addedAt': '2026-01-01T00:00:00.000',
          },
        ]),
      );

      final items = await LibraryService.loadLibrary();
      expect(items.map((v) => v.name), ['Lesson A']);

      // Two saves racing must both land, one after the other.
      await Future.wait([
        LibraryService.removeVideo('/nowhere-1'),
        LibraryService.removeVideo('/nowhere-2'),
      ]);
      expect(File('${index.path}.tmp').existsSync(), isFalse);
      final saved = jsonDecode(await index.readAsString()) as List<dynamic>;
      expect(saved.map((e) => e['name']), ['Lesson A']);
    });
  });

  group('thumbnail store', () {
    ThumbnailStore store({int concurrent = 3}) => ThumbnailStore(
      directory: () async => Directory('${root.path}/thumbs')..createSync(),
      maxConcurrent: concurrent,
    );

    test('produces once, then serves memory, then disk', () async {
      var calls = 0;
      Future<Uint8List?> produce() async {
        calls++;
        return _bytes(7);
      }

      final a = store();
      expect(await a.get('lx', '1-1', produce), _bytes(7));
      expect(await a.get('lx', '1-1', produce), _bytes(7));
      expect(calls, 1);

      final b = store(); // a fresh launch
      expect(await b.get('lx', '1-1', produce), _bytes(7));
      expect(calls, 1);
    });

    test('a new version replaces the stored file', () async {
      final s = store();
      await s.get('lx', '1-1', () async => _bytes(1));
      await s.get('lx', '2-2', () async => _bytes(2));
      final names = Directory(
        '${root.path}/thumbs',
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, ['lx.2-2.thumb']);
    });

    test('"no preview" is remembered, a failure is not', () async {
      final s = store();
      var nulls = 0;
      await s.get('ln', '1-1', () async {
        nulls++;
        return null;
      });
      await s.get('ln', '1-1', () async {
        nulls++;
        return null;
      });
      expect(nulls, 1);

      var throws = 0;
      Future<Uint8List?> fail() async {
        throws++;
        throw const SocketException('offline');
      }

      expect(await s.get('lt', '1-1', fail), isNull);
      expect(await s.get('lt', '1-1', fail), isNull);
      expect(throws, 2);
    });

    test('never runs more than maxConcurrent producers at once', () async {
      final s = store(concurrent: 2);
      var running = 0;
      var peak = 0;
      final gate = Completer<void>();
      Future<Uint8List?> slow() async {
        running++;
        peak = running > peak ? running : peak;
        await gate.future;
        running--;
        return _bytes(3);
      }

      final all = [for (var i = 0; i < 6; i++) s.get('c$i', '1-1', slow)];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(peak, 2);
      gate.complete();
      await Future.wait(all);
      expect(peak, 2);
    });

    test('work nobody wants any more is skipped', () async {
      final s = store(concurrent: 1);
      final gate = Completer<void>();
      final first = s.get('w1', '1-1', () async {
        await gate.future;
        return _bytes(1);
      });
      var skippedRan = false;
      final skipped = s.get('w2', '1-1', () async {
        skippedRan = true;
        return _bytes(2);
      }, stillWanted: () => false);
      gate.complete();
      await first;
      expect(await skipped, isNull);
      expect(skippedRan, isFalse);
    });

    test('remove deletes every stored version', () async {
      final s = store();
      await s.get('lr', '1-1', () async => _bytes(1));
      await s.remove('lr');
      expect(Directory('${root.path}/thumbs').listSync(), isEmpty);
    });
  });
}
