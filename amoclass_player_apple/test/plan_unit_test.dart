import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/amo_core/core/constants.dart';
import 'package:amo_player_apple/core/decryption_service.dart';

/// v2 pattern-encryption math for the Android player.
///
/// The container encrypts [AmoConstants.patternUnit] bytes of every
/// [AmoConstants.patternStride], uniformly across the video body. The one thing
/// that has repeatedly gone wrong here is the CTR counter: it advances ONLY over
/// bytes that were fed through the cipher, so a byte at body position `p` is
/// keyed to `base + patternEncryptedBytes(p)` — never to `p` itself.
///
/// Under v1 that same question ("what stride does the counter advance by?") was
/// answered differently by the encryptor (100 KB) and by every player (10 MB),
/// and nothing caught it because the old tests only ever exercised block 0,
/// where both answers are 0. Every test here that touches offsets therefore runs
/// across a ≥2-block body.
void main() {
  const stride = AmoConstants.patternStride;
  const unit = AmoConstants.patternUnit;
  const blockSize = AmoConstants.videoBlockSize;

  group('1. Pattern geometry', () {
    test('a 10MB block holds a whole number of strides', () {
      // If this ever fails, a stride straddles a block boundary and every
      // block-at-a-time consumer silently desynchronises.
      expect(blockSize % stride, 0, reason: '10MB must divide by the stride');
      expect(blockSize ~/ stride, 65536);
    });

    test('a full block feeds exactly 1MB through the cipher', () {
      expect(AmoConstants.patternEncryptedBytes(blockSize), 1024 * 1024);
    });

    test('the encrypted share is 10% — CENC cbcs 1:9', () {
      expect(unit / stride, closeTo(0.10, 0.0001));
    });

    test('the longest possible contiguous plaintext run is 144 bytes', () {
      // The entire reason v2 exists. 144 is below an AAC frame at any lecture
      // bitrate, so audio cannot be carved out frame by frame either.
      expect(stride - unit, 144);
    });

    test('this build is v2-only', () {
      expect(AmoConstants.formatVersion, 2);
    });

    test('1MB is NOT stride-aligned — the trap for chunked readers', () {
      // The obvious buffer size is the one that silently corrupts: a reader
      // that walks the body in 1 MB windows starts every window after the first
      // at 96 bytes into a stride, so its units are keyed to the wrong counter
      // and only the first window decrypts. Round up to 1048640 instead.
      expect(1024 * 1024 % stride, 96);
      expect(1048640 % stride, 0);
      // 10MB, the block size, is aligned — which is why block-at-a-time is safe.
      expect(blockSize % stride, 0);
    });
  });

  group('2. patternEncryptedBytes', () {
    test('boundary table', () {
      expect(AmoConstants.patternEncryptedBytes(0), 0);
      expect(AmoConstants.patternEncryptedBytes(1), 1);
      expect(AmoConstants.patternEncryptedBytes(15), 15);
      expect(AmoConstants.patternEncryptedBytes(16), 16);
      // Inside the cleartext run: the count stops climbing.
      expect(AmoConstants.patternEncryptedBytes(17), 16);
      expect(AmoConstants.patternEncryptedBytes(159), 16);
      expect(AmoConstants.patternEncryptedBytes(160), 16);
      expect(AmoConstants.patternEncryptedBytes(161), 17);
      expect(AmoConstants.patternEncryptedBytes(320), 32);
    });

    test('is monotonic and never exceeds 10% + one unit', () {
      int prev = 0;
      for (int p = 0; p < stride * 40; p++) {
        final n = AmoConstants.patternEncryptedBytes(p);
        expect(n, greaterThanOrEqualTo(prev));
        expect(n, lessThanOrEqualTo((p ~/ stride) * unit + unit));
        prev = n;
      }
    });

    test('block 1 does not start at zero — the bug-006 shape', () {
      // Under v1 the encryptor said 100KB and the players said 10MB for this
      // very quantity. There is now one answer and it is neither.
      expect(AmoConstants.patternEncryptedBytes(blockSize), 1024 * 1024);
      expect(AmoConstants.patternEncryptedBytes(blockSize), isNot(100 * 1024));
      expect(AmoConstants.patternEncryptedBytes(blockSize), isNot(blockSize));
    });
  });

  group('3. amo_read chunking agrees with a single whole-body pass', () {
    // Ported literally from amo_read() in amo_stream.c — same clamping, same
    // bounds. If the C changes, change this with it.
    List<int> cipherOffsetsForRead(int start, int nbytes, int base) {
      final out = <int>[];
      final end = start + nbytes;
      final encBefore = AmoConstants.patternEncryptedBytes(start);
      var cursor = base + encBefore;
      final firstStride = (start ~/ stride) * stride;
      for (int s = firstStride; s < end; s += stride) {
        int u0 = s, u1 = s + unit;
        if (u0 < start) u0 = start;
        if (u1 > end) u1 = end;
        if (u1 <= u0) continue;
        for (int b = u0; b < u1; b++) {
          out.add(cursor++);
        }
      }
      return out;
    }

    /// Ground truth: every encrypted body byte, in order, with the counter
    /// position the spec assigns it.
    List<int> cipherOffsetsWholeBody(int bodyLength, int base) {
      final out = <int>[];
      for (int p = 0; p < bodyLength; p++) {
        if (p % stride < unit) {
          out.add(base + AmoConstants.patternEncryptedBytes(p));
        }
      }
      return out;
    }

    const base = 2378; // metadataLength + thumbnailLength, arbitrary but fixed
    const bodyLength = 3 * stride * 1000; // 480,000 B — small enough to enumerate

    test('sequential reads of many sizes reproduce the whole-body mapping', () {
      final truth = cipherOffsetsWholeBody(bodyLength, base);

      for (final readSize in [1, 15, 16, 17, 159, 160, 161, 1000, 4096, 65536]) {
        final got = <int>[];
        int pos = 0;
        while (pos < bodyLength) {
          final n = min(readSize, bodyLength - pos);
          got.addAll(cipherOffsetsForRead(pos, n, base));
          pos += n;
        }
        expect(
          got,
          truth,
          reason: 'chunked reads of $readSize B disagree with the whole-body pass',
        );
      }
    });

    test('a read starting mid-unit picks up the counter mid-unit', () {
      // Position 5 is the 6th encrypted byte, so its counter is base + 5 — not
      // base, and not base + 16.
      final offsets = cipherOffsetsForRead(5, 20, base);
      expect(offsets.first, base + 5);
      expect(offsets.length, 11); // bytes 5..15 of the first unit
    });

    test('a read landing entirely in cleartext decrypts nothing', () {
      // Bytes 16..159 of a stride are clear; a read wholly inside them must not
      // advance the cipher at all.
      expect(cipherOffsetsForRead(20, 100, base), isEmpty);
    });

    test('seeking into block 1 resumes at exactly 1MB of keystream', () {
      final offsets = cipherOffsetsForRead(blockSize, 4096, base);
      expect(offsets.first, base + 1024 * 1024);
    });
  });

  group('4. Real cipher round-trip across a >10MB body', () {
    // The ≥2-block round-trip the old suite never had: block 0 alone cannot
    // distinguish a correct counter from several wrong ones.
    final key = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));
    final iv = Uint8List.fromList(List.generate(16, (i) => (i * 31 + 11) & 0xFF));
    const base = 2378;

    Uint8List body(int n) {
      final out = Uint8List(n);
      int s = 12345;
      for (int i = 0; i < n; i++) {
        s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
        out[i] = s & 0xFF;
      }
      return out;
    }

    test('block-at-a-time decrypt inverts block-at-a-time encrypt', () {
      final plain = body(25 * 1024 * 1024);
      final buf = Uint8List.fromList(plain);

      // Encrypt exactly as buildAmoFile does: one pass per 10MB block.
      for (int pos = 0; pos < buf.length; pos += blockSize) {
        final len = min(blockSize, buf.length - pos);
        DecryptionService.patternXcryptInPlace(
          Uint8List.sublistView(buf, pos, pos + len),
          key,
          iv,
          base,
          pos,
        );
      }

      expect(buf, isNot(equals(plain)), reason: 'nothing was encrypted');

      // 10% encrypted, so 90% of bytes must still match verbatim.
      int clear = 0;
      for (int i = 0; i < buf.length; i++) {
        if (buf[i] == plain[i]) clear++;
      }
      expect(clear / buf.length, closeTo(0.90, 0.01));

      // Decrypt back.
      for (int pos = 0; pos < buf.length; pos += blockSize) {
        final len = min(blockSize, buf.length - pos);
        DecryptionService.patternXcryptInPlace(
          Uint8List.sublistView(buf, pos, pos + len),
          key,
          iv,
          base,
          pos,
        );
      }
      expect(buf, equals(plain));
    });

    test('decrypting in stride-aligned chunks matches decrypting in blocks', () {
      // decryptVideoRange / the streaming server read in windows that are not
      // 10MB. Those must produce the same plaintext as decryptToTempFile.
      final plain = body(12 * 1024 * 1024);
      final cipher = Uint8List.fromList(plain);
      for (int pos = 0; pos < cipher.length; pos += blockSize) {
        final len = min(blockSize, cipher.length - pos);
        DecryptionService.patternXcryptInPlace(
          Uint8List.sublistView(cipher, pos, pos + len),
          key,
          iv,
          base,
          pos,
        );
      }

      for (final window in [stride, stride * 7, 1048640, blockSize]) {
        final out = Uint8List.fromList(cipher);
        for (int pos = 0; pos < out.length; pos += window) {
          final len = min(window, out.length - pos);
          DecryptionService.patternXcryptInPlace(
            Uint8List.sublistView(out, pos, pos + len),
            key,
            iv,
            base,
            pos,
          );
        }
        expect(out, equals(plain), reason: 'window of $window B diverged');
      }
    });

    test('no contiguous plaintext run survives encryption', () {
      // The carving attack v1 was vulnerable to, asserted directly: v1 left a
      // 9.90MB run here.
      final plain = body(2 * 1024 * 1024);
      final cipher = Uint8List.fromList(plain);
      DecryptionService.patternXcryptInPlace(cipher, key, iv, base, 0);

      int longest = 0, run = 0;
      for (int i = 0; i < cipher.length; i++) {
        if (cipher[i] == plain[i]) {
          run++;
          if (run > longest) longest = run;
        } else {
          run = 0;
        }
      }
      // 144 clear bytes, plus the odd byte that coincidentally ciphers to
      // itself (1-in-256 at each unit edge).
      expect(longest, lessThan(200));
    });
  });

  group('5. Security of data', () {
    test('keys are 32 bytes and the magic is 8', () {
      expect(AmoConstants.getMasterKey().length, 32);
      expect(AmoConstants.magicBytes.length, 8);
    });
  });
}
