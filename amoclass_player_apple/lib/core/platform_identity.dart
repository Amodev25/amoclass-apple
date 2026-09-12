import 'dart:io' show Platform;

/// The platform name this build reports to the server.
///
/// A student's seat is bound to a platform: the teacher issues the seat for one
/// of them, and the server refuses a login from any other. iOS and macOS are
/// separate values rather than a single "apple" because what the app can
/// actually protect differs sharply between them — macOS blocks screen capture
/// outright and can lock the student in, while iOS can do neither. A teacher who
/// is willing to put a lesson on a Mac is not necessarily willing to put it on
/// an iPhone, and one shared value would take that choice away.
///
/// This must stay in step with the values the teacher dashboard offers and the
/// worker accepts; reporting a platform the server does not know means every
/// login is refused as a mismatch.
class PlatformIdentity {
  const PlatformIdentity._();

  static const String ios = 'ios';
  static const String macos = 'macos';

  /// The value to send with login and verification requests.
  static String get current => Platform.isMacOS ? macos : ios;
}
