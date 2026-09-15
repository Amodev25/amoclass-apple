import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'course_files_service.dart';
import 'auth_service.dart';
import '../screens/login_screen.dart';
import '../screens/re_verify_screen.dart';
import '../core/amo_native_bridge.dart';
import '../core/app_build.dart';
import '../core/app_secure_storage.dart';
import '../core/app_update_gate.dart';
import '../core/device_identity.dart';
import '../core/platform_identity.dart';
import '../widgets/course_files_prompt.dart';

/// Result of a session check.
enum SessionResult {
  /// Session is valid — proceed to library.
  ok,

  /// Offline limit reached, the server no longer accepts this session's
  /// token (401 / SESSION_INVALID), access has ended on the device clock, or
  /// the clock was turned back — show the password-only re-verify screen.
  needsReVerify,

  /// No session file — show full login screen.
  needsFullLogin,

  /// Account removed / device changed / platform changed — blocked.
  blocked,

  /// The worker refused this build (HTTP 426 / APP_UPDATE_REQUIRED). The
  /// blocking dialog is already up ([AppUpdateGate]); callers do nothing else.
  updateRequired,
}

/// Holds the outcome of [SessionService.checkOnAppOpen] including
/// any stored course data needed by the re-verify screen.
class SessionCheckResult {
  final SessionResult result;
  final String? blockedReason;

  /// The course [blockedReason] is about. A student can hold several courses
  /// and the check walks all of them, so it is not always the one open.
  final String? blockedServerCode;
  final List<StoredCourse> storedCourses;

  /// Why re-verification is needed, already localized — shown on the
  /// re-verify screen (`offlineTooLong`, `clockChanged`, …). Null when the
  /// screen's own title says enough.
  final String? notice;

  const SessionCheckResult({
    required this.result,
    this.blockedReason,
    this.blockedServerCode,
    this.storedCourses = const [],
    this.notice,
  });
}

/// A course persisted inside the session file.
class StoredCourse {
  final int studentId;
  final String studentName;
  final int teacherId;
  final String teacherName;
  final String courseName;
  final String serverCode;

  /// The course's database id; names the course's download folder.
  int? courseId;

  /// The course content key (64 hex digits). Refreshed by every successful
  /// verification. A course without one cannot be played and is discarded
  /// when the session is read (contract §3.1).
  String? contentKey;

  /// The earliest end of access the server knows (ISO-8601), or null.
  String? accessEndsAt;

  bool requireHeadphones;

  /// The student's seat number (`رقم الجلوس`) in THIS course — spec D7.
  ///
  /// Per enrolment, not per person: a student in two courses has two seat
  /// numbers, which is why it lives here and not beside the student's name.
  /// Null only for a session restored from a file written before T11, or a row
  /// that somehow predates the server-side allocator; the UI omits the line
  /// rather than showing a zero.
  ///
  /// Mutable, like `contentKey`: /auth/verify-session returns it on every
  /// check-in, so a seat the teacher corrected reaches the student without a
  /// re-login.
  int? seatNo;

  /// Bearer token for this enrolment. Refreshed by /auth/verify-session, so it
  /// is persisted here rather than held only in memory — otherwise every app
  /// restart would need a password.
  String? sessionToken;

  /// The password this enrolment was last signed in or re-verified with
  /// (trimmed, exactly as sent), drawn over lessons by `StudentWatermark`.
  ///
  /// Lives ONLY in this keychain session entry. Set by a login and replaced by
  /// a re-verify; a verify-session refresh never touches it, and because the
  /// refresh mutates this object in place the caller's later write keeps it.
  /// Null for a session written before passwords were kept.
  String? password;
  int offlineCounter;
  String lastVerified;

  StoredCourse({
    required this.studentId,
    required this.studentName,
    required this.teacherId,
    required this.teacherName,
    required this.courseName,
    required this.serverCode,
    this.courseId,
    this.contentKey,
    this.accessEndsAt,
    this.requireHeadphones = false,
    this.seatNo,
    this.sessionToken,
    this.password,
    this.offlineCounter = 0,
    String? lastVerified,
  }) : lastVerified = lastVerified ?? DateTime.now().toIso8601String();

  factory StoredCourse.fromSession(CourseSession c, String fallbackCode) =>
      StoredCourse(
        studentId: c.studentId,
        studentName: c.studentName,
        teacherId: c.teacherId,
        teacherName: c.teacherName,
        courseName: c.courseName,
        serverCode: c.serverCode ?? fallbackCode,
        courseId: c.courseId,
        contentKey: c.contentKey,
        accessEndsAt: c.accessEndsAt,
        requireHeadphones: c.requireHeadphones,
        seatNo: c.seatNo,
        sessionToken: c.sessionToken,
        password: c.password,
      );

