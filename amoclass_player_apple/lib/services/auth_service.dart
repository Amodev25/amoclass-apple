import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'session_service.dart';
import 'library_service.dart';
import '../core/decryption_service.dart';
import '../core/amo_native_bridge.dart';
import '../core/app_build.dart';
import '../core/app_update_gate.dart';
import '../core/device_identity.dart';
import '../core/platform_identity.dart';
import 'course_files_service.dart';

/// A course content key as the worker sends it: 32 bytes as 64 hex digits.
final RegExp kContentKeyPattern = RegExp(r'^[0-9a-fA-F]{64}$');

bool isValidContentKey(String? key) =>
    key != null && kContentKeyPattern.hasMatch(key);

const Object _unset = Object();

/// Represents one course session a student belongs to.
class CourseSession {
  final int studentId;
  final String studentName;
  final int teacherId;
  final String teacherName;
  final String courseName;
  final String? serverCode;

  /// The course's database id. Online downloads live under
  /// `AmoOnlineFiles/<courseId>/`, so two courses never share a folder.
  final int? courseId;

  /// The course content key (64 hex digits), computed by the worker. The
  /// teacher credential and course secret it is derived from never reach the
  /// app.
  final String? contentKey;

  /// The earliest end of access the server knows (ISO-8601), or null when
  /// access is unbounded. Enforced offline too.
  final String? accessEndsAt;

  final bool requireHeadphones;

  /// The student's seat number (`رقم الجلوس`) in THIS course — spec D7.
  ///
  /// Per enrolment, not per person: a student in two courses has two seat
  /// numbers, which is why it lives here and not beside the student's name.
  /// Null only for a session restored from a file written before T11, or a row
  /// that somehow predates the server-side allocator; the UI omits the line
  /// rather than showing a zero.
  final int? seatNo;

  /// Bearer token for every later call about THIS enrolment.
  ///
  /// One per course, not one per person: each enrolment is its own row on the
  /// server, and the token names exactly one of them.
  final String? sessionToken;

  /// The password this enrolment was last signed in or re-verified with,
  /// exactly as sent to the worker (trimmed). Drawn over lessons by
  /// `StudentWatermark` (owner decision 2026-09-14).
  ///
  /// Never read from a server response: [AuthService.requestLogin] attaches it
  /// after a successful login. Persisted only inside the keychain session
  /// entry; never logged or sent anywhere else. Null for a session stored
  /// before passwords were kept.
  final String? password;

  const CourseSession({
    required this.studentId,
    required this.studentName,
    required this.teacherId,
    required this.teacherName,
    required this.courseName,
    this.serverCode,
    this.courseId,
    this.contentKey,
    this.accessEndsAt,
    this.requireHeadphones = false,
    this.seatNo,
    this.sessionToken,
    this.password,
  });

  factory CourseSession.fromJson(Map<String, dynamic> j) => CourseSession(
    studentId: j['studentId'] as int,
    studentName: j['studentName'] as String,
    teacherId: j['teacherId'] as int,
    teacherName: j['teacherName'] as String,
    courseName: (j['courseName'] as String?) ?? (j['teacherName'] as String),
    serverCode: j['serverCode'] as String?,
    courseId: (j['courseId'] as num?)?.toInt(),
    contentKey: j['contentKey'] as String?,
    accessEndsAt: j['accessEndsAt'] as String?,
    requireHeadphones: j['requireHeadphones'] as bool? ?? false,
    seatNo: j['seatNo'] as int?,
    sessionToken: j['sessionToken'] as String?,
  );

  CourseSession copyWith({
    String? contentKey,
    Object? accessEndsAt = _unset,
    bool? requireHeadphones,
    int? seatNo,
    String? sessionToken,
    String? password,
  }) => CourseSession(
    studentId: studentId,
    studentName: studentName,
    teacherId: teacherId,
    teacherName: teacherName,
    courseName: courseName,
    serverCode: serverCode,
    courseId: courseId,
    contentKey: contentKey ?? this.contentKey,
    accessEndsAt: identical(accessEndsAt, _unset)
        ? this.accessEndsAt
        : accessEndsAt as String?,
    requireHeadphones: requireHeadphones ?? this.requireHeadphones,
    seatNo: seatNo ?? this.seatNo,
    sessionToken: sessionToken ?? this.sessionToken,
    // A token refresh passes no password, so the stored one is KEPT.
    password: password ?? this.password,
  );
}

