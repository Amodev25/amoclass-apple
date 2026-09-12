import 'package:flutter/material.dart';

/// The one palette shared by both players.
///
/// Windows and Android render the same product and must not drift: before this
/// file moved here, Windows referenced these tokens while Android inlined 186
/// raw `Color(0x…)` literals of the same values. Add a token here rather than a
/// hex literal in a screen, and give it a name for what it IS, not where it is
/// first used.
///
/// Not covered here, deliberately: `Colors.white.withValues(alpha:)` dimming.
/// That is a legitimate idiom for de-emphasising foreground text on these dark
/// surfaces, not a colour choice, and it stays inline.
class AppColors {
  AppColors._();

  // Backgrounds
  static const Color scaffoldBg = Color(0xFF0A0A0A);
  static const Color surfaceDark = Color(0xFF0D0D0D);
  static const Color surface = Color(0xFF141414);
  static const Color iconChipBg = Color(0xFF1C1C1C);
  static const Color pillUnselectedBg = Color(0xFF1A1A1A);

  // Borders
  static const Color border = Color(0xFF2A2A2A);
  static const Color videoCardBorder = Color(0xFF1E1E1E);

  // Brand
  static const Color brandAccent = Colors.white;

  // Semantic accents
  static const Color error = Color(0xFFFF6B6B);
  static const Color folderAccent = Color(0xFFFFB74D);
  static const Color folderAccentAlt = Color(0xFFFF9800);
  static const Color pdfAccent = Color(0xFFEF5350);
  static const Color pdfAccentAlt = Color(0xFFE53935);

  /// Dark end of the PDF placeholder-thumbnail gradient, whose light end is
  /// [pdfAccentAlt] at 13% — a near-black with the same red cast, so the two
  /// read as one wash rather than a red fading into the page background.
  static const Color pdfThumbBg = Color(0xFF1A0A0A);

  static const Color filesTabAccent = Color(0xFFFF7043);
  static const Color focusGradientStart = Color(0xFFFF8F00);
  static const Color focusGradientEnd = Color(0xFFFF6D00);
  static const Color verifyAccent = Color(0xFFFF9800);
  static const Color pausedDownload = Color(0xFFFFAA00);

  // Online/cloud (library_screen only — player_screen's DRM badge keeps drmAccent)
  static const Color onlineAccent = Color(0xFF29B6F6);
  static const Color onlineGradientEnd = Color(0xFF0288D1);
  static const Color drmAccent = Color(0xFF00D4AA);

  // Muted text
  static const Color mutedGray = Color(0xFF888888);
}
