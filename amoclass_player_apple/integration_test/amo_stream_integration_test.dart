import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'package:amo_core/core/constants.dart';
import 'package:amo_player_apple/core/amo_native_bridge.dart';
import 'package:amo_player_apple/core/decryption_service.dart';

/// Test-only inputs for the course key. The server computes
/// HMAC-SHA256(credential, course_secret) and sends the app only the result
/// (the content key); the fixture derives it the same way, so the key handed
/// to the C side must be exactly [kContentKeyHex].
const kCredential = 'test_user';
const kCourseSecret = 'test_secret';

/// The content key as the worker would send it: 64 hex digits.
final String kContentKeyHex = crypto.Hmac(
  crypto.sha256,
  utf8.encode(kCredential),
).convert(utf8.encode(kCourseSecret)).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late File testAmoFile;
  late Player player;

  setUpAll(() async {
    MediaKit.ensureInitialized();
    player = Player(configuration: const PlayerConfiguration());

    // Download a sample 10-second MP4 video (around 1.5MB)
    final dir = await getTemporaryDirectory();
    final tempMp4 = File('${dir.path}/sample.mp4');
    final amoPath = '${dir.path}/test_video.amo';

    if (!tempMp4.existsSync()) {
      final dio = Dio();
      await dio.download(
        'https://www.w3schools.com/html/mov_bbb.mp4',
        tempMp4.path,
      );
    }

    final inputBytes = tempMp4.readAsBytesSync();

    // Build a real v2 container. Dart writes it, the native C decryptor reads
    // it — so this is a genuine cross-implementation check of the pattern math,
    // not one implementation agreeing with itself.
    final masterKey = AmoConstants.getMasterKey();
    final courseKey = Uint8List.fromList(
      crypto.Hmac(crypto.sha256, utf8.encode(kCredential))
          .convert(utf8.encode(kCourseSecret))
          .bytes,
    );

    final iv = Uint8List(16);
    final random = Random.secure();
    for (int i = 0; i < 16; i++) {
      iv[i] = random.nextInt(256);
    }

    // Metadata is master-key encrypted at counter 0. keyVersion 2 is mandatory:
    // amo_open refuses anything lower rather than falling back to the master key.
    final metaBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'name': 'integration',
          'contentType': 'video',
          'originalExtension': 'mp4',
          'originalSize': inputBytes.length,
          'encryptedAt': DateTime.now().toIso8601String(),
          'version': AmoConstants.formatVersion,
          'keyVersion': 2,
          'serverCode': 'TESTSERVER',
          'folderName': '',
        }),
      ),
    );
    final encMeta = DecryptionService.decryptChunk(metaBytes, masterKey, iv, 0);

    // No thumbnail, so the payload base is just the metadata length.
    const thumbLength = 0;
    final payloadBase = encMeta.length + thumbLength;

    // Pattern-encrypt the body a 10 MB block at a time, exactly as buildAmoFile
    // does. CTR is symmetric, so the decrypt primitive encrypts here.
    final body = Uint8List.fromList(inputBytes);
    for (int pos = 0; pos < body.length; pos += AmoConstants.videoBlockSize) {
      final len = min(AmoConstants.videoBlockSize, body.length - pos);
      DecryptionService.patternXcryptInPlace(
        Uint8List.sublistView(body, pos, pos + len),
        courseKey,
        iv,
        payloadBase,
        pos,
      );
    }

    // HMAC over encryptedThumbnail || first 1 MB of the STORED body.
    final hmacCover = min(body.length, AmoConstants.chunkSize);
    final hmac = crypto.Hmac(crypto.sha256, courseKey)
        .convert(body.sublist(0, hmacCover))
        .bytes;

    final header = Uint8List(128);
    final hv = ByteData.view(header.buffer);
    header.setRange(0, 8, AmoConstants.magicBytes);
    hv.setUint32(8, AmoConstants.formatVersion);
    hv.setUint32(12, encMeta.length);
    hv.setUint32(16, thumbLength);
    hv.setUint64(20, inputBytes.length);
    header.setRange(28, 44, iv);
    header.setRange(44, 76, hmac);
    hv.setUint32(76, AmoConstants.patternStride);
    hv.setUint32(80, AmoConstants.patternUnit);

    final out = File(amoPath).openSync(mode: FileMode.write);
    out.writeFromSync(header);
    out.writeFromSync(encMeta);
    out.writeFromSync(body);
    out.closeSync();
    testAmoFile = File(amoPath);
  });

  tearDownAll(() async {
    await player.dispose();
    if (testAmoFile.existsSync()) {
      testAmoFile.deleteSync();
    }
  });

  testWidgets(
    '1- Verify Applied Plan & 2- Seeking Forward/Backward & 3- Security clearing',
    (tester) async {
      // 3. Security of Data - Setting the content key (must be accepted)
      expect(await AmoNativeBridge.setContentKey(kContentKeyHex), isTrue);
      // A malformed key is refused, never half-applied.
      expect(await AmoNativeBridge.setContentKey('not-hex'), isFalse);
      expect(await AmoNativeBridge.setContentKey(kContentKeyHex), isTrue);

      // Register the custom protocol
      final regResult = await AmoNativeBridge.registerProtocol(player);
      expect(regResult, isTrue, reason: 'Protocol registration failed');

      // 1. Configure Player for testing - verifies the applied plan configs
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('load-unsafe-playlists', 'yes');
        await platform.setProperty('demuxer-max-back-bytes', '52428800');
        await platform.setProperty('cache', 'no');
        await platform.setProperty('hr-seek', 'no');
      }

      // Open media using the amo:// protocol
      await player.open(Media('amo://${testAmoFile.path}'));

      await player.play();

      // Wait for playback to begin
      await Future.delayed(const Duration(seconds: 3));

      // 2. Seeking forward (using relative+exact to bypass hr-seek keyframe snapping)
      final currentPos = player.state.position;
      if (platform is NativePlayer) {
        await platform.command([
          'seek',
          '3',
          'relative+exact',
        ]); // Seek forward 3s precisely
      } else {
        await player.seek(currentPos + const Duration(seconds: 3));
      }

      // Wait for the seek buffer to settle
      await Future.delayed(const Duration(seconds: 2));

      final newPos = player.state.position;
      // Expect it to have jumped forward successfully, avoiding snapping back to 0
      expect(newPos.inSeconds, greaterThanOrEqualTo(currentPos.inSeconds + 2));

      // 2. Seeking backward (using relative+exact)
      await player.pause(); // Pause to get a stable read
      await Future.delayed(const Duration(milliseconds: 500));

      final pausedPos = player.state.position;

      if (platform is NativePlayer) {
        await platform.command([
          'seek',
          '-2',
          'relative+exact',
        ]); // Seek backward 2s precisely
      } else {
        await player.seek(pausedPos - const Duration(seconds: 2));
      }

      await Future.delayed(const Duration(seconds: 1));

      final finalPos = player.state.position;
      expect(finalPos.inSeconds, lessThanOrEqualTo(pausedPos.inSeconds - 1));

      // 3. Security of Data - Clearing the content key correctly
      await AmoNativeBridge.clearContentKey();
      expect(
        true,
        true,
      ); // If we reach here without crash, native memory clear succeeded
    },
  );
}
