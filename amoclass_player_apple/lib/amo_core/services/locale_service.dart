import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/gen/amo_localizations.dart';

/// The app's language, and the one place that changes it.
///
/// Singleton, following the [ChangeNotifier] + `ListenableBuilder` idiom the
/// players already use for Focus Mode. `MaterialApp` listens to it, so flipping
/// the language re-renders everything in place — no restart, no reload.
///
/// **English is the default and stays the default.** Arabic is opt-in and the
/// choice is remembered; a student who never touches the toggle sees exactly
/// what they saw before this existed.
///
/// Persistence is a one-byte file rather than a preferences package: the only
/// state is a two-value enum, and `path_provider` is already a dependency here.
class LocaleService extends ChangeNotifier {
  static final LocaleService instance = LocaleService._();
  LocaleService._();

  static const supportedLocales = [Locale('en'), Locale('ar')];

  static const _fileName = '.amo_locale';

  Locale _locale = const Locale('en');
  Locale get locale => _locale;

  bool get isArabic => _locale.languageCode == 'ar';

  /// Strings for the current language, for code that has no [BuildContext].
  ///
  /// Widgets must keep using `AmoL10n.of(context)` — that one rebuilds when the
  /// language changes, this one does not. This exists for the service layer,
  /// which builds messages (network failures, session expiry) before any widget
  /// is involved, and where the alternative is threading a context through
  /// every call or returning English.
  AmoL10n get strings => lookupAmoL10n(_locale);

  /// Text direction for the current language. Widgets should almost never read
  /// this — use `Directionality.of(context)` or, better, directional insets and
  /// alignments, which follow it automatically.
  TextDirection get textDirection =>
      isArabic ? TextDirection.rtl : TextDirection.ltr;

  /// Load the remembered choice. Call once, before `runApp`, so the first frame
  /// is already in the right language and direction.
  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final code = (await f.readAsString()).trim();
      if (code == 'ar') _locale = const Locale('ar');
    } catch (_) {
      // An unreadable preference is not worth failing a launch over; English
      // is the default anyway.
    }
  }

  /// Switch language now; remember it in the background.
  ///
  /// The write is deliberately not awaited. The language has already changed in
  /// memory by the time this returns, and making a button press wait on disk
  /// only adds a way for the UI to stall — on a slow or unavailable app-support
  /// directory it would stall indefinitely.
  void setLocale(Locale locale) {
    if (locale.languageCode == _locale.languageCode) return;
    _locale = locale;
    notifyListeners();
    _persist(locale.languageCode);
  }

  void toggle() =>
      setLocale(isArabic ? const Locale('en') : const Locale('ar'));

  Future<void> _persist(String code) async {
    try {
      await (await _file()).writeAsString(code);
    } catch (_) {
      // The switch already happened in memory; losing it on restart is a much
      // smaller failure than throwing out of a button press.
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }
}
