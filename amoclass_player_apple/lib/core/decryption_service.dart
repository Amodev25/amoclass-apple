import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart' as crypto_lib;
import 'package:path_provider/path_provider.dart';
import 'constants.dart';
import '../services/auth_service.dart';
import 'package:amo_player_apple/amo_core/core/amo_exceptions.dart';

// Typed AMO exceptions live in the shared package so both players — and,
// once localized, one .arb entry each — use the same four strings.
export 'package:amo_player_apple/amo_core/core/amo_exceptions.dart';

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
      final fileLength = await raf.length();
      if (fileLength < AmoConstants.headerSize) return null;
      final headerBytes = Uint8List(AmoConstants.headerSize);
      if (await raf.readInto(headerBytes) != AmoConstants.headerSize) {
        return null;
      }

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

      // Bounds BEFORE any allocation: every length comes from the file, and a
      // crafted header could otherwise ask for gigabytes (contract §3.10).
      if (!headerFits(
        fileLength: fileLength,
        metadataLength: metadataLength,
        thumbnailLength: thumbnailLength,
        videoDataLength: videoDataLength,
      )) {
        if (kDebugMode) {
          debugPrint('[AMO] header lengths exceed the file: $filePath');
        }
        return null;
      }

      // Read and decrypt metadata
      final metadataOffset = AmoConstants.headerSize;
      final encryptedMetadata = Uint8List(metadataLength);
      await raf.setPosition(metadataOffset);
      if (await raf.readInto(encryptedMetadata) != metadataLength) return null;

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

  /// Largest metadata block accepted. Real metadata is a few hundred bytes of
  /// JSON; the cap stops a crafted header from making us allocate the file.
  static const int maxMetadataLength = 1024 * 1024;

  /// Whether the lengths a header declares fit inside a file of [fileLength]
  /// bytes. Checked before anything is allocated from those lengths.
  @visibleForTesting
  static bool headerFits({
    required int fileLength,
    required int metadataLength,
    required int thumbnailLength,
    required int videoDataLength,
  }) {
    if (metadataLength <= 0 || metadataLength > maxMetadataLength) return false;
    if (thumbnailLength < 0 || videoDataLength < 0) return false;
    final available = fileLength - AmoConstants.headerSize;
    if (available < 0) return false;
    // Compared one at a time, so the sum cannot overflow.
    if (metadataLength > available) return false;
    if (thumbnailLength > available - metadataLength) return false;
    return videoDataLength <= available - metadataLength - thumbnailLength;
  }

  /// The data key for v2 content: the active course's content key (64 hex
  /// digits, computed by the server). Null — and so every check fails closed —
  /// for older containers or when no well-formed key is held.
  static Uint8List? _getDataKey(AmoFileHeader header) {
    if (header.keyVersion < 2) return null;
    return contentKeyBytes(AuthService.activeContentKey);
  }

  /// Decodes a 64-hex-digit content key into its 32 bytes, or null.
  @visibleForTesting
  static Uint8List? contentKeyBytes(String? hex) {
    if (!isValidContentKey(hex)) return null;
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(hex!.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Zero out a key buffer to prevent lingering key material in memory.
  static void _zeroKey(Uint8List key) {
    for (int i = 0; i < key.length; i++) {
      key[i] = 0;
    }
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
    if (dataKey == null) return false;
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
      if (await raf.readInto(hmacData) != hmacDataLen) return false;

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
      _zeroKey(dataKey);
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
      if (dataKey == null) return null;
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
      if (metadataLength <= 0 || metadataLength > maxMetadataLength) {
        return null;
      }

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

      // v2 content only: the data key is the course content key.
      if (keyVersion < 2) return null;
      final dataKey = contentKeyBytes(AuthService.activeContentKey);
      if (dataKey == null) return null;

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
      if (dataKey == null) throw const AmoWrongCourseException();

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

  /// Largest PDF body decrypted into memory.
  static const int maxInMemoryPdfBytes = 256 * 1024 * 1024;

  /// Decrypts a PDF body into memory — never to disk (contract §3.9).
  ///
  /// The caller owns the returned buffer and should zero it when the document
  /// closes ([wipe]). Throws [AmoWrongCourseException] when the HMAC does not
  /// match the active course key, [AmoFileCorruptedException] when the file
  /// is not a readable PDF container, [AmoDecryptionException] otherwise.
  static Future<Uint8List> decryptToMemory(
    String filePath,
    AmoFileHeader header,
  ) async {
    if (!header.isPdf) throw const AmoFileCorruptedException();
    if (header.videoDataLength <= 0 ||
        header.videoDataLength > maxInMemoryPdfBytes) {
      throw const AmoFileCorruptedException();
    }
    if (!await verifyHmac(filePath, header)) {
      throw const AmoWrongCourseException();
    }
    final dataKey = _getDataKey(header);
    if (dataKey == null) throw const AmoWrongCourseException();

    final total = header.videoDataLength;
    final out = Uint8List(total);
    final raf = await File(filePath).open(mode: FileMode.read);
    try {
      await raf.setPosition(header.videoDataOffset);
      final base = header.metadataLength + header.thumbnailLength;
      var done = 0;
      var loops = 0;
      while (done < total) {
        final take = min(AmoConstants.chunkSize, total - done);
        final view = Uint8List.sublistView(out, done, done + take);
        final read = await raf.readInto(view);
        if (read != take) throw const AmoFileCorruptedException();
        // PDFs are one continuous CTR stream: decrypt this span in place.
        final plain = decryptChunk(view, dataKey, header.iv, base + done);
        out.setRange(done, done + take, plain);
        wipe(plain);
        done += take;
        if (++loops % 4 == 0) await Future<void>.delayed(Duration.zero);
      }
      return out;
    } catch (e) {
      wipe(out);
      if (e is AmoWrongCourseException || e is AmoFileCorruptedException) {
        rethrow;
      }
      throw AmoDecryptionException('Decryption failed: ${e.runtimeType}');
    } finally {
      _zeroKey(dataKey);
      await raf.close();
    }
  }

  /// Overwrites a decrypted buffer with zeros.
  static void wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);

  /// Clean up temp files — securely wipes any decrypted content an older
  /// build left on disk (this build no longer writes any).
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
