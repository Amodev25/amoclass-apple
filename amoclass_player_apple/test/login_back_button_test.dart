import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'package:amo_player_apple/screens/login_screen.dart';
import 'package:amo_player_apple/services/auth_service.dart';
import 'package:amo_player_apple/services/session_service.dart';

/// The login screen offers a way back ONLY when it was opened to add a course
/// while other courses are signed in. On a first login there is nothing to go
/// back to, so neither the button nor a system/swipe pop may appear.
void main() {
  final l10n = lookupAmoL10n(const Locale('en'));
  final backButton = find.byTooltip(l10n.verifyBackToCourses);

  StoredCourse course() => StoredCourse(
    studentId: 7,
    studentName: 'Hoda Samir Fathy',
    teacherId: 1,
    teacherName: 'Instructor',
    courseName: 'A Course',
    serverCode: 'SERVERCODE-AA',
  );

  /// A stand-in course list that pushes the login screen, as course select does.
  Future<void> openLogin(WidgetTester tester, {required bool adding}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AmoL10n.localizationsDelegates,
        supportedLocales: LocaleService.supportedLocales,
        // The test font draws every glyph a full em wide, so the login card's
        // footer row (capped at 440 px) overflows at real sizes. Half-size
        // text keeps the layout honest without swallowing overflow errors.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LoginScreen(isAddingCourse: adding),
                ),
              ),
              child: const Text('course list'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('course list'));
    await tester.pumpAndSettle();
  }

  bool loginCanPop(WidgetTester tester) => tester
      .widget<PopScope>(
        find.descendant(
          of: find.byType(LoginScreen),
          matching: find.byWidgetPredicate((w) => w is PopScope),
        ),
      )
      .canPop;

  tearDown(() => AuthService.restoreFromSession(const []));

  testWidgets('add-course mode with a signed-in course shows back', (
    tester,
  ) async {
    AuthService.restoreFromSession([course()]);
    await openLogin(tester, adding: true);

    expect(backButton, findsOneWidget);
    expect(loginCanPop(tester), isTrue);

    await tester.tap(backButton);
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('course list'), findsOneWidget);
  });

  testWidgets('first login shows no back and blocks pops', (tester) async {
    AuthService.restoreFromSession([course()]);
    await openLogin(tester, adding: false);

    expect(backButton, findsNothing);
    expect(loginCanPop(tester), isFalse);
  });

  testWidgets('add-course mode with an empty session shows no back', (
    tester,
  ) async {
    AuthService.restoreFromSession(const []);
    await openLogin(tester, adding: true);

    expect(backButton, findsNothing);
    expect(loginCanPop(tester), isFalse);
  });
}