  Map<String, dynamic> toJson() => {
    'studentId': studentId,
    'studentName': studentName,
    'teacherId': teacherId,
    'teacherName': teacherName,
    'courseName': courseName,
    'serverCode': serverCode,
    'courseId': courseId,
    'contentKey': contentKey,
    'accessEndsAt': accessEndsAt,
    'requireHeadphones': requireHeadphones,
    'seatNo': seatNo,
    'sessionToken': sessionToken,
    'password': password,
    'offlineCounter': offlineCounter,
    'lastVerified': lastVerified,
  };

  factory StoredCourse.fromJson(Map<String, dynamic> j) => StoredCourse(
    studentId: j['studentId'] as int,
    studentName: j['studentName'] as String,
    teacherId: j['teacherId'] as int,
    teacherName: j['teacherName'] as String,
    courseName: (j['courseName'] as String?) ?? (j['teacherName'] as String),
    serverCode: j['serverCode'] as String,
    courseId: (j['courseId'] as num?)?.toInt(),
    contentKey: j['contentKey'] as String?,
    accessEndsAt: j['accessEndsAt'] as String?,
    requireHeadphones: (j['requireHeadphones'] as bool?) ?? false,
    seatNo: j['seatNo'] as int?,
    sessionToken: j['sessionToken'] as String?,
    // Absent in a session written before passwords were kept: null.
    password: j['password'] as String?,
    offlineCounter: (j['offlineCounter'] as int?) ?? 0,
    lastVerified: j['lastVerified'] as String?,
  );
}

enum _VerdictKind { valid, offline, reauth, updateRequired, blocked }

/// What one /auth/verify-session round-trip established.
class _Verdict {
  final _VerdictKind kind;
  final String? reason;

  const _Verdict(this.kind, [this.reason]);

  static const valid = _Verdict(_VerdictKind.valid);
  static const offline = _Verdict(_VerdictKind.offline);
  static const reauth = _Verdict(_VerdictKind.reauth);
  static const updateRequired = _Verdict(_VerdictKind.updateRequired);
}

/// Manages the signed session file, offline counters, and session verification.
/// Uses HMAC-signed JSON to prevent tampering.
class SessionService {
  static const _fileName = '.amo_session'; // legacy plaintext (migrated away)

  /// Keychain-backed secure storage for the session blob and signing secret,
  /// this-device-only (see [AppSecureStorage]).
  static const _storage = AppSecureStorage.instance;
  static const _kSession = 'amo_session_json';
  static const _kAppSecret = 'amo_app_secret';

  /// Session-level keys: the latest wall-clock time ever observed, and whether
  /// a clock rollback was detected and not yet cleared by an online verify.
  static const _kLastSeenAt = 'lastSeenAt';
  static const _kClockRollback = 'clockRollback';

  /// How far the clock may go backwards (NTP corrections, travel) before it
  /// counts as turned back.
  static const Duration clockTolerance = Duration(minutes: 10);

  static String? _appSecret;

  /// Generate and persist a per-installation random secret (in the Keychain).
  static Future<void> _ensureAppSecret() async {
    if (_appSecret != null) return;
    final stored = await _storage.read(key: _kAppSecret);
    if (stored != null) {
      _appSecret = stored;
      return;
    }
    // Migrate a legacy plaintext app key if present (preserves existing session
    // signatures), otherwise generate a fresh secret.
    try {
      final dir = await getApplicationSupportDirectory();
      final legacy = File('${dir.path}/amo_app_key');
      if (await legacy.exists()) {
        _appSecret = await legacy.readAsString();
        try {
          await legacy.delete();
        } catch (_) {}
      }
    } catch (_) {}
    _appSecret ??= List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _storage.write(key: _kAppSecret, value: _appSecret);
  }

  /// Maximum offline opens before requiring re-verification. Owner decision
  /// 2026-09-13: the offline limit is this counter, not a number of days. It
  /// is reset only by a successful online verification.
  static const int maxOfflineOpens = 3;

  // Cache: skip verify-session if last check was recent
  static DateTime? _lastVerifyTime;
  static bool? _lastVerifyResult;

  // ══════════════════════════════════════════════════════════════════════════
  // SIGNING
  // ══════════════════════════════════════════════════════════════════════════

