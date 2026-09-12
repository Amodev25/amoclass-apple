import '../l10n/gen/amo_localizations.dart';

/// Turns a student-worker refusal into a localized message.
///
/// The worker returns `{success: false, error: "<English>", code: "<CODE>"}`
/// (see `web/amo-student-worker/src/errors.ts`). Before this existed the players
/// rendered `error` verbatim, which is why an Arabic student saw English at the
/// exact moment they most needed to understand what went wrong.
///
/// `code` is the contract; `error` is the fallback. A worker deployed ahead of
/// the app can add a code this build has never heard of, and an old worker may
/// send no code at all — both cases fall through to the server's own English
/// text rather than to a blank dialog. That is the whole reason the worker still
/// sends `error`, and why it must keep doing so.
String localizeServerError(AmoL10n l10n, Map<String, dynamic> data) {
  final code = data['code'];
  switch (code) {
    case 'COURSE_UNAVAILABLE':
      return l10n.srvCourseUnavailable;
    case 'COURSE_EXPIRED':
      return l10n.srvCourseExpired;
    case 'COURSE_INACTIVE':
      return l10n.srvCourseInactive;
    case 'COURSE_EXPIRED_MIDSESSION':
      return l10n.srvCourseExpiredMidsession;
    case 'ENROLLMENT_EXPIRED_MIDSESSION':
      return l10n.srvEnrollmentExpiredMidsession;
    case 'SEATS_LAPSED':
      return l10n.srvSeatsLapsed;
    case 'STORAGE_LAPSED':
      return l10n.srvStorageLapsed;
    case 'STUDENT_SUSPENDED':
      return l10n.srvStudentSuspended;
    case 'STUDENT_NOT_FOUND':
      return l10n.srvStudentNotFound;
    case 'ENROLLMENT_EXPIRED':
      return l10n.srvEnrollmentExpired;
    case 'ENROLLMENT_SUSPENDED':
      return l10n.srvEnrollmentSuspended;
    case 'DEVICE_MISMATCH':
      return l10n.srvDeviceMismatch;
    case 'PLATFORM_MISMATCH':
      return l10n.srvPlatformMismatch(_platformName(data['platform']));
    case 'INVALID_LOGIN':
      return l10n.srvInvalidLogin;
    case 'MISSING_CREDENTIALS':
      return l10n.srvMissingCredentials;
    case 'RATE_LIMITED':
      return l10n.srvRateLimited;
    case 'RATE_LIMITED_COURSE':
      return l10n.srvRateLimitedCourse;
    case 'SESSION_INVALID':
      return l10n.srvSessionInvalid;
    case 'ACCESS_DENIED':
      return l10n.srvAccessDenied;
    case 'STORAGE_UNCONFIGURED':
      return l10n.srvStorageUnconfigured;
    case 'NOT_FOUND':
      return l10n.srvNotFound;
    case 'SERVER_ERROR':
      return l10n.srvServerError;
  }
  final fallback = data['error'];
  if (fallback is String && fallback.isNotEmpty) return fallback;
  return l10n.srvInvalidLogin;
}

/// The platform names stay in Latin script in both languages — they are the
/// OS's own brand names, and a student comparing them against a store listing
/// or a teacher's instructions needs to see the same word.
String _platformName(Object? platform) {
  switch (platform) {
    case 'windows':
      return 'Windows';
    case 'android':
      return 'Android';
    default:
      return platform?.toString() ?? '';
  }
}
