import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'core/platform_ui.dart';
import 'services/session_service.dart';
import 'services/auth_service.dart';
import 'services/progress_service.dart';
import 'screens/login_screen.dart';
import 'screens/library_screen.dart';
import 'screens/course_select_screen.dart';
import 'screens/re_verify_screen.dart';
import 'core/anti_capture.dart';
import 'core/decryption_service.dart';
import 'widgets/focus_mode_widgets.dart';
import 'package:amo_core/amo_core.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService.instance.load();

  // Global error handlers — surface uncaught framework/async errors instead of
  // silently dropping them. Wire these to a crash reporter (Sentry/Crashlytics)
  // when one is added.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint('[AMO] FlutterError: ${details.exceptionAsString()}');
    }
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    if (kDebugMode) debugPrint('[AMO] Uncaught async error: $error');
    return true;
  };

  MediaKit.ensureInitialized();

  // Clean up any leftover decrypted temp files from crashes (awaited so a
  // freshly opened file can't race a pending secure-delete).
  await DecryptionService.cleanupTempFiles();

  // Orientation and system chrome are phone concepts. On macOS there is no
  // status bar to tint and no rotation to lock, and calling these leaves the
  // desktop window in an undefined state rather than doing nothing useful.
  if (PlatformUi.supportsOrientationLock) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.scaffoldBg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  await ProgressService.init();

  // Enable anti-screen capture BEFORE the first frame so there is no
  // unprotected window at launch.
  await AntiCapture.enableProtection();

  runApp(const AmoPlayerApp());
}

class AmoPlayerApp extends StatelessWidget {
  const AmoPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LocaleService.instance,
      builder: (context, _) => _app(context),
    );
  }

  Widget _app(BuildContext context) {
    return MaterialApp(
      title: 'Lockclass',
      debugShowCheckedModeBanner: false,
      locale: LocaleService.instance.locale,
      supportedLocales: LocaleService.supportedLocales,
      localizationsDelegates: AmoL10n.localizationsDelegates,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.scaffoldBg,
        primaryColor: AppColors.brandAccent,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: AppColors.mutedGray,
          surface: AppColors.surface,
          error: AppColors.error,
        ),
        // No fontFamily. 'Roboto' was pinned here and has NO Arabic
        // glyphs, so Arabic text fell through to an uncontrolled system
        // fallback with mismatched metrics. Letting Flutter pick the
        // platform default per script is correct until a bundled Arabic
        // face lands (see GLOSSARY-AR.md / pubspec fonts:).
      ),
      home: const SplashGate(),
      builder: (context, child) {
        return Stack(
          children: [
            child!,
            const Align(
              alignment: Alignment.bottomCenter,
              child: FocusModeOverlay(),
            ),
          ],
        );
      },
    );
  }
}

/// Entry gate that decides where to navigate based on session state:
///
///  - No session → [LoginScreen]
///  - Session valid + online → silent verify → [LibraryScreen] / [CourseSelectScreen]
///  - Session valid + offline + counter < 2 → [LibraryScreen] / [CourseSelectScreen]
///  - Session valid + offline + counter >= 2 → [ReVerifyScreen]
///  - Session blocked → [LoginScreen] with error message
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  final bool _checking = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _resolveSession();
  }

  Future<void> _resolveSession() async {
    // Verify with the server on every app open (was: local-only hasValidSession).
    // Fails open when offline (counter-gated re-verify), but fails CLOSED on a
    // definitive server verdict (blocked / expired / device-changed).
    final check = await SessionService.checkOnAppOpen();

    if (!mounted) return;

    switch (check.result) {
      case SessionResult.needsFullLogin:
        _navigateTo(const LoginScreen());
        break;
      case SessionResult.blocked:
        // Fail closed: clear the session and force a fresh login.
        AuthService.logout();
        _navigateTo(const LoginScreen());
        break;
      case SessionResult.needsReVerify:
        AuthService.restoreFromSession(check.storedCourses);
        _navigateTo(ReVerifyScreen(courses: check.storedCourses));
        break;
      case SessionResult.ok:
        AuthService.restoreFromSession(check.storedCourses);
        // Sync progress from server (non-blocking, offline-safe)
        ProgressService.syncToServer();
        _navigateTo(CourseSelectScreen(storedCourses: check.storedCourses));
        break;
    }
  }

  void _navigateTo(Widget screen) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => screen,
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // App logo
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.iconChipBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.06),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const LockMark(size: 44, color: Colors.white, weight: 7.0),
              ),
              const SizedBox(height: 24),
              const Text(
                'Lockclass',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 20),
              if (_checking)
                Column(
                  children: [
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      AmoL10n.of(context).coursesCheckingSession,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
