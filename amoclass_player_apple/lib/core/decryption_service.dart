import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart' as crypto_lib;
import 'package:path_provider/path_provider.dart';
import 'constants.dart';
import '../services/auth_service.dart';
import 'package:amo_core/core/amo_exceptions.dart';

// Typed AMO exceptions live in the shared package so both players — and,
// once localized, one .arb entry each — use the same four strings.
export 'package:amo_core/core/amo_exceptions.dart';

/// Parsed AMO file header
class AmoFileHeader {
  final int version;
  final int metadataLength;
  final int thumbnailLength;
  final int videoDataLength;
  final Uint8List iv;
  final Uint8List hmac;

  // Parsed metadata
  final String videoName;
  final String originalExtension;
  final int originalSize;
  final String? folderName;
  final String contentType; // 'video' or 'pdf'
  final String? serverCode; // server code the file was encrypted for
  final int keyVersion; // 1 = legacy master key, 2 = HMAC-derived key

  // Calculated offsets
  final int metadataOffset;
  final int thumbnailOffset;
  final int videoDataOffset;

  AmoFileHeader({
    required this.version,
    required this.metadataLength,
    required this.thumbnailLength,
    required this.videoDataLength,
    required this.iv,
    required this.hmac,
    required this.videoName,
    required this.originalExtension,
    required this.originalSize,
    this.folderName,
    this.contentType = 'video',
    this.serverCode,
    this.keyVersion = 1,
    required this.metadataOffset,
    required this.thumbnailOffset,
    required this.videoDataOffset,
  });

  bool get isPdf => contentType == 'pdf';
}

/// AMO Decryption Service
class DecryptionService {
  /// Header cache: avoids re-parsing headers for files already seen.
  static final Map<String, AmoFileHeader> _headerCache = {};

  /// Clear the header cache (call on logout / course switch).
  static void clearHeaderCache() => _headerCache.clear();

  /// Decrypt chunk using AES-256-CTR
  static Uint8List decryptChunk(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
    int offset,
  ) {
    final cipher = _getCipherAtOffset(key, iv, offset);
    final output = Uint8List(data.length);
    cipher.processBytes(data, 0, data.length, output, 0);
    return output;
  }

  /// Create a cipher positioned at a given byte offset.
  /// Public for use by the streaming isolate's cipher cache.
  static CTRStreamCipher createCipherAtOffset(
    Uint8List key,
    Uint8List iv,
    int offset,
  ) => _getCipherAtOffset(key, iv, offset);

