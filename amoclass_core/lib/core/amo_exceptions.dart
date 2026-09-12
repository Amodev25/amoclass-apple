/// File is damaged, truncated, or not a valid AMO container.
class AmoFileCorruptedException implements Exception {
  final String message;
  const AmoFileCorruptedException([
    this.message = 'File is damaged or incomplete.',
  ]);
  @override
  String toString() => message;
}

/// HMAC mismatch — file belongs to a different course or has been tampered.
class AmoWrongCourseException implements Exception {
  final String message;
  const AmoWrongCourseException([
    this.message = 'This file belongs to a different course.',
  ]);
  @override
  String toString() => message;
}

/// General decryption failure.
class AmoDecryptionException implements Exception {
  final String message;
  const AmoDecryptionException([this.message = 'Unable to decrypt this file.']);
  @override
  String toString() => message;
}

/// The file's embedded server code does not match the logged-in one.
///
/// Distinct from [AmoWrongCourseException]: that is an HMAC failure found while
/// decrypting, this is a header check made at import time, and the two raise
/// different dialogs.
///
/// The type carries the distinction because [message] is localized. The import
/// path used to recognise this case with `e.toString().contains('different
/// server')`, which stops working the moment the student switches to Arabic.
class AmoWrongServerCodeException implements Exception {
  final String message;
  const AmoWrongServerCodeException(this.message);
  @override
  String toString() => message;
}

/// A refusal from the student worker, carrying its machine-readable `code`.
///
/// [message] is already localized (see `localizeServerError`), so callers must
/// branch on [code], never on the text. `code` is null only when talking to a
/// worker old enough not to send one.
class AmoServerException implements Exception {
  final String message;
  final String? code;
  const AmoServerException(this.message, [this.code]);
  @override
  String toString() => message;
}
