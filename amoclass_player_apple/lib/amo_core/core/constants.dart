import 'dart:typed_data';

// AMO Encryption Constants - MUST match encryptor
class AmoConstants {
  static const String magicString = 'AMOENC01';
  static const List<int> magicBytes = [
    0x41,
    0x4D,
    0x4F,
    0x45,
    0x4E,
    0x43,
    0x30,
    0x31,
  ];

  /// The ONLY container version this build reads or writes.
  ///
  /// v1 (first 100 KB of every 10 MB block encrypted) is gone. It left 98.83% of
  /// a video in the clear as one contiguous 9.90 MB run per block, which could be
  /// carved out and remuxed into a watchable file with no key at all — the header
  /// is cleartext and self-describing, so the payload offset falls straight out of
  /// it. v1 files are rejected rather than played; nothing in the field predates
  /// this, so there is no back-compat to keep.
  static const int formatVersion = 2;
  static const int headerSize = 128;
  static const int keySize = 32;
  static const int ivSize = 16;
  static const int hmacSize = 32;
  static const int chunkSize = 1024 * 1024;

  /// Unit the video body is walked in. Not a crypto boundary in v2 — the pattern
  /// is uniform across the whole payload — but 10 MB divides by [patternStride]
  /// exactly (65,536 strides), so a stride never straddles a block edge and each
  /// full block feeds exactly 1 MB through the cipher.
  static const int videoBlockSize = 10 * 1024 * 1024; // 10MB

  /// v2 pattern: encrypt [patternUnit] bytes, leave the rest of [patternStride]
  /// in the clear, repeating. The 1:9 shape CENC's `cbcs` scheme uses.
  ///
  /// The longest contiguous plaintext run is therefore 144 bytes. That is short
  /// enough that every H.264/H.265 slice takes several hits (entropy decoding
  /// desynchronises immediately), and shorter than an AAC frame at any bitrate a
  /// lecture would use — so the audio cannot be carved out frame by frame either.
  static const int patternStride = 160;
  static const int patternUnit = 16;

  /// Number of ENCRYPTED bytes contained in the first [length] bytes of the
  /// video body.
  ///
  /// This is the seek formula. The CTR counter advances only over bytes that were
  /// actually fed through the cipher, so the counter offset for content position
  /// `p` is `metadataLength + thumbnailLength + patternEncryptedBytes(p)` — never
  /// `p` itself. O(1), so random access costs nothing.
  static int patternEncryptedBytes(int length) {
    final strides = length ~/ patternStride;
    final rest = length % patternStride;
    return strides * patternUnit + (rest < patternUnit ? rest : patternUnit);
  }

  // Master key parts - IDENTICAL to encryptor
  static const List<int> _keyPart1 = [
    0x7A,
    0x3F,
    0x8B,
    0xC2,
    0x15,
    0xD4,
    0xE6,
    0x91,
    0x4D,
    0xA8,
    0x2C,
    0x67,
    0xF3,
    0x0E,
    0x5B,
    0x89,
  ];
  static const List<int> _keyPart2 = [
    0xB1,
    0x6D,
    0x23,
    0xF5,
    0x78,
    0x9A,
    0x4C,
    0xDE,
    0x03,
    0x56,
    0xE7,
    0x1B,
    0x8F,
    0xC4,
    0x32,
    0xA0,
  ];
  static const List<int> _xorMask1 = [
    0x2E,
    0x71,
    0xD9,
    0x84,
    0x43,
    0x96,
    0xA0,
    0xF7,
    0x1B,
    0xEE,
    0x7A,
    0x21,
    0xA5,
    0x48,
    0x0D,
    0xCF,
  ];
  static const List<int> _xorMask2 = [
    0xE3,
    0x2B,
    0x75,
    0xB3,
    0x0C,
    0xDC,
    0x1A,
    0x98,
    0x55,
    0x00,
    0xA1,
    0x4D,
    0xD9,
    0x82,
    0x64,
    0xF6,
  ];

  static Uint8List getMasterKey() {
    final key = Uint8List(keySize);
    for (int i = 0; i < 16; i++) {
      key[i] = _keyPart1[i] ^ _xorMask1[i];
      key[i + 16] = _keyPart2[i] ^ _xorMask2[i];
    }
    return key;
  }

  static const String defaultExtension = '.amo';

  // PDF formats
  static const List<String> pdfFormats = ['pdf'];

  /// Determine content type from file extension
  static String contentTypeFromExtension(String ext) {
    final lower = ext.toLowerCase().replaceAll('.', '');
    if (pdfFormats.contains(lower)) return 'pdf';
    return 'video';
  }
}