/// Why a login attempt was refused.
///
/// Carries the localized message to show AND the server's machine code, because
/// the login screen has to react to one specific refusal — `INVALID_LOGIN`,
/// which is the only one that can mean "this student has not been converted to
/// password-only login yet". Matching on the message text instead would break
/// the moment the message is translated, which has already happened twice in
/// this codebase (see .wolf/cerebrum.md).
class LoginFailure {
  /// Ready to show to the student, already in their language.
  final String message;

  /// The worker's `code`, or null for a transport failure that never reached it.
  final String? code;

  const LoginFailure(this.message, [this.code]);
}

/// The outcome of one POST /auth/login: the courses, or why not.
class LoginAttempt {
  final List<CourseSession>? courses;
  final LoginFailure? failure;

  const LoginAttempt._(this.courses, this.failure);
  const LoginAttempt.succeeded(List<CourseSession> courses)
    : this._(courses, null);
  const LoginAttempt.failed(LoginFailure failure) : this._(null, failure);
}

/// Service to authenticate students against the AMO web server.
class AuthService {
  static const String baseUrl =
      'https://amo-student-worker.doctoramr0101.workers.dev';
  static const String workerUrl =
      'https://amo-student-worker.doctoramr0101.workers.dev';

  /// Session tokens by studentId — one per enrolment the app holds.
  ///
  /// Keyed by studentId rather than kept as a single field because
  /// `addCourseLogin` lets one installation hold several courses at once, and
  /// each one authenticates as itself.
  static final Map<int, String> _sessionTokens = {};

  static String? _loggedInStudentName;
  static int? _loggedInStudentId;
  static String? _activeSessionToken;
  static int? _activeCourseTeacherId;
  static int? _activeCourseId;
  static String? _loggedInServerCode;
  static String? _activeContentKey;
  static String? _activeAccessEndsAt;
  static bool _activeRequireHeadphones = false;
  static String? _activePassword;

  /// All courses returned after successful login.
  static List<CourseSession> _courses = [];

  static String? get loggedInStudentName => _loggedInStudentName;

  /// The active course's password, for the lesson watermark only. Null when
  /// signed out or for a session stored before passwords were kept.
  static String? get activePassword => _activePassword;
  static int? get loggedInStudentId => _loggedInStudentId;
  static int? get activeCourseTeacherId => _activeCourseTeacherId;
  static int? get activeCourseId => _activeCourseId;
  static String? get loggedInServerCode => _loggedInServerCode;
  static String? get activeContentKey => _activeContentKey;
  static String? get activeAccessEndsAt => _activeAccessEndsAt;
  static bool get activeRequireHeadphones => _activeRequireHeadphones;
  static bool get isLoggedIn => _loggedInStudentName != null;

  /// Token for the course currently in focus.
  static String? get activeSessionToken => _activeSessionToken;

  /// Token for one specific enrolment — used when verifying courses in a loop.
  static String? tokenFor(int studentId) => _sessionTokens[studentId];

  /// Authorization header for the active course, or empty when signed out.
  static Map<String, String> get authHeaders => _activeSessionToken == null
      ? const {}
      : {'Authorization': 'Bearer $_activeSessionToken'};

  /// Everything a request to the student worker carries: the build number
  /// (always) and the active course's bearer token (when signed in).
  static Map<String, String> get workerHeaders => {
    ...kAppBuildHeaders,
    ...authHeaders,
  };

  /// Record a token, and keep the active one in step when it is the same course.
  static void rememberToken(int studentId, String token) {
    _sessionTokens[studentId] = token;
    if (_loggedInStudentId == studentId) _activeSessionToken = token;
  }

  static List<CourseSession> get courses => List.unmodifiable(_courses);

  /// Apply what /auth/verify-session or a re-verify returned for [studentId].
  ///
  /// Updates the in-memory course, and the active fields only when [studentId]
  /// IS the active course — verifying course B in a loop must never replace
  /// course A's key. Returns whether it was the active course, so the caller
  /// knows to hand the new key to the native decryptor.
  static bool applyRefresh(
    int studentId, {
    String? contentKey,
    bool accessEndsAtKnown = false,
    String? accessEndsAt,
    bool? requireHeadphones,
    int? seatNo,
    String? sessionToken,
  }) {
    final index = _courses.indexWhere((c) => c.studentId == studentId);
    if (index >= 0) {
      _courses[index] = _courses[index].copyWith(
        contentKey: contentKey,
        accessEndsAt: accessEndsAtKnown ? accessEndsAt : _unset,
        requireHeadphones: requireHeadphones,
        seatNo: seatNo,
        sessionToken: sessionToken,
      );
    }
    if (sessionToken != null) rememberToken(studentId, sessionToken);
    if (_loggedInStudentId != studentId) return false;
    if (contentKey != null) _activeContentKey = contentKey;
    if (accessEndsAtKnown) _activeAccessEndsAt = accessEndsAt;
    if (requireHeadphones != null) _activeRequireHeadphones = requireHeadphones;
    return true;
  }

