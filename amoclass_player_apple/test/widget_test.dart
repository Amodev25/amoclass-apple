import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'package:amo_player_apple/main.dart';

void main() {
  // The old assertion was `find.text('AMO Player')`, which tied the only test
  // in the repo to one English string. It now checks the same thing through the
  // localizations, so the test says "the app came up in the right language"
  // rather than "the app came up in English".
  testWidgets('App loads in English by default', (WidgetTester tester) async {
    await tester.pumpWidget(const AmoPlayerApp());
    await tester.pump();

    final l10n = lookupAmoL10n(const Locale('en'));
    expect(find.text(l10n.appTitle), findsOneWidget);
  });

  testWidgets('App loads in Arabic when the locale is Arabic', (
    WidgetTester tester,
  ) async {
    // Reaching into the service rather than pumping a locale override, because
    // it is the service — not MaterialApp's locale resolution — that decides the
    // language at runtime, and that is the path worth testing.
    LocaleService.instance.setLocale(const Locale('ar'));
    addTearDown(() => LocaleService.instance.setLocale(const Locale('en')));

    await tester.pumpWidget(const AmoPlayerApp());
    await tester.pump();

    final l10n = lookupAmoL10n(const Locale('ar'));
    expect(find.text(l10n.appTitle), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text(l10n.appTitle))),
      TextDirection.rtl,
    );
  });
}
