import 'package:amo_core/amo_core.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'session_service.dart';
import 'library_service.dart';
import '../core/decryption_service.dart';
import '../core/amo_native_bridge.dart';
import '../core/platform_identity.dart';

/// Represents one course session a student belongs to.
class CourseSession {
  final int studentId;
  final String studentName;
  final int teacherId;
  final String teacherName;
  final String courseName;
  final String? serverCode;
  final String? credential;
  final String? courseSecret;
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
  /// server, and the token names exactly one of them. Null only for a session
  /// restored from a file written before tokens existed, which the server will
  /// reject — forcing a fresh sign-in, which is the correct outcome.
  final String? sessionToken;

  const CourseSession({
    required this.studentId,
    required this.studentName,
    required this.teacherId,
    required this.teacherName,
    required this.courseName,
    this.serverCode,
    this.credential,
    this.courseSecret,
    this.requireHeadphones = false,
    this.seatNo,
    this.sessionToken,
  });

  factory CourseSession.fromJson(Map<String, dynamic> j) => CourseSession(
    studentId: j['studentId'] as int,
    studentName: j['studentName'] as String,
    teacherId: j['teacherId'] as int,
    teacherName: j['teacherName'] as String,
    courseName: (j['courseName'] as String?) ?? (j['teacherName'] as String),
    serverCode: j['serverCode'] as String?,
    credential: j['credential'] as String?,
    courseSecret: j['courseSecret'] as String?,
    requireHeadphones: j['requireHeadphones'] as bool? ?? false,
    seatNo: j['seatNo'] as int?,
    sessionToken: j['sessionToken'] as String?,
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

/// Service to authenticate students against the AMO web server.
class AuthService {
  static const String baseUrl =
      'https://amo-student-worker.doctoramr0101.workers.dev';
  static const String workerUrl =
      'https://amo-student-worker.doctoramr0101.workers.dev';
  static const _channel = MethodChannel('com.amoplayer/anti_capture');

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
  static String? _loggedInServerCode;
  static String? _activeCredential;
  static String? _activeCourseSecret;
  static bool _activeRequireHeadphones = false;

  /// All courses returned after successful login.
  static List<CourseSession> _courses = [];

  static String? get loggedInStudentName => _loggedInStudentName;
  static int? get loggedInStudentId => _loggedInStudentId;
  static int? get activeCourseTeacherId => _activeCourseTeacherId;
  static String? get loggedInServerCode => _loggedInServerCode;
  static String? get activeCredential => _activeCredential;
  static String? get activeCourseSecret => _activeCourseSecret;
  static bool get activeRequireHeadphones => _activeRequireHeadphones;
  static bool get isLoggedIn => _loggedInStudentName != null;

  /// Token for the course currently in focus.
  static String? get activeSessionToken => _activeSessionToken;

  /// Token for one specific enrolment — used when verifying courses in a loop.
  static String? tokenFor(int studentId) => _sessionTokens[studentId];

  /// Authorization header for the active course, or empty when signed out.
  /// Empty rather than absent so callers can spread it unconditionally; the
  /// server answers 401 either way.
  static Map<String, String> get authHeaders => _activeSessionToken == null
      ? const {}
      : {'Authorization': 'Bearer $_activeSessionToken'};

  /// Record a token, and keep the active one in step when it is the same course.
  static void rememberToken(int studentId, String token) {
    _sessionTokens[studentId] = token;
    if (_loggedInStudentId == studentId) _activeSessionToken = token;
  }
  static List<CourseSession> get courses => List.unmodifiable(_courses);

  /// Update credential and courseSecret from verify-session response.
  static void updateCredentials(
    String? credential,
    String? courseSecret, {
    bool? requireHeadphones,
  }) {
    if (credential != null) _activeCredential = credential;
    if (courseSecret != null) _activeCourseSecret = courseSecret;
    if (requireHeadphones != null) _activeRequireHeadphones = requireHeadphones;
  }

  /// Get unique device ID from native Android
  static Future<String> _getDeviceId() async {
    try {
      final id = await _channel.invokeMethod<String>('getDeviceId');
      return id ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  // ── Login ──────────────────────────────────────────────────────────────────

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
    final client = HttpClient();
    try {
      final deviceId = await _getDeviceId();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.postUrl(Uri.parse('$workerUrl/auth/login'));
      request.headers.set('Content-Type', 'application/json');
      request.write(
        jsonEncode({
          'serverCode': serverCode.trim(),
          'password': password,
          'platform': PlatformIdentity.current,
          'deviceId': deviceId,
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        }),
      );

      // Remember the server code for later verification
      _loggedInServerCode = serverCode.trim();

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['success'] == true) {
        // Parse courses list (new API) – fall back to legacy single-student
        final rawCourses = data['courses'] as List<dynamic>?;
        if (rawCourses != null && rawCourses.isNotEmpty) {
          _courses = rawCourses
              .map((c) => CourseSession.fromJson(c as Map<String, dynamic>))
              .toList();
        } else {
          // Backward-compat: server returned old format
          final s = data['student'] as Map<String, dynamic>;
          _courses = [
            CourseSession(
              studentId: s['id'] as int,
              studentName: s['name'] as String,
              teacherId: 0,
              teacherName: 'Course',
              courseName: 'Course',
            ),
          ];
        }
        // Activate first course by default
        _setActiveCourse(_courses.first);
        // Create signed session file for offline tracking (new format — all courses)
        await SessionService.createSession(_courses, serverCode.trim());
        return null; // success
      } else {
        return LoginFailure(
          localizeServerError(LocaleService.instance.strings, data),
          data['code'] as String?,
        );
      }
    } on SocketException {
      return LoginFailure(LocaleService.instance.strings.errCannotConnect);
    } on HttpException {
      return LoginFailure(LocaleService.instance.strings.errServerRetry);
    } catch (e) {
      return LoginFailure(LocaleService.instance.strings.errConnectionFailed('$e'));
    } finally {
      client.close(force: true);
    }
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
    final client = HttpClient();
    try {
      final deviceId = await _getDeviceId();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.postUrl(Uri.parse('$workerUrl/auth/login'));
      request.headers.set('Content-Type', 'application/json');
      request.write(
        jsonEncode({
          'serverCode': serverCode.trim(),
          'password': password,
          'platform': PlatformIdentity.current,
          'deviceId': deviceId,
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        }),
      );

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['success'] == true) {
        List<CourseSession> newCourses;
        final rawCourses = data['courses'] as List<dynamic>?;
        if (rawCourses != null && rawCourses.isNotEmpty) {
          newCourses = rawCourses
              .map((c) => CourseSession.fromJson(c as Map<String, dynamic>))
              .toList();
        } else {
          final s = data['student'] as Map<String, dynamic>;
          newCourses = [
            CourseSession(
              studentId: s['id'] as int,
              studentName: s['name'] as String,
              teacherId: 0,
              teacherName: 'Course',
              courseName: 'Course',
            ),
          ];
        }

        // Merge new courses into existing list (avoid duplicates by studentId)
        final existingIds = _courses.map((c) => c.studentId).toSet();
        for (final c in newCourses) {
          if (!existingIds.contains(c.studentId)) {
            _courses.add(c);
            existingIds.add(c.studentId);
          }
        }

        // Merge into session file
        await SessionService.addCoursesToSession(newCourses, serverCode.trim());
        return null; // success
      } else {
        return LoginFailure(
          localizeServerError(LocaleService.instance.strings, data),
          data['code'] as String?,
        );
      }
    } on SocketException {
      return LoginFailure(LocaleService.instance.strings.errCannotConnect);
    } on HttpException {
      return LoginFailure(LocaleService.instance.strings.errServerRetry);
    } catch (e) {
      return LoginFailure(LocaleService.instance.strings.errConnectionFailed('$e'));
    } finally {
      client.close(force: true);
    }
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
            credential: sc.credential,
            courseSecret: sc.courseSecret,
            requireHeadphones: sc.requireHeadphones,
            sessionToken: sc.sessionToken,
          ),
        )
        .toList();
    for (final sc in storedCourses) {
      if (sc.sessionToken != null) _sessionTokens[sc.studentId] = sc.sessionToken!;
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
    _loggedInStudentId = course.studentId;
    // Prefer the token already in the map: /auth/verify-session refreshes it,
    // and the CourseSession object may be the older one from login.
    if (course.sessionToken != null) {
      _sessionTokens[course.studentId] = course.sessionToken!;
    }
    _activeSessionToken = _sessionTokens[course.studentId];
    _activeCourseTeacherId = course.teacherId;
    // ── Security: update server code + derived-key fields on EVERY switch
    _loggedInServerCode = course.serverCode ?? _loggedInServerCode;
    _activeCredential = course.credential;
    _activeCourseSecret = course.courseSecret;
    _activeRequireHeadphones = course.requireHeadphones;
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  static void logout() {
    _sessionTokens.clear();
    _activeSessionToken = null;
    _loggedInStudentName = null;
    _loggedInStudentId = null;
    _activeCourseTeacherId = null;
    _loggedInServerCode = null;
    _activeCredential = null;
    _activeCourseSecret = null;
    _activeRequireHeadphones = false;
    _courses = [];
    // Clear native credentials from process memory
    AmoNativeBridge.clearCredentials();
    SessionService.clearSession();
    // Clear library to prevent cross-course data leakage
    LibraryService.clearCache();
    // Clean up any decrypted temp files
    DecryptionService.cleanupTempFiles();
  }
}
