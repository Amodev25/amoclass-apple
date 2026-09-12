/// AMO Core — shared library for the Lockclass player apps
/// (Windows, Android, iOS and macOS).
///
/// Contains encryption constants, decryption logic, data models,
/// typed exceptions, and shared service interfaces.
library amo_core;

export 'core/constants.dart';
export 'core/amo_exceptions.dart';
export 'models/video_item.dart';
export 'core/app_colors.dart';
export 'core/server_errors.dart';
export 'l10n/gen/amo_localizations.dart';
export 'services/locale_service.dart';
export 'widgets/language_toggle.dart';