  // ── Login ──────────────────────────────────────────────────────────────────

  /// One POST /auth/login, shared by sign-in, add-course and re-verify.
  ///
  /// The password is trimmed here (the server trims too). Courses without a
  /// well-formed `contentKey` are dropped: nothing in this build can play them.
  static Future<LoginAttempt> requestLogin(
    String serverCode,
    String password, {
    String? name,
    bool reVerify = false,
  }) async {
    final strings = LocaleService.instance.strings;
    final client = HttpClient();
    try {
      final deviceId = await DeviceIdentity.get();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.postUrl(Uri.parse('$workerUrl/auth/login'));
      request.headers.set('Content-Type', 'application/json');
      request.headers.set(kAppBuildHeader, '$kAppBuild');
      request.write(
        jsonEncode({
          'serverCode': serverCode.trim(),
          'password': password.trim(),
          'platform': PlatformIdentity.current,
          'deviceId': deviceId,
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        }),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      Map<String, dynamic> data = const {};
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}

      if (AppUpdateGate.isUpdateRequired(response.statusCode, data)) {
        AppUpdateGate.report();
        return LoginAttempt.failed(
          LoginFailure(strings.srvAppUpdateRequired, 'APP_UPDATE_REQUIRED'),
        );
      }

      if (response.statusCode == 200 && data['success'] == true) {
        final courses = <CourseSession>[];
        final raw = data['courses'];
        if (raw is List) {
          for (final entry in raw) {
            if (entry is! Map<String, dynamic>) continue;
            try {
              // The exact trimmed value sent above, kept for the watermark.
              // The server never echoes it back, so it is attached here — the
              // one place every login, add-course and re-verify passes through.
              final course = CourseSession.fromJson(
                entry,
              ).copyWith(password: password.trim());
              if (isValidContentKey(course.contentKey)) courses.add(course);
            } catch (_) {}
          }
        }
        if (courses.isEmpty) {
          return LoginAttempt.failed(
            LoginFailure(strings.srvInvalidRequest, 'INVALID_REQUEST'),
          );
        }
        return LoginAttempt.succeeded(courses);
      }

      if (data.isEmpty) {
        return LoginAttempt.failed(
          LoginFailure(strings.errServerStatus(response.statusCode)),
        );
      }
      final code = data['code'];
      return LoginAttempt.failed(
        LoginFailure(
          localizeServerError(strings, data),
          code is String ? code : null,
        ),
      );
    } on SocketException {
      return LoginAttempt.failed(
        LoginFailure(
          reVerify ? strings.errCannotConnectDialog : strings.errCannotConnect,
        ),
      );
    } on TimeoutException {
      return LoginAttempt.failed(
        LoginFailure(
          reVerify ? strings.errCannotConnectDialog : strings.errCannotConnect,
        ),
      );
    } on HttpException {
      return LoginAttempt.failed(LoginFailure(strings.errServerRetry));
    } catch (e) {
      return LoginAttempt.failed(
        LoginFailure(strings.errConnectionFailed('$e')),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Verify student credentials using server code + password.
  ///
  /// `name` is NOT part of the credential (spec D1) — the course code and the
  /// password are. It is accepted only for the one case the server cannot
  /// resolve without it: a student enrolled before migration 0022 whose
  /// `password_lookup` has not been backfilled yet. The login screen sends it
  /// on a retry, never on the first attempt.
  ///
  /// Returns null on success, or a [LoginFailure] describing the refusal.
  static Future<LoginFailure?> login(
    String serverCode,
    String password, {
    String? name,
  }) async {
    final code = serverCode.trim();
    final attempt = await requestLogin(code, password, name: name);
    final courses = attempt.courses;
    if (courses == null) return attempt.failure;

    _loggedInServerCode = code;
    _courses = courses;
    // Activate first course by default
    _setActiveCourse(_courses.first);
    // Create signed session file for offline tracking (all courses)
    await SessionService.createSession(_courses, code);
    await CourseFilesService.rememberLoginCode(
      code,
      _courses.map((c) => c.serverCode ?? code),
    );
    return null;
  }

  /// Login to add a NEW course from a different server code.
  /// Merges the new courses into the existing in-memory list and session file.
  /// Returns null on success, or a [LoginFailure] describing the refusal.
  /// `name` carries the same meaning as in [login].
  static Future<LoginFailure?> addCourseLogin(
    String serverCode,
    String password, {
    String? name,
  }) async {
    final code = serverCode.trim();
    final attempt = await requestLogin(code, password, name: name);
    final newCourses = attempt.courses;
    if (newCourses == null) return attempt.failure;

    // Merge new courses into existing list (a re-added course replaces the
    // old entry, so its fresh key and token win).
    for (final c in newCourses) {
      final index = _courses.indexWhere((e) => e.studentId == c.studentId);
      if (index >= 0) {
        _courses[index] = c;
      } else {
        _courses.add(c);
      }
    }

    await SessionService.addCoursesToSession(newCourses, code);
    await CourseFilesService.rememberLoginCode(
      code,
      newCourses.map((c) => c.serverCode ?? code),
    );
    return null;
  }

  // ── Session restoration ───────────────────────────────────────────────────

  /// Restore auth state from stored session data (no server call).
  /// Called by SplashGate when a valid session exists.
  static void restoreFromSession(List<StoredCourse> storedCourses) {
    _courses = storedCourses
        .map(
          (sc) => CourseSession(
            studentId: sc.studentId,
            studentName: sc.studentName,
            teacherId: sc.teacherId,
            teacherName: sc.teacherName,
            courseName: sc.courseName,
            serverCode: sc.serverCode,
            courseId: sc.courseId,
            contentKey: sc.contentKey,
            accessEndsAt: sc.accessEndsAt,
            requireHeadphones: sc.requireHeadphones,
            seatNo: sc.seatNo,
            sessionToken: sc.sessionToken,
            password: sc.password,
          ),
        )
        .toList();
    for (final sc in storedCourses) {
      if (sc.sessionToken != null) {
        _sessionTokens[sc.studentId] = sc.sessionToken!;
      }
    }
    if (_courses.isNotEmpty) {
      _setActiveCourse(_courses.first);
      _loggedInServerCode = storedCourses.first.serverCode;
    }
  }

  // ── Course switching ───────────────────────────────────────────────────────

  /// Switch the active course (after login with multiple courses).
  static void switchCourse(CourseSession course) => _setActiveCourse(course);

  static void _setActiveCourse(CourseSession course) {
    _loggedInStudentName = course.studentName;
    _activePassword = course.password;
    _loggedInStudentId = course.studentId;
    // Prefer the token already in the map: /auth/verify-session refreshes it,
    // and the CourseSession object may be the older one from login.
    if (course.sessionToken != null) {
      _sessionTokens[course.studentId] = course.sessionToken!;
    }
    _activeSessionToken = _sessionTokens[course.studentId];
    _activeCourseTeacherId = course.teacherId;
    _activeCourseId = course.courseId;
    // ── Security: update server code + key fields on EVERY switch
    _loggedInServerCode = course.serverCode ?? _loggedInServerCode;
    _activeContentKey = course.contentKey;
    _activeAccessEndsAt = course.accessEndsAt;
    _activeRequireHeadphones = course.requireHeadphones;
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  static void logout() {
    _sessionTokens.clear();
    _activeSessionToken = null;
    _loggedInStudentName = null;
    _activePassword = null;
    _loggedInStudentId = null;
    _activeCourseTeacherId = null;
    _activeCourseId = null;
    _loggedInServerCode = null;
    _activeContentKey = null;
    _activeAccessEndsAt = null;
    _activeRequireHeadphones = false;
    _courses = [];
    // Clear the content key from native process memory
    AmoNativeBridge.clearContentKey();
    SessionService.clearSession();
    // Clear library to prevent cross-course data leakage
    LibraryService.clearCache();
    // Previews are stored as plain images, so they leave with the session.
    LibraryService.purgeThumbnails();
    // Clean up any decrypted temp files
    DecryptionService.cleanupTempFiles();
  }
}