  static CTRStreamCipher _getCipherAtOffset(
    Uint8List key,
    Uint8List iv,
    int offset,
  ) {
    final blockIndex = offset ~/ 16;
    final counterIV = Uint8List.fromList(iv);
    _addToCounter(counterIV, blockIndex);

    final cipher = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), counterIV));

    final partialOffset = offset % 16;
    if (partialOffset > 0) {
      final dummy = Uint8List(partialOffset);
      cipher.processBytes(dummy, 0, partialOffset, Uint8List(partialOffset), 0);
    }

    return cipher;
  }

  static void _addToCounter(Uint8List counter, int value) {
    int carry = value;
    for (int i = counter.length - 1; i >= 0 && carry > 0; i--) {
      carry += counter[i];
      counter[i] = carry & 0xFF;
      carry >>= 8;
    }
  }

  /// v2 pattern (de)cryption of a span of video body, IN PLACE.
  ///
  /// Gathers the encrypted units into one contiguous buffer, runs a single CTR
  /// pass over it, scatters them back. The gather is the whole trick: a 10 MB
  /// block holds 65,536 units, and 65,536 separate cipher calls would cost far
  /// more than the 1 MB of AES they actually perform.
  ///
  /// It is also the only correct keystream, not merely the fast one. Every
  /// gathered byte is contiguous in cipher space — a unit ends exactly where the
  /// next begins, because the counter skips the cleartext entirely — so the
  /// units must be fed to one continuous cipher run.
  ///
  /// [bodyPosition] is where [block] starts within the video body and MUST be a
  /// multiple of [AmoConstants.patternStride] — otherwise the block's first byte
  /// is not the start of an encrypted unit and every unit in it is keyed to the
  /// wrong counter. Note that 1 MB is *not* stride-aligned (1048576 % 160 = 96),
  /// so the obvious chunk size is exactly the one that silently corrupts;
  /// callers that read in windows must round up to a stride (1048640).
  ///
  /// Taking the position rather than a pre-computed counter is deliberate: the
  /// counter is derived here, so a caller cannot pass a plausible-looking wrong
  /// one, and the assert catches the misalignment in debug builds.
  ///
  /// Returns how many bytes were fed through the cipher.
  static int patternXcryptInPlace(
    Uint8List block,
    Uint8List key,
    Uint8List iv,
    int payloadBase,
    int bodyPosition,
  ) {
    assert(
      bodyPosition % AmoConstants.patternStride == 0,
      'block must start on a ${AmoConstants.patternStride}-byte stride '
      'boundary; got $bodyPosition',
    );
    final cryptoOffset =
        payloadBase + AmoConstants.patternEncryptedBytes(bodyPosition);
    final total = AmoConstants.patternEncryptedBytes(block.length);
    if (total == 0) return 0;

    final gathered = Uint8List(total);
    int g = 0;
    for (int p = 0; p < block.length; p += AmoConstants.patternStride) {
      final take = min(AmoConstants.patternUnit, block.length - p);
      gathered.setRange(g, g + take, block, p);
      g += take;
    }

    final out = decryptChunk(gathered, key, iv, cryptoOffset);

    int e = 0;
    for (int p = 0; p < block.length; p += AmoConstants.patternStride) {
      final take = min(AmoConstants.patternUnit, block.length - p);
      block.setRange(p, p + take, out, e);
      e += take;
    }
    return total;
  }

  /// Parse AMO file header and extract metadata
  static Future<AmoFileHeader?> parseHeader(String filePath) async {
    // Check cache first
    final cached = _headerCache[filePath];
    if (cached != null) return cached;

    final file = File(filePath);
    if (!await file.exists()) return null;

    final raf = await file.open(mode: FileMode.read);
    try {
      final headerBytes = Uint8List(AmoConstants.headerSize);
      await raf.readInto(headerBytes);

      // Verify magic bytes
      for (int i = 0; i < AmoConstants.magicBytes.length; i++) {
        if (headerBytes[i] != AmoConstants.magicBytes[i]) {
          return null;
        }
      }

      final byteData = ByteData.view(headerBytes.buffer);
      int offset = 8;

      final version = byteData.getUint32(offset, Endian.big);
      offset += 4;

      // v2-only build. A v1 container has a completely different video layout
      // (100 KB head per 10 MB block vs. the uniform 160/16 pattern), so reading
      // one here would not fail loudly — it would hand the decoder plausible-
      // looking garbage. Refuse it instead.
      if (version != AmoConstants.formatVersion) {
        if (kDebugMode) {
          debugPrint(
            '[AMO] unsupported container version $version '
            '(this build reads v${AmoConstants.formatVersion} only): $filePath',
          );
        }
        return null;
      }

      final metadataLength = byteData.getUint32(offset, Endian.big);
      offset += 4;

      final thumbnailLength = byteData.getUint32(offset, Endian.big);
      offset += 4;

      final videoDataLength = byteData.getUint64(offset, Endian.big);
      offset += 8;

      final iv = Uint8List.fromList(
        headerBytes.sublist(offset, offset + AmoConstants.ivSize),
      );
      offset += AmoConstants.ivSize;

      final hmac = Uint8List.fromList(
        headerBytes.sublist(offset, offset + AmoConstants.hmacSize),
      );

      // Read and decrypt metadata
      final metadataOffset = AmoConstants.headerSize;
      final encryptedMetadata = Uint8List(metadataLength);
      await raf.setPosition(metadataOffset);
      await raf.readInto(encryptedMetadata);

      final masterKey = AmoConstants.getMasterKey();
      final decryptedMetadata = decryptChunk(
        encryptedMetadata,
        masterKey,
        iv,
        0,
      );
      final metadataJson =
          jsonDecode(utf8.decode(decryptedMetadata)) as Map<String, dynamic>;

      final thumbnailOffset = metadataOffset + metadataLength;
      final videoDataOffset = thumbnailOffset + thumbnailLength;

      // Determine content type
      String ct = (metadataJson['contentType'] as String?) ?? 'video';
      final rawExt = (metadataJson['originalExtension'] ?? '')
          .toString()
          .toLowerCase();
      if (ct == 'video' && rawExt == 'pdf') ct = 'pdf';

      final header = AmoFileHeader(
        version: version,
        metadataLength: metadataLength,
        thumbnailLength: thumbnailLength,
        videoDataLength: videoDataLength,
        iv: iv,
        hmac: hmac,
        videoName: (metadataJson['name'] as String?) ?? 'Unknown',
        originalExtension: rawExt.isNotEmpty ? rawExt : 'mp4',
        originalSize: (metadataJson['originalSize'] as int?) ?? 0,
        folderName: metadataJson['folderName'] as String?,
        contentType: ct,
        serverCode: metadataJson['serverCode'] as String?,
        keyVersion: (metadataJson['keyVersion'] as int?) ?? 1,
        metadataOffset: metadataOffset,
        thumbnailOffset: thumbnailOffset,
        videoDataOffset: videoDataOffset,
      );

      // Cache the parsed header
      _headerCache[filePath] = header;
      return header;
    } catch (e) {
      return null;
    } finally {
      await raf.close();
    }
  }

  /// Get the correct data key based on key version.
  static Uint8List _getDataKey(AmoFileHeader header) {
    if (header.keyVersion >= 2) {
      final credential = AuthService.activeCredential;
      final courseSecret = AuthService.activeCourseSecret;
      if (credential != null && courseSecret != null) {
        final hmac = crypto_lib.Hmac(
          crypto_lib.sha256,
          utf8.encode(credential),
        );
        final digest = hmac.convert(utf8.encode(courseSecret));
        return Uint8List.fromList(digest.bytes);
      }
    }
    // Fallback to legacy master key — log warning
    if (kDebugMode) {
      debugPrint(
        '[AMO] WARNING: Using legacy master key (v1) — '
        'consider re-encrypting with derived keys (v2+)',
      );
    }
    return AmoConstants.getMasterKey();
  }

  /// Zero out a key buffer to prevent lingering key material in memory.
  static void _zeroKey(Uint8List key) {
    for (int i = 0; i < key.length; i++) {
      key[i] = 0;
    }
  }

  /// Get the app-private temp directory for decrypted files.
  static Future<Directory> _getSecureTempDir() async {
    final appDir = await getApplicationSupportDirectory();
    final tmpDir = Directory('${appDir.path}/amo_tmp');
    if (!await tmpDir.exists()) {
      await tmpDir.create(recursive: true);
    }
    return tmpDir;
  }

  /// Securely delete a file by overwriting with zeros before removal.
  static Future<void> _secureDelete(File file) async {
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      final sink = file.openWrite();
      final zeroChunk = Uint8List(min(length, AmoConstants.chunkSize));
      int written = 0;
      while (written < length) {
        final remaining = length - written;
        final chunkLen = remaining < zeroChunk.length
            ? remaining
            : zeroChunk.length;
        sink.add(
          chunkLen == zeroChunk.length ? zeroChunk : Uint8List(chunkLen),
        );
        written += chunkLen;
      }
      await sink.flush();
      await sink.close();
      await file.delete();
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Verify the HMAC stored in the file header.
  ///
  /// v2-only build: there is no legacy exemption. An all-zero HMAC or a
  /// keyVersion below 2 used to be waved through (`allowLegacyUnverified`) so v1
  /// content in the field kept playing, but that was also a downgrade bypass —
  /// strip the HMAC to zeros and verification skipped itself. Every file this
  /// build accepts is v2, so both cases now fail closed. The native decryptor
  /// mirrors this (AMO_ENFORCE_NATIVE_HMAC).
  static Future<bool> verifyHmac(String filePath, AmoFileHeader header) async {
    final isAllZero = header.hmac.every((b) => b == 0);
    if (isAllZero) return false;
    if (header.keyVersion < 2) return false;

    final dataKey = _getDataKey(header);
    final file = File(filePath);
    final raf = await file.open(mode: FileMode.read);

    try {
      final thumbStart = AmoConstants.headerSize + header.metadataLength;
      final videoBytes = header.videoDataLength > AmoConstants.chunkSize
          ? AmoConstants.chunkSize
          : header.videoDataLength;
      final hmacDataLen = header.thumbnailLength + videoBytes;

      await raf.setPosition(thumbStart);
      final hmacData = Uint8List(hmacDataLen);
      await raf.readInto(hmacData);

      final hmacComputer = crypto_lib.Hmac(crypto_lib.sha256, dataKey);
      final computed = hmacComputer.convert(hmacData);
      final computedBytes = Uint8List.fromList(computed.bytes);

      // Constant-time comparison
      if (computedBytes.length != header.hmac.length) return false;
      int diff = 0;
      for (int i = 0; i < computedBytes.length; i++) {
        diff |= computedBytes[i] ^ header.hmac[i];
      }
      return diff == 0;
    } finally {
      await raf.close();
    }
  }

  /// Extract and decrypt thumbnail
  static Future<Uint8List?> extractThumbnail(String filePath) async {
    final header = await parseHeader(filePath);
    if (header == null || header.thumbnailLength == 0) return null;

    final hmacOk = await verifyHmac(filePath, header);
    if (!hmacOk) {
      if (kDebugMode) {
        debugPrint(
          '[AMO] HMAC verification failed — wrong key or tampered file',
        );
      }
      return null;
    }

    final file = File(filePath);
    final raf = await file.open(mode: FileMode.read);
    Uint8List? dataKey;
    try {
      await raf.setPosition(header.thumbnailOffset);
      final encryptedThumb = Uint8List(header.thumbnailLength);
      await raf.readInto(encryptedThumb);

      dataKey = _getDataKey(header);
      final offset = header.metadataLength;
      return decryptChunk(encryptedThumb, dataKey, header.iv, offset);
    } finally {
      if (dataKey != null) _zeroKey(dataKey);
      await raf.close();
    }
  }

  /// Decrypt an embedded thumbnail from an in-memory buffer holding at least
  /// the first (headerSize + metadataLength + thumbnailLength) bytes of an
  /// .amo file. Used for online-tab previews fetched via an HTTP Range request,
  /// so a thumbnail can be shown without downloading the whole file.
  ///
  /// HMAC is intentionally not verified here: a wrong key just yields bytes
  /// that fail to decode as an image and the caller shows a fallback. Download
  /// and playback keep their full HMAC / server-code checks. The data key
  /// never leaves the device and the file stays encrypted at rest — same trust
  /// model as the offline tab.
  static Uint8List? extractThumbnailFromBytes(Uint8List bytes) {
    try {
      if (bytes.length < AmoConstants.headerSize) return null;

      for (int i = 0; i < AmoConstants.magicBytes.length; i++) {
        if (bytes[i] != AmoConstants.magicBytes[i]) return null;
      }

      final byteData = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.length,
      );
      int offset = 8; // skip magic
      offset += 4; // skip version
      final metadataLength = byteData.getUint32(offset, Endian.big);
      offset += 4;
      final thumbnailLength = byteData.getUint32(offset, Endian.big);
      offset += 4;
      offset += 8; // skip videoDataLength
      final iv = Uint8List.fromList(
        bytes.sublist(offset, offset + AmoConstants.ivSize),
      );

      if (thumbnailLength == 0) return null;

      final metadataOffset = AmoConstants.headerSize;
      final thumbnailOffset = metadataOffset + metadataLength;
      final thumbnailEnd = thumbnailOffset + thumbnailLength;
      if (bytes.length < thumbnailEnd) return null; // buffer too small

      // Decrypt metadata with the master key to read the key version.
      final encryptedMetadata = Uint8List.sublistView(
        bytes,
        metadataOffset,
        thumbnailOffset,
      );
      final masterKey = AmoConstants.getMasterKey();
      final metadataJson = jsonDecode(
        utf8.decode(decryptChunk(encryptedMetadata, masterKey, iv, 0)),
      );
      final keyVersion = (metadataJson['keyVersion'] ?? 1) as int;

      // Derive the data key: v2+ = HMAC(credential, courseSecret), else master.
      Uint8List dataKey;
      if (keyVersion >= 2) {
        final credential = AuthService.activeCredential;
        final courseSecret = AuthService.activeCourseSecret;
        if (credential == null || courseSecret == null) return null;
        final hmac = crypto_lib.Hmac(
          crypto_lib.sha256,
          utf8.encode(credential),
        );
        dataKey = Uint8List.fromList(
          hmac.convert(utf8.encode(courseSecret)).bytes,
        );
      } else {
        dataKey = masterKey;
      }

      final encryptedThumb = Uint8List.sublistView(
        bytes,
        thumbnailOffset,
        thumbnailEnd,
      );
      // CTR offset for the thumbnail matches the on-disk path (metadataLength).
      final result = decryptChunk(encryptedThumb, dataKey, iv, metadataLength);
      _zeroKey(dataKey);
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Decrypt a range of video data (for streaming).
  static Future<Uint8List> decryptVideoRange(
    String filePath,
    AmoFileHeader header,
    int start,
    int length,
  ) async {
    final file = File(filePath);
    final raf = await file.open(mode: FileMode.read);
    Uint8List? dataKey;
    try {
      final base = header.metadataLength + header.thumbnailLength;
      dataKey = _getDataKey(header);

      // PDFs are one continuous CTR stream — any offset is a valid start.
      if (header.isPdf) {
        await raf.setPosition(header.videoDataOffset + start);
        final buf = Uint8List(length);
        final bytesRead = await raf.readInto(buf);
        final actual = bytesRead < length
            ? Uint8List.sublistView(buf, 0, bytesRead)
            : buf;
        return decryptChunk(actual, dataKey, header.iv, base + start);
      }

      // Video is patterned, so the cipher can only be positioned at the start of
      // an encrypted unit. Widen the read to stride boundaries, decrypt, trim.
      const stride = AmoConstants.patternStride;
      final alignedStart = (start ~/ stride) * stride;
      final wantedEnd = min(start + length, header.videoDataLength);
      final alignedEnd = min(
        ((wantedEnd + stride - 1) ~/ stride) * stride,
        header.videoDataLength,
      );

      await raf.setPosition(header.videoDataOffset + alignedStart);
      final window = Uint8List(alignedEnd - alignedStart);
      final bytesRead = await raf.readInto(window);
      final actual = bytesRead < window.length
          ? Uint8List.sublistView(window, 0, bytesRead)
          : window;

      patternXcryptInPlace(actual, dataKey, header.iv, base, alignedStart);

      final from = start - alignedStart;
      final available = actual.length - from;
      if (available <= 0) return Uint8List(0);
      return actual.sublist(from, from + min(length, available));
    } finally {
      if (dataKey != null) _zeroKey(dataKey);
      await raf.close();
    }
  }

  /// Decrypt entire video to a temporary file for playback.
  /// Throws [AmoWrongCourseException] if HMAC fails.
  /// Throws [AmoDecryptionException] on other decryption errors.
  static Future<String> decryptToTempFile(
    String filePath,
    AmoFileHeader header, {
    void Function(double progress)? onProgress,
  }) async {
    final hmacOk = await verifyHmac(filePath, header);
    if (!hmacOk) {
      throw const AmoWrongCourseException();
    }

    final tempDir = await _getSecureTempDir();
    final random = Random.secure();
    final randomId = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    // Use .tmp extension — don't hint at original file type
    final tempFile = File('${tempDir.path}/amo_play_$randomId.tmp');

    final sourceFile = File(filePath);
    final raf = await sourceFile.open(mode: FileMode.read);
    final sink = tempFile.openWrite();
    final dataKey = _getDataKey(header);

    try {
      await raf.setPosition(header.videoDataOffset);

      int bytesDecrypted = 0;
      final totalSize = header.videoDataLength;
      final readBuffer = Uint8List(AmoConstants.chunkSize);

      int loopCount = 0;
      while (bytesDecrypted < totalSize) {
        final remaining = totalSize - bytesDecrypted;

        if (header.contentType == 'pdf') {
          final chunkSize = remaining < AmoConstants.chunkSize
              ? remaining
              : AmoConstants.chunkSize;

          final encryptedChunk = chunkSize == AmoConstants.chunkSize
              ? readBuffer
              : Uint8List(chunkSize);
          final bytesRead = await raf.readInto(encryptedChunk);
          if (bytesRead == 0) break;

          final actualChunk = bytesRead < chunkSize
              ? Uint8List.fromList(encryptedChunk.sublist(0, bytesRead))
              : encryptedChunk;

          final encryptionOffset =
              header.metadataLength + header.thumbnailLength + bytesDecrypted;
          final decryptedChunk = decryptChunk(
            actualChunk,
            dataKey,
            header.iv,
            encryptionOffset,
          );

          sink.add(decryptedChunk);
          bytesDecrypted += bytesRead;
        } else {
          // Video: v2 pattern — 16 encrypted bytes of every 160, uniformly.
          final blockSize = remaining < AmoConstants.videoBlockSize
              ? remaining
              : AmoConstants.videoBlockSize;

          final blockBuffer = Uint8List(blockSize);
          final bytesRead = await raf.readInto(blockBuffer);
          if (bytesRead == 0) break;

          // A view, not a copy: patternXcryptInPlace writes through it.
          final actualBlock = bytesRead < blockSize
              ? Uint8List.sublistView(blockBuffer, 0, bytesRead)
              : blockBuffer;

          // 10 MB is a whole number of strides, so every block after the first
          // still starts on a stride boundary.
          patternXcryptInPlace(
            actualBlock,
            dataKey,
            header.iv,
            header.metadataLength + header.thumbnailLength,
            bytesDecrypted,
          );
          sink.add(actualBlock);

          bytesDecrypted += bytesRead;
        }

        loopCount++;
        if (loopCount % 4 == 0) await Future.delayed(Duration.zero);

        onProgress?.call(bytesDecrypted / totalSize);
      }

      await sink.flush();
      await sink.close();
      return tempFile.path;
    } catch (e) {
      await sink.close();
      if (await tempFile.exists()) await _secureDelete(tempFile);
      if (e is AmoWrongCourseException || e is AmoFileCorruptedException) {
        rethrow;
      }
      throw AmoDecryptionException('Decryption failed: ${e.runtimeType}');
    } finally {
      _zeroKey(dataKey);
      await raf.close();
    }
  }

  /// Clean up temp files — securely wipes all decrypted content.
  /// Also cleans legacy files from system temp dir.
  static Future<void> cleanupTempFiles() async {
    clearHeaderCache();

    // Clean app-private temp dir
    try {
      final appDir = await getApplicationSupportDirectory();
      final tmpDir = Directory('${appDir.path}/amo_tmp');
      if (await tmpDir.exists()) {
        final files = await tmpDir.list().toList();
        for (final entity in files) {
          if (entity is File) {
            await _secureDelete(entity);
          }
        }
      }
    } catch (_) {}

    // Also clean legacy files from system temp (migration)
    try {
      final sysTemp = Directory.systemTemp;
      final files = await sysTemp.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.contains('amo_play_')) {
          await _secureDelete(entity);
        }
      }
    } catch (_) {}
  }
}