  /// Generate HMAC signature for tamper detection. Covers the clock fields
  /// too, so `lastSeenAt` cannot be edited back to defeat the rollback check.
  static Future<String> _sign(Map<String, dynamic> data) async {
    await _ensureAppSecret();
    final payload = jsonEncode({
      'courses': data['courses'],
      'deviceId': data['deviceId'],
      _kLastSeenAt: data[_kLastSeenAt],
      _kClockRollback: data[_kClockRollback],
    });
    final deviceId = (data['deviceId'] ?? '') as String;
    final key = utf8.encode(_appSecret! + deviceId);
    final bytes = utf8.encode(payload);
    final hmacSha256 = Hmac(sha256, key);
    return hmacSha256.convert(bytes).toString();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FILE I/O
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>?> _readSession() async {
    try {
      String? content = await _storage.read(key: _kSession);

      // One-time migration of any legacy plaintext session file.
      if (content == null) {
        final dir = await getApplicationSupportDirectory();
        final legacy = File('${dir.path}/$_fileName');
        if (await legacy.exists()) {
          content = await legacy.readAsString();
          await _storage.write(key: _kSession, value: content);
          try {
            await legacy.delete();
          } catch (_) {}
        }
      }
      if (content == null) return null;

      final data = jsonDecode(content) as Map<String, dynamic>;
      if (data['deviceId'] is! String) {
        await _storage.delete(key: _kSession);
        return null;
      }

      // Verify signature
      final expectedSig = await _sign(data);
      if (data['signature'] != expectedSig) {
        await _storage.delete(key: _kSession);
        return null;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeSession(Map<String, dynamic> data) async {
    data['signature'] = await _sign(data);
    await _storage.write(key: _kSession, value: jsonEncode(data));
  }

  static Map<String, dynamic> _newSession(
    List<StoredCourse> courses,
    String deviceId,
  ) => <String, dynamic>{
    'courses': courses.map((c) => c.toJson()).toList(),
    'deviceId': deviceId,
    'appOpenedAt': DateTime.now().toIso8601String(),
    _kLastSeenAt: DateTime.now().toUtc().toIso8601String(),
    _kClockRollback: false,
  };

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Create / Clear
  // ══════════════════════════════════════════════════════════════════════════

  /// Create session file after a successful full login.
  static Future<void> createSession(
    List<CourseSession> courses,
    String serverCode,
  ) async {
    final deviceId = await DeviceIdentity.get();
    final stored = courses
        .map((c) => StoredCourse.fromSession(c, serverCode))
        .toList();
    await _writeSession(_newSession(stored, deviceId));
    _markVerified();
  }

  /// Add new courses to the existing session file (merge).
  /// If a course with the same studentId already exists, it is updated.
  /// Otherwise the new course is appended.
  static Future<void> addCoursesToSession(
    List<CourseSession> newCourses,
    String serverCode,
  ) async {
    final deviceId = await DeviceIdentity.get();
    final session = await _readSession();

    final newStored = newCourses
        .map((c) => StoredCourse.fromSession(c, serverCode))
        .toList();

    if (session == null) {
      await _writeSession(_newSession(newStored, deviceId));
      _markVerified();
      return;
    }

    // Merge: existing courses + new courses (update duplicates by studentId)
    final existing = _parseCourses(session);
    final mergedMap = <int, StoredCourse>{};
    for (final c in existing) {
      mergedMap[c.studentId] = c;
    }
    for (final c in newStored) {
      mergedMap[c.studentId] = c;
    }

    session['courses'] = mergedMap.values.map((c) => c.toJson()).toList();
    session['appOpenedAt'] = DateTime.now().toIso8601String();
    _clockVerifiedOnline(session);
    await _writeSession(session);
    _markVerified();
  }

  /// Delete session file (on logout or tamper detection).
  static Future<void> clearSession() async {
    try {
      await _storage.delete(key: _kSession);
    } catch (_) {}
    // Remove any lingering legacy plaintext copies.
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in [_fileName, 'amo_app_key']) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    // Rotate the signing secret so a captured session copy can't be re-validated.
    try {
      await _storage.delete(key: _kAppSecret);
    } catch (_) {}
    _appSecret = null;
    _lastVerifyTime = null;
    _lastVerifyResult = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Stored course access
  // ══════════════════════════════════════════════════════════════════════════

  /// Check if a valid (non-tampered) session file exists — no verification,
  /// no counter increment. Returns the stored courses or empty list.
  static Future<List<StoredCourse>> hasValidSession() async {
    final session = await _readSession();
    if (session == null) return [];
    return _parseCourses(session);
  }

  /// Get all courses stored in the session file.
  static Future<List<StoredCourse>> getStoredCourses() async {
    final session = await _readSession();
    if (session == null) return [];
    return _parseCourses(session);
  }

  /// The stored courses that can still be played. A course written before the
  /// content-key change (no `contentKey`, or a malformed one) is dropped: the
  /// student signs in again for it (contract §3.1).
  static List<StoredCourse> _parseCourses(Map<String, dynamic> session) {
    final raw = session['courses'] as List<dynamic>?;
    if (raw == null || raw.isEmpty) return [];
    final courses = <StoredCourse>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        final course = StoredCourse.fromJson(entry);
        if (isValidContentKey(course.contentKey)) courses.add(course);
      } catch (_) {}
    }
    return courses;
  }

  static void _markVerified() {
    _lastVerifyTime = DateTime.now();
    _lastVerifyResult = true;
  }

  static void _invalidateVerifyCache() {
    _lastVerifyTime = null;
    _lastVerifyResult = false;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // OFFLINE POLICY (contract §3.6)
  // ══════════════════════════════════════════════════════════════════════════

  /// Records the wall clock and reports whether it was turned back.
  ///
  /// `lastSeenAt` only ever moves forward. Once `now` is more than
  /// [clockTolerance] behind it, the session is flagged and stays flagged
  /// until an online verification succeeds — setting the clock forward again
  /// does not clear it.
  static bool _observeClock(Map<String, dynamic> session) {
    final now = DateTime.now().toUtc();
    final lastSeen = DateTime.tryParse(
      (session[_kLastSeenAt] as String?) ?? '',
    )?.toUtc();
    var rolledBack = session[_kClockRollback] == true;
    if (lastSeen != null && now.isBefore(lastSeen.subtract(clockTolerance))) {
      rolledBack = true;
    }
    session[_kClockRollback] = rolledBack;
    if (lastSeen == null || now.isAfter(lastSeen)) {
      session[_kLastSeenAt] = now.toIso8601String();
    }
    return rolledBack;
  }

  /// The server has just vouched for this session: trust the current clock.
  static void _clockVerifiedOnline(Map<String, dynamic> session) {
    session[_kLastSeenAt] = DateTime.now().toUtc().toIso8601String();
    session[_kClockRollback] = false;
  }

  /// True when [course]'s access has ended by the device clock.
  static bool _accessEnded(StoredCourse course) {
    final ends = course.accessEndsAt;
    if (ends == null) return false;
    final at = DateTime.tryParse(ends);
    // An unparseable date is not proof of expiry; the server re-checks online.
    if (at == null) return false;
    return !DateTime.now().toUtc().isBefore(at.toUtc());
  }

  /// The localized reason [course] may NOT be played without the server, or
  /// null when it may. [countOpen] increments the offline open counter first
  /// (an app open or course entry); the content gate only checks it.
  static String? _offlineRefusal(
    Map<String, dynamic> session,
    StoredCourse course, {
    required bool countOpen,
    required bool clockRolledBack,
  }) {
    final strings = LocaleService.instance.strings;
    if (clockRolledBack) return strings.clockChanged;
    if (_accessEnded(course)) return strings.srvEnrollmentExpired;
    if (countOpen) course.offlineCounter++;
    if (course.offlineCounter >= maxOfflineOpens) return strings.offlineTooLong;
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NETWORKING
  // ══════════════════════════════════════════════════════════════════════════

  static Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Verify a single course with the server (lightweight, no password).
  ///
  /// On success the refreshed token, content key, access end, headphone flag
  /// and seat are written into [course] IN PLACE — the caller then persists
  /// the session it already holds. (Persisting from here and letting the
  /// caller write its older copy afterwards used to undo the token refresh.)
  /// The in-memory [AuthService] state is updated too, and the native
  /// decryptor gets the new key when this is the active course.
  ///
  /// Verdicts: 200 `valid:true` → valid; 401 or `SESSION_INVALID` → reauth
  /// (never offline); 426 / `APP_UPDATE_REQUIRED` → updateRequired; 408, 429,
  /// 5xx, an unparseable body or a transport failure → offline (bounded by the
  /// counter); any other JSON answer → blocked with its reason.
  static Future<_Verdict> _verifyWithServer(
    StoredCourse course,
    String deviceId,
  ) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.postUrl(
        Uri.parse('${AuthService.workerUrl}/auth/verify-session'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set(kAppBuildHeader, '$kAppBuild');
      final token =
          AuthService.tokenFor(course.studentId) ?? course.sessionToken;
      if (token == null) return _Verdict.reauth;
      request.headers.set('Authorization', 'Bearer $token');
      request.write(
        jsonEncode({
          'deviceId': deviceId,
          'platform': PlatformIdentity.current,
        }),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final status = response.statusCode;

      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}

      if (AppUpdateGate.isUpdateRequired(status, data)) {
        AppUpdateGate.report();
        return _Verdict.updateRequired;
      }
      if (status == 401 || data?['code'] == 'SESSION_INVALID') {
        return _Verdict.reauth;
      }
      // No authoritative verdict: treat as offline (bounded by the offline
      // counter), NEVER as a valid session.
      if (status == 408 || status == 429 || status >= 500 || data == null) {
        return _Verdict.offline;
      }

      if (status == 200 && data['valid'] == true) {
        await _applyRefresh(course, data);
        return _Verdict.valid;
      }
      if (status == 200 && data['valid'] != false) return _Verdict.offline;

      // The server's verdict is authoritative: a real BLOCK.
      final reason = data['reason'];
      return _Verdict(
        _VerdictKind.blocked,
        reason is String ? reason : 'invalid',
      );
    } on TimeoutException {
      return _Verdict.offline;
    } on SocketException {
      return _Verdict.offline;
    } on HandshakeException {
      return _Verdict.offline;
    } on HttpException {
      return _Verdict.offline;
    } catch (_) {
      // Any other transport-level failure → offline (bounded by the counter),
      // NEVER a synthesized valid session.
      return _Verdict.offline;
    } finally {
      client.close(force: true);
    }
  }

  /// Copies what a successful verification (or re-login) returned into
  /// [course], [AuthService] and — for the active course — the native
  /// decryptor.
  static Future<void> _applyRefresh(
    StoredCourse course,
    Map<String, dynamic> data,
  ) async {
    final token = data['sessionToken'];
    final key = data['contentKey'];
    final headphones = data['requireHeadphones'];
    final seat = data['seatNo'];
    final courseId = data['courseId'];
    final endsKnown = data.containsKey('accessEndsAt');
    final ends = data['accessEndsAt'];

    final newToken = token is String && token.isNotEmpty ? token : null;
    final newKey = key is String && isValidContentKey(key) ? key : null;
    final newEnds = ends is String ? ends : null;

    if (newToken != null) course.sessionToken = newToken;
    if (newKey != null) course.contentKey = newKey;
    if (endsKnown) course.accessEndsAt = newEnds;
    if (headphones is bool) course.requireHeadphones = headphones;
    if (seat is int) course.seatNo = seat;
    if (courseId is num) course.courseId = courseId.toInt();

    final isActive = AuthService.applyRefresh(
      course.studentId,
      contentKey: newKey,
      accessEndsAtKnown: endsKnown,
      accessEndsAt: newEnds,
      requireHeadphones: headphones is bool ? headphones : null,
      seatNo: seat is int ? seat : null,
      sessionToken: newToken,
    );
    if (isActive && newKey != null) {
      await AmoNativeBridge.setContentKey(newKey);
    }
  }

  /// Test hook for [_applyRefresh]: the in-place refresh a verify-session
  /// answer goes through.
  @visibleForTesting
  static Future<void> applyRefreshForTest(
    StoredCourse course,
    Map<String, dynamic> data,
  ) => _applyRefresh(course, data);

  /// Marks [course] as verified online just now.
  static void _resetCounter(StoredCourse course) {
    course.offlineCounter = 0;
    course.lastVerified = DateTime.now().toIso8601String();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ══════════════════════════════════════════════════════════════════════════

  /// Called once when the app starts (from SplashGate).
  static Future<SessionCheckResult> checkOnAppOpen() async {
    final session = await _readSession();
    if (session == null) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final courses = _parseCourses(session);
    if (courses.isEmpty) {
      await clearSession();
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    return _checkAll(session, courses);
  }

  /// Called periodically while the app stays open.
  static Future<SessionCheckResult> periodicCheck() async {
    final session = await _readSession();
    if (session == null) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final courses = _parseCourses(session);
    if (courses.isEmpty) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    return _checkAll(session, courses);
  }

  /// Verifies every stored course online where possible; applies the offline
  /// policy (counting one open) to each course the server could not vouch for.
  static Future<SessionCheckResult> _checkAll(
    Map<String, dynamic> session,
    List<StoredCourse> courses,
  ) async {
    final deviceId = session['deviceId'] as String;
    final online = await _hasInternet();
    final rolledBack = _observeClock(session);

    var anyVerified = false;
    final needsReVerify = <StoredCourse>[];
    String? notice;

    for (final course in courses) {
      final verdict = online
          ? await _verifyWithServer(course, deviceId)
          : _Verdict.offline;

      switch (verdict.kind) {
        case _VerdictKind.valid:
          _resetCounter(course);
          anyVerified = true;
        case _VerdictKind.updateRequired:
          await _saveCourses(session, courses);
          return SessionCheckResult(
            result: SessionResult.updateRequired,
            storedCourses: courses,
          );
        case _VerdictKind.blocked:
          _invalidateVerifyCache();
          await _saveCourses(session, courses);
          return SessionCheckResult(
            result: SessionResult.blocked,
            blockedReason: verdict.reason,
            blockedServerCode: course.serverCode,
            storedCourses: courses,
          );
        case _VerdictKind.reauth:
          needsReVerify.add(course);
          notice ??= LocaleService.instance.strings.srvSessionInvalid;
        case _VerdictKind.offline:
          final refusal = _offlineRefusal(
            session,
            course,
            countOpen: true,
            clockRolledBack: rolledBack,
          );
          if (refusal != null) {
            needsReVerify.add(course);
            notice ??= refusal;
          }
      }
    }

    // An online verification proves the clock is sane again. Only a course
    // the server actually vouched for clears the flag.
    if (anyVerified && needsReVerify.isEmpty) _clockVerifiedOnline(session);
    await _saveCourses(session, courses);

    if (needsReVerify.isNotEmpty) {
      _invalidateVerifyCache();
      return SessionCheckResult(
        result: SessionResult.needsReVerify,
        storedCourses: courses,
        notice: notice,
      );
    }
    if (anyVerified) _markVerified();
    return SessionCheckResult(result: SessionResult.ok, storedCourses: courses);
  }

  static Future<void> _saveCourses(
    Map<String, dynamic> session,
    List<StoredCourse> courses,
  ) async {
    session['courses'] = courses.map((c) => c.toJson()).toList();
    session['appOpenedAt'] = DateTime.now().toIso8601String();
    await _writeSession(session);
  }

  /// Verify a single course when the user taps on it in CourseSelectScreen.
  /// Returns a [SessionCheckResult] for that course.
  static Future<SessionCheckResult> verifySingleCourse(
    StoredCourse course,
  ) async {
    final session = await _readSession();
    if (session == null) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final courses = _parseCourses(session);
    final index = courses.indexWhere((c) => c.studentId == course.studentId);
    if (index < 0) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final stored = courses[index];

    // Verified moments ago (app open): only the local checks apply.
    final fresh =
        _lastVerifyTime != null &&
        _lastVerifyResult == true &&
        DateTime.now().difference(_lastVerifyTime!).inSeconds < 60;
    return _checkOne(session, courses, stored, countOpen: !fresh, fresh: fresh);
  }

  /// Called before playing a video or opening a PDF (content gate, contract
  /// §3.7).
  ///
  /// The local policy (clock rollback, access end, exhausted counter) runs
  /// EVERY time, even inside the verification cache window. The server round
  /// trip is skipped when a verification succeeded within the last 24 hours;
  /// the periodic check is the backstop.
  static Future<SessionCheckResult> checkBeforeContent() async {
    final session = await _readSession();
    if (session == null) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final courses = _parseCourses(session);
    final activeId = AuthService.loggedInStudentId;
    final index = courses.indexWhere((c) => c.studentId == activeId);
    if (index < 0) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }
    final fresh =
        _lastVerifyTime != null &&
        _lastVerifyResult == true &&
        DateTime.now().difference(_lastVerifyTime!).inHours < 24;
    return _checkOne(
      session,
      courses,
      courses[index],
      countOpen: false,
      fresh: fresh,
    );
  }

  static Future<SessionCheckResult> _checkOne(
    Map<String, dynamic> session,
    List<StoredCourse> courses,
    StoredCourse stored, {
    required bool countOpen,
    required bool fresh,
  }) async {
    final deviceId = session['deviceId'] as String;
    final rolledBack = _observeClock(session);

    _Verdict verdict = _Verdict.offline;
    if (!fresh || rolledBack || _accessEnded(stored)) {
      // A suspect local state is worth a round trip even inside the cache
      // window: the server may clear it (extended course, corrected clock).
      if (await _hasInternet()) {
        verdict = await _verifyWithServer(stored, deviceId);
      }
    } else {
      // Inside the cache window with nothing suspicious: no request.
      verdict = const _Verdict(_VerdictKind.valid);
      countOpen = false;
    }

    final strings = LocaleService.instance.strings;
    switch (verdict.kind) {
      case _VerdictKind.valid:
        if (!fresh) {
          _resetCounter(stored);
          _clockVerifiedOnline(session);
          _markVerified();
        } else if (stored.offlineCounter >= maxOfflineOpens) {
          await _saveCourses(session, courses);
          return SessionCheckResult(
            result: SessionResult.needsReVerify,
            storedCourses: [stored],
            notice: strings.offlineTooLong,
          );
        }
        await _saveCourses(session, courses);
        return SessionCheckResult(
          result: SessionResult.ok,
          storedCourses: courses,
        );
      case _VerdictKind.updateRequired:
        await _saveCourses(session, courses);
        return SessionCheckResult(
          result: SessionResult.updateRequired,
          storedCourses: courses,
        );
      case _VerdictKind.reauth:
        _invalidateVerifyCache();
        await _saveCourses(session, courses);
        return SessionCheckResult(
          result: SessionResult.needsReVerify,
          storedCourses: [stored],
          notice: strings.srvSessionInvalid,
        );
      case _VerdictKind.blocked:
        // Invalidate the verify cache so a just-blocked account can't slip
        // through the content-gate window before logout completes.
        _invalidateVerifyCache();
        await _saveCourses(session, courses);
        return SessionCheckResult(
          result: SessionResult.blocked,
          blockedReason: verdict.reason,
          blockedServerCode: stored.serverCode,
          storedCourses: courses,
        );
      case _VerdictKind.offline:
        final refusal = _offlineRefusal(
          session,
          stored,
          countOpen: countOpen,
          clockRolledBack: rolledBack,
        );
        await _saveCourses(session, courses);
        if (refusal != null) {
          _invalidateVerifyCache();
          return SessionCheckResult(
            result: SessionResult.needsReVerify,
            storedCourses: [stored],
            notice: refusal,
          );
        }
        return SessionCheckResult(
          result: SessionResult.ok,
          storedCourses: courses,
        );
    }
  }

  /// Force a verify-session round-trip for the ACTIVE course so a teacher
  /// toggling `requireHeadphones` is reflected without re-login. No-op (keeps
  /// the last known value) when offline or with no active session. Returns the
  /// current flag value.
  static Future<bool> refreshActiveRequireHeadphones() async {
    final studentId = AuthService.loggedInStudentId;
    if (studentId == null) return AuthService.activeRequireHeadphones;
    if (!await _hasInternet()) return AuthService.activeRequireHeadphones;
    final session = await _readSession();
    if (session == null) return AuthService.activeRequireHeadphones;
    final courses = _parseCourses(session);
    final index = courses.indexWhere((c) => c.studentId == studentId);
    if (index < 0) return AuthService.activeRequireHeadphones;
    final course = courses[index];
    final verdict = await _verifyWithServer(
      course,
      session['deviceId'] as String,
    );
    if (verdict.kind == _VerdictKind.valid) {
      _resetCounter(course);
      _clockVerifiedOnline(session);
      await _saveCourses(session, courses);
      _markVerified();
    }
    return AuthService.activeRequireHeadphones;
  }

  /// Re-verify a specific course using server code + password.
  ///
  /// On success the new token, content key and access end are saved to
  /// storage AND memory, the offline counter is reset and the clock flag
  /// cleared (contract §3.5). The caller hands the key to the native decryptor
  /// after switching to the course.
  static Future<LoginFailure?> reVerifyCourse(
    StoredCourse course,
    String password,
  ) async {
    final attempt = await AuthService.requestLogin(
      course.serverCode,
      password,
      reVerify: true,
    );
    final fresh = attempt.courses;
    if (fresh == null) return attempt.failure;

    final match = fresh.firstWhere(
      (c) => c.studentId == course.studentId,
      orElse: () => fresh.firstWhere(
        (c) => c.serverCode == course.serverCode,
        orElse: () => fresh.first,
      ),
    );

    final session = await _readSession();
    if (session == null) {
      // The stored session vanished meanwhile (tamper check, logout in
      // another path): start one from what the server just returned.
      await createSession(fresh, course.serverCode);
      return null;
    }

    final courses = _parseCourses(session);
    final index = courses.indexWhere((c) => c.studentId == course.studentId);
    final StoredCourse target;
    if (index >= 0) {
      target = courses[index];
    } else {
      // Dropped by _parseCourses (no content key yet): take the fresh copy.
      target = StoredCourse.fromSession(match, course.serverCode);
      courses.add(target);
    }

    await _applyRefresh(target, {
      'sessionToken': match.sessionToken,
      'contentKey': match.contentKey,
      'accessEndsAt': match.accessEndsAt,
      'requireHeadphones': match.requireHeadphones,
      'seatNo': match.seatNo,
      'courseId': match.courseId,
    });
    // Set on [target] itself, the copy [_saveCourses] writes below — never
    // through a helper that persists on its own (cerebrum Do-Not-Repeat).
    // Kept out of [_applyRefresh], which also handles verify-session answers.
    if (match.password != null) target.password = match.password;
    _resetCounter(target);
    _clockVerifiedOnline(session);
    await _saveCourses(session, courses);
    _markVerified();
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ROUTING
  // ══════════════════════════════════════════════════════════════════════════

  /// Acts on a check that did not come back [SessionResult.ok]: re-verify
  /// screen, forced logout, or nothing (update dialog already shown).
  /// Returns true only for [SessionResult.ok], so callers can write
  /// `if (!await SessionService.handleCheck(context, check)) return;`.
  static bool handleCheck(BuildContext context, SessionCheckResult check) {
    switch (check.result) {
      case SessionResult.ok:
        return true;
      case SessionResult.updateRequired:
        return false;
      case SessionResult.needsReVerify:
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => ReVerifyScreen(
              courses: check.storedCourses,
              notice: check.notice,
            ),
          ),
          (route) => false,
        );
        return false;
      case SessionResult.needsFullLogin:
        showForceLogout(context, 'session_expired');
        return false;
      case SessionResult.blocked:
        showForceLogout(
          context,
          check.blockedReason ?? 'invalid',
          serverCode: check.blockedServerCode,
        );
        return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ERROR MESSAGES & FORCE LOGOUT
  // ══════════════════════════════════════════════════════════════════════════

  static String getErrorMessage(String reason) {
    switch (reason) {
      case 'removed':
      case 'device_changed':
        if (kDebugMode) debugPrint('[AMO] Session blocked reason: $reason');
        return LocaleService.instance.strings.errSessionExpiredLogin;
      case 'platform_changed':
        if (kDebugMode) {
          debugPrint('[AMO] Session blocked reason: platform_changed');
        }
        return LocaleService.instance.strings.errPlatformLocked;
      case 'course_expired':
        return LocaleService.instance.strings.errCourseAccessExpired;
      case 'offline_limit':
        return LocaleService.instance.strings.errConnectToVerify;
      case 'session_expired':
        return LocaleService.instance.strings.errSessionExpired;
      default:
        return LocaleService.instance.strings.errSessionInvalid;
    }
  }

  /// Show force-logout dialog and navigate to login screen.
  ///
  /// When access to a course has ended, the dialog also says how much space
  /// that course's files take on this device and offers to delete them. It
  /// only offers: the teacher may extend the course, and then the files would
  /// have to be downloaded again, so the student decides.
  ///
  /// [serverCode] names the course the verdict is about; it defaults to the
  /// course currently open.
  static Future<void> showForceLogout(
    BuildContext context,
    String reason, {
    String? serverCode,
  }) async {
    final message = getErrorMessage(reason);
    final code = serverCode ?? AuthService.loggedInServerCode;

    var leftovers = const <File>[];
    var leftoverBytes = 0;
    if (reason == 'course_expired' && code != null) {
      try {
        leftovers = await CourseFilesService.filesFor(code);
        leftoverBytes = await CourseFilesService.totalBytes(leftovers);
      } catch (_) {}
    }
    if (!context.mounted) return;

    final offerDelete = leftoverBytes > 0;
    final sizeLabel = CourseFilesService.formatBytes(leftoverBytes);
    var deleting = false;

    void leave(BuildContext dialogContext) {
      AuthService.logout();
      clearSession();
      Navigator.of(dialogContext).pop();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            icon: Icon(
              reason == 'offline_limit' ? Icons.wifi_off : Icons.block,
              color: AppColors.error,
              size: 48,
            ),
            title: Text(
              reason == 'offline_limit'
                  ? AmoL10n.of(context).errInternetRequiredTitle
                  : AmoL10n.of(context).errAccessDeniedTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                if (offerDelete) ...[
                  const SizedBox(height: 16),
                  CourseFilesSizeBox(sizeLabel: sizeLabel),
                ],
              ],
            ),
            actions: [
              if (offerDelete) ...[
                CourseFilesDeleteButton(
                  sizeLabel: sizeLabel,
                  deleting: deleting,
                  onPressed: deleting
                      ? null
                      : () async {
                          setDialogState(() => deleting = true);
                          await CourseFilesService.delete(code!, leftovers);
                          if (!ctx.mounted) return;
                          leave(ctx);
                        },
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: deleting ? null : () => leave(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    offerDelete
                        ? AmoL10n.of(context).courseFilesKeep
                        : reason == 'offline_limit'
                        ? AmoL10n.of(context).actionOk
                        : AmoL10n.of(context).actionGoToLogin,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
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
