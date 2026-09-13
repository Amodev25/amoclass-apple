import 'package:amo_core/amo_core.dart';
import 'package:flutter/material.dart';

/// The blocking "update required" dialog.
///
/// The worker answers every route with HTTP 426 `APP_UPDATE_REQUIRED` when
/// this build is older than its `MIN_APP_BUILD`. That can surface from a
/// service with no BuildContext (a background verify, a progress sync), so
/// the dialog is shown through the app's root navigator key.
///
/// It cannot be dismissed: nothing this build does can succeed against a
/// server that refuses it.
class AppUpdateGate {
  const AppUpdateGate._();

  /// Installed on the MaterialApp in main.dart.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static bool _shown = false;
  static bool _scheduled = false;

  /// True once the server has refused this build. Session logic uses it to
  /// stop navigating underneath the dialog.
  static bool get isBlocked => _shown || _scheduled;

  /// Whether a worker response means "this build is too old".
  static bool isUpdateRequired(int? statusCode, Object? body) =>
      statusCode == 426 ||
      (body is Map && body['code'] == 'APP_UPDATE_REQUIRED');

  /// Shows the dialog once. Safe to call from anywhere, any number of times.
  static void report() {
    if (_shown) return;
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      if (_scheduled) return;
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        report();
      });
      return;
    }
    _shown = true;
    showDialog<void>(
      context: navigator.context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.border),
          ),
          icon: const Icon(
            Icons.system_update,
            color: Colors.white,
            size: 48,
          ),
          content: Text(
            AmoL10n.of(ctx).srvAppUpdateRequired,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
