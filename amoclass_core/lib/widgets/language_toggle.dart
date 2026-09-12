import 'package:flutter/material.dart';

import '../services/locale_service.dart';

/// The one control that switches the app between English and Arabic.
///
/// It is labelled with the language it switches *to*, written in that language
/// — "العربية" while the app is in English, "English" while it is in Arabic.
/// A student who has landed in a language they cannot read can still find their
/// way out, which a label like "Language" or a flag icon does not allow.
///
/// Shared rather than duplicated because both players and every surface that
/// hosts it (login, library chrome) must agree on the wording; two toggles that
/// disagree read as two different settings.
class LanguageToggle extends StatelessWidget {
  /// Muted by default, to sit in a footer without competing with the primary
  /// action. Pass a brighter colour when it lives in app chrome.
  final Color? color;
  final double fontSize;

  const LanguageToggle({super.key, this.color, this.fontSize = 13});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LocaleService.instance,
      builder: (context, _) {
        final tint = color ?? Colors.white.withValues(alpha: 0.55);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => LocaleService.instance.toggle(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.translate, size: fontSize + 2, color: tint),
                  const SizedBox(width: 6),
                  Text(
                    // The target language, in the target language.
                    LocaleService.instance.isArabic ? 'English' : 'العربية',
                    style: TextStyle(
                      color: tint,
                      fontSize: fontSize,
                      fontWeight: FontWeight.w600,
                    ),
                    // The label is a fixed word in a fixed script; it must not
                    // flip with the surrounding Directionality.
                    textDirection: LocaleService.instance.isArabic
                        ? TextDirection.ltr
                        : TextDirection.rtl,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
