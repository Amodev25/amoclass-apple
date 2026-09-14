import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one keychain configuration every secure read and write goes through.
///
/// * **iOS** — `first_unlock_this_device`: readable after the first unlock
///   (background refreshes work), and never migrated to another device through
///   a backup. A session or signing secret restored onto a different phone
///   would otherwise carry this device's seat binding with it.
///
/// * **macOS** — `usesDataProtectionKeychain: false`. The data-protection
///   keychain needs a keychain-access-groups entitlement, i.e. a signed app
///   with a team id; the app is built without one, and every call there
///   fails with -34018 (errSecMissingEntitlement). The file-based login
///   keychain works without it, sandboxed too (the sandbox has been on since
///   2026-09-14). The same this-device accessibility is passed for parity.
class AppSecureStorage {
  const AppSecureStorage._();

  static const FlutterSecureStorage instance = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );
}
