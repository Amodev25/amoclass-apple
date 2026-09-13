import 'package:amo_core/amo_core.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'course_files_service.dart';
import 'auth_service.dart';
import '../screens/login_screen.dart';
import '../core/platform_identity.dart';

/// Result of a session check.
enum SessionResult {
  /// Session is valid — proceed to library.
  ok,

  /// Offline limit reached — show password-only re-verify screen.
  needsReVerify,

  /// No session file — show full login screen.
  needsFullLogin,

  /// Account removed / device changed / platform changed — blocked.
  blocked,
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

  const SessionCheckResult({
    required this.result,
    this.blockedReason,
    this.blockedServerCode,
    this.storedCourses = const [],
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
  String? credential;
  String? courseSecret;
  bool requireHeadphones;

  /// The student's seat number (`رقم الجلوس`) in THIS course — spec D7.
  ///
  /// Per enrolment, not per person: a student in two courses has two seat
  /// numbers, which is why it lives here and not beside the student's name.
  /// Null only for a session restored from a file written before T11, or a row
  /// that somehow predates the server-side allocator; the UI omits the line
  /// rather than showing a zero.
  ///
  /// Mutable, like `credential`: /auth/verify-session returns it on every
  /// check-in, so a seat the teacher corrected reaches the student without a
  /// re-login.
  int? seatNo;

  /// Bearer token for this enrolment. Refreshed by /auth/verify-session, so it
  /// is persisted here rather than held only in memory — otherwise every app
  /// restart would need a password.
  String? sessionToken;
  int offlineCounter;
  String lastVerified;

  StoredCourse({
    required this.studentId,
    required this.studentName,
    required this.teacherId,
    required this.teacherName,
    required this.courseName,
    required this.serverCode,
    this.credential,
    this.courseSecret,
    this.requireHeadphones = false,
    this.seatNo,
    this.sessionToken,
    this.offlineCounter = 0,
    String? lastVerified,
  }) : lastVerified = lastVerified ?? DateTime.now().toIso8601String();

  Map<String, dynamic> toJson() => {
    'studentId': studentId,
    'studentName': studentName,
    'teacherId': teacherId,
    'teacherName': teacherName,
    'courseName': courseName,
    'serverCode': serverCode,
    'credential': credential,
    'courseSecret': courseSecret,
    'requireHeadphones': requireHeadphones,
    'seatNo': seatNo,
    'sessionToken': sessionToken,
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
    credential: j['credential'] as String?,
    courseSecret: j['courseSecret'] as String?,
    requireHeadphones: (j['requireHeadphones'] as bool?) ?? false,
    seatNo: j['seatNo'] as int?,
    sessionToken: j['sessionToken'] as String?,
    offlineCounter: (j['offlineCounter'] as int?) ?? 0,
    lastVerified: j['lastVerified'] as String?,
  );
}

/// Manages the signed session file, offline counters, and session verification.
/// Uses HMAC-signed JSON to prevent tampering.
class SessionService {
  static const _channel = MethodChannel('com.lockclass/anti_capture');
  static const _fileName = '.amo_session'; // legacy plaintext (migrated away)

  /// Keystore-backed secure storage for the session blob and signing secret.
  /// Replaces the previous plaintext .amo_session / amo_app_key files so the
  /// credential + courseSecret are encrypted at rest — not recoverable from a
  /// file pull on a rooted device without the hardware-backed key.
  static final _storage = const FlutterSecureStorage();
  static const _kSession = 'amo_session_json';
  static const _kAppSecret = 'amo_app_secret';
  static String? _appSecret;

  /// Generate and persist a per-installation random secret (in the Keystore).
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

  /// Maximum offline opens before requiring re-verification.
  static const int maxOfflineOpens = 3;

  // Cache: skip verify-session if last check was < 30 seconds ago
  static DateTime? _lastVerifyTime;
  static bool? _lastVerifyResult;

  // ══════════════════════════════════════════════════════════════════════════
  // SIGNING
  // ══════════════════════════════════════════════════════════════════════════

  /// Generate HMAC signature for tamper detection.
  static Future<String> _sign(Map<String, dynamic> data) async {
    await _ensureAppSecret();
    final payload = jsonEncode({
      'courses': data['courses'],
      'deviceId': data['deviceId'],
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

  /// Get unique device ID from native Android via MethodChannel
  static Future<String> _getDeviceId() async {
    try {
      final id = await _channel.invokeMethod<String>('getDeviceId');
      return id ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  // ── Read / Write ────────────────────────────────────────────────────────

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

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Create / Clear
  // ══════════════════════════════════════════════════════════════════════════

  /// Create session file after a successful full login.
  static Future<void> createSession(
    List<CourseSession> courses,
    String serverCode,
  ) async {
    final deviceId = await _getDeviceId();
    final storedCourses = courses
        .map(
          (c) => StoredCourse(
            studentId: c.studentId,
            studentName: c.studentName,
            teacherId: c.teacherId,
            teacherName: c.teacherName,
            courseName: c.courseName,
            serverCode: c.serverCode ?? serverCode,
            credential: c.credential,
            courseSecret: c.courseSecret,
            requireHeadphones: c.requireHeadphones,
            seatNo: c.seatNo,
            sessionToken: c.sessionToken,
          ).toJson(),
        )
        .toList();

    final data = <String, dynamic>{
      'courses': storedCourses,
      'deviceId': deviceId,
      'appOpenedAt': DateTime.now().toIso8601String(),
    };
    await _writeSession(data);
    _lastVerifyTime = DateTime.now();
    _lastVerifyResult = true;
  }

  /// Add new courses to the existing session file (merge).
  /// If a course with the same studentId already exists, it is updated.
  /// Otherwise the new course is appended.
  static Future<void> addCoursesToSession(
    List<CourseSession> newCourses,
    String serverCode,
  ) async {
    final deviceId = await _getDeviceId();
    final session = await _readSession();

    // Build StoredCourse objects for the new courses
    final newStored = newCourses
        .map(
          (c) => StoredCourse(
            studentId: c.studentId,
            studentName: c.studentName,
            teacherId: c.teacherId,
            teacherName: c.teacherName,
            courseName: c.courseName,
            serverCode: c.serverCode ?? serverCode,
            credential: c.credential,
            courseSecret: c.courseSecret,
            requireHeadphones: c.requireHeadphones,
            seatNo: c.seatNo,
            sessionToken: c.sessionToken,
          ),
        )
        .toList();

    if (session == null) {
      // No existing session — create fresh
      final data = <String, dynamic>{
        'courses': newStored.map((c) => c.toJson()).toList(),
        'deviceId': deviceId,
        'appOpenedAt': DateTime.now().toIso8601String(),
      };
      await _writeSession(data);
      _lastVerifyTime = DateTime.now();
      _lastVerifyResult = true;
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
    await _writeSession(session);
    _lastVerifyTime = DateTime.now();
    _lastVerifyResult = true;
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

  static List<StoredCourse> _parseCourses(Map<String, dynamic> session) {
    final raw = session['courses'] as List<dynamic>?;
    if (raw == null || raw.isEmpty) return [];
    return raw
        .map((c) => StoredCourse.fromJson(c as Map<String, dynamic>))
        .toList();
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
    final deviceId = session['deviceId'] as String;
    final online = await _hasInternet();

    // Find matching course in session
    final stored = courses.firstWhere(
      (c) => c.studentId == course.studentId,
      orElse: () => course,
    );

    if (online) {
      if (_lastVerifyTime != null &&
          _lastVerifyResult == true &&
          DateTime.now().difference(_lastVerifyTime!).inSeconds < 60) {
        stored.offlineCounter = 0;
        stored.lastVerified = DateTime.now().toIso8601String();
        session['courses'] = courses.map((c) => c.toJson()).toList();
        session['appOpenedAt'] = DateTime.now().toIso8601String();
        await _writeSession(session);
        return SessionCheckResult(
          result: SessionResult.ok,
          storedCourses: courses,
        );
      }

      final result = await _verifyWithServer(stored.studentId, deviceId);

      if (result['offline'] == true) {
        // Server unreachable — treat as offline
        stored.offlineCounter++;
        if (stored.offlineCounter >= maxOfflineOpens) {
          session['courses'] = courses.map((c) => c.toJson()).toList();
          await _writeSession(session);
          return SessionCheckResult(
            result: SessionResult.needsReVerify,
            storedCourses: [stored],
          );
        }
        session['courses'] = courses.map((c) => c.toJson()).toList();
        await _writeSession(session);
        return SessionCheckResult(
          result: SessionResult.ok,
          storedCourses: courses,
        );
      }

      if (result['valid'] == true) {
        stored.offlineCounter = 0;
        stored.lastVerified = DateTime.now().toIso8601String();
        session['courses'] = courses.map((c) => c.toJson()).toList();
        session['appOpenedAt'] = DateTime.now().toIso8601String();
        await _writeSession(session);
        _lastVerifyTime = DateTime.now();
        _lastVerifyResult = true;
        return SessionCheckResult(
          result: SessionResult.ok,
          storedCourses: courses,
        );
      } else {
        final reason = result['reason'] as String? ?? 'invalid';
        return SessionCheckResult(
          result: SessionResult.blocked,
          blockedReason: reason,
          blockedServerCode: stored.serverCode,
          storedCourses: courses,
        );
      }
    } else {
      // Offline
      stored.offlineCounter++;
      session['courses'] = courses.map((c) => c.toJson()).toList();
      await _writeSession(session);

      if (stored.offlineCounter >= maxOfflineOpens) {
        return SessionCheckResult(
          result: SessionResult.needsReVerify,
          storedCourses: [stored],
        );
      }

      return SessionCheckResult(
        result: SessionResult.ok,
        storedCourses: courses,
      );
    }
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
  /// Also updates credentials if the server returns new ones.
  static Future<Map<String, dynamic>> _verifyWithServer(
    int studentId,
    String deviceId,
  ) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.postUrl(
        Uri.parse('${AuthService.workerUrl}/auth/verify-session'),
      );
      request.headers.set('Content-Type', 'application/json');
      // The student is named by the token, not by the body. A request without
      // one is answered 401 — which the non-200 branch below already treats as
      // non-authoritative rather than as a valid session.
      final token = AuthService.tokenFor(studentId);
      if (token != null) {
        request.headers.set('Authorization', 'Bearer $token');
      }
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

      // A non-200 status means we did NOT get an authoritative verdict from the
      // server. Treat that as "offline" (bounded by the offline-open counter),
      // NEVER as a valid session.
      if (response.statusCode != 200) {
        return {'offline': true};
      }

      // An unparseable body on a reached server is likewise non-authoritative.
      final Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) return {'offline': true};
        data = decoded;
      } catch (_) {
        return {'offline': true};
      }

      // The server's verdict is authoritative. A `valid:false` (with a reason)
      // is a real BLOCK and is returned unchanged so callers enforce it.
      // Update credentials if the server returned new ones.
      if (data['valid'] == true) {
        // Rolling renewal: the server hands back a fresh token on every
        // successful check-in, so an app used normally never has to ask for a
        // password again.
        final refreshed = data['sessionToken'] as String?;
        if (refreshed != null) {
          AuthService.rememberToken(studentId, refreshed);
          await _persistSessionToken(studentId, refreshed);
        }
        final newCredential = data['credential'] as String?;
        final newCourseSecret = data['courseSecret'] as String?;
        final newRequireHeadphones = data['requireHeadphones'] as bool?;
        // D7. The seat number travels on every check-in, not just at login, so
        // it cannot appear once and then vanish on the next app start.
        final newSeatNo = data['seatNo'] as int?;
        if (newCredential != null ||
            newCourseSecret != null ||
            newRequireHeadphones != null ||
            newSeatNo != null) {
          AuthService.updateCredentials(
            newCredential,
            newCourseSecret,
            requireHeadphones: newRequireHeadphones,
          );
          // Also update the stored session file with new values
          await _updateStoredCredentials(
            studentId,
            newCredential,
            newCourseSecret,
            newRequireHeadphones,
            newSeatNo,
          );
        }
      }

      return data;
    } on TimeoutException {
      return {'offline': true};
    } on SocketException {
      return {'offline': true};
    } on HandshakeException {
      return {'offline': true};
    } on HttpException {
      return {'offline': true};
    } catch (_) {
      // Any other transport-level failure → offline (bounded by the counter),
      // NEVER a synthesized valid session. This is the fail-CLOSED behavior:
      // blocking the worker host no longer grants unlimited access.
      return {'offline': true};
    } finally {
      client.close(force: true);
    }
  }

  /// Update credential/courseSecret in the stored session file for a given student.
  /// Write a refreshed session token into the stored session file.
  static Future<void> _persistSessionToken(int studentId, String token) async {
    final session = await _readSession();
    if (session == null) return;
    final courses = _parseCourses(session);
    var changed = false;
    for (final c in courses) {
      if (c.studentId == studentId && c.sessionToken != token) {
        c.sessionToken = token;
        changed = true;
      }
    }
    if (changed) {
      session['courses'] = courses.map((c) => c.toJson()).toList();
      await _writeSession(session);
    }
  }

  static Future<void> _updateStoredCredentials(
    int studentId,
    String? credential,
    String? courseSecret,
    bool? requireHeadphones,
    int? seatNo,
  ) async {
    if (credential == null &&
        courseSecret == null &&
        requireHeadphones == null &&
        seatNo == null) {
      return;
    }
    final session = await _readSession();
    if (session == null) return;

    final courses = _parseCourses(session);
    bool updated = false;
    for (final c in courses) {
      if (c.studentId == studentId) {
        if (credential != null) c.credential = credential;
        if (courseSecret != null) c.courseSecret = courseSecret;
        if (requireHeadphones != null) c.requireHeadphones = requireHeadphones;
        if (seatNo != null) c.seatNo = seatNo;
        updated = true;
      }
    }

    if (updated) {
      session['courses'] = courses.map((c) => c.toJson()).toList();
      await _writeSession(session);
    }
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
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }

    final deviceId = session['deviceId'] as String;
    final online = await _hasInternet();

    if (online) {
      bool anyBlocked = false;
      String? blockedReason;

      for (final course in courses) {
        final result = await _verifyWithServer(course.studentId, deviceId);

        if (result['offline'] == true) {
          course.offlineCounter++;
          continue;
        }

        if (result['valid'] == true) {
          course.offlineCounter = 0;
          course.lastVerified = DateTime.now().toIso8601String();
        } else {
          anyBlocked = true;
          blockedReason = result['reason'] as String? ?? 'invalid';
          break;
        }
      }

      if (anyBlocked) {
        return SessionCheckResult(
          result: SessionResult.blocked,
          blockedReason: blockedReason,
          storedCourses: courses,
        );
      }

      session['courses'] = courses.map((c) => c.toJson()).toList();
      session['appOpenedAt'] = DateTime.now().toIso8601String();
      await _writeSession(session);

      _lastVerifyTime = DateTime.now();
      _lastVerifyResult = true;

      return SessionCheckResult(
        result: SessionResult.ok,
        storedCourses: courses,
      );
    } else {
      bool anyExceeded = false;

      for (final course in courses) {
        course.offlineCounter++;
        if (course.offlineCounter >= maxOfflineOpens) {
          anyExceeded = true;
        }
      }

      session['courses'] = courses.map((c) => c.toJson()).toList();
      await _writeSession(session);

      if (anyExceeded) {
        return SessionCheckResult(
          result: SessionResult.needsReVerify,
          storedCourses: courses,
        );
      }

      return SessionCheckResult(
        result: SessionResult.ok,
        storedCourses: courses,
      );
    }
  }

  /// Force a verify-session round-trip for the ACTIVE course so a teacher
  /// toggling `requireHeadphones` is reflected without re-login. As a side
  /// effect [_verifyWithServer] updates [AuthService.activeRequireHeadphones]
  /// and the stored session file. No-op (keeps the last known value) when
  /// offline or with no active session. Returns the current flag value.
  static Future<bool> refreshActiveRequireHeadphones() async {
    final studentId = AuthService.loggedInStudentId;
    if (studentId == null) return AuthService.activeRequireHeadphones;
    if (!await _hasInternet()) return AuthService.activeRequireHeadphones;
    final session = await _readSession();
    final deviceId = session?['deviceId'] as String?;
    if (deviceId == null) return AuthService.activeRequireHeadphones;
    await _verifyWithServer(studentId, deviceId);
    return AuthService.activeRequireHeadphones;
  }

  /// Called before playing a video or opening a PDF (content gate).
  static Future<String?> checkBeforeContent() async {
    // Skip if we have a valid check within the last 24 hours — the background
    // timer handles periodic re-verification; no need to hit the server on
    // every content open.
    if (_lastVerifyTime != null &&
        _lastVerifyResult == true &&
        DateTime.now().difference(_lastVerifyTime!).inHours < 24) {
      return null;
    }

    final session = await _readSession();
    if (session == null) return 'session_expired';

    final courses = _parseCourses(session);
    if (courses.isEmpty) return 'session_expired';

    final deviceId = session['deviceId'] as String;
    final online = await _hasInternet();

    if (online) {
      final activeId = AuthService.loggedInStudentId;
      final course = courses.firstWhere(
        (c) => c.studentId == activeId,
        orElse: () => courses.first,
      );

      final result = await _verifyWithServer(course.studentId, deviceId);

      if (result['offline'] == true) return null;
      if (result['valid'] == true) {
        course.offlineCounter = 0;
        course.lastVerified = DateTime.now().toIso8601String();
        session['courses'] = courses.map((c) => c.toJson()).toList();
        await _writeSession(session);
        _lastVerifyTime = DateTime.now();
        _lastVerifyResult = true;
        return null;
      } else {
        // Invalidate the verify cache so a just-blocked account can't slip
        // through the 24h content-gate window before logout completes.
        _lastVerifyTime = null;
        _lastVerifyResult = false;
        return (result['reason'] as String?) ?? 'invalid';
      }
    }

    return null;
  }

  /// Called periodically (every 24 hours) while app stays open.
  static Future<SessionCheckResult> periodicCheck() async {
    final session = await _readSession();
    if (session == null) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }

    final courses = _parseCourses(session);
    if (courses.isEmpty) {
      return const SessionCheckResult(result: SessionResult.needsFullLogin);
    }

    final deviceId = session['deviceId'] as String;
    final online = await _hasInternet();

    if (!online) {
      bool anyExceeded = false;
      for (final course in courses) {
        course.offlineCounter++;
        if (course.offlineCounter >= maxOfflineOpens) {
          anyExceeded = true;
        }
      }
      session['courses'] = courses.map((c) => c.toJson()).toList();
      await _writeSession(session);

      if (anyExceeded) {
        return SessionCheckResult(
          result: SessionResult.needsReVerify,
          storedCourses: courses,
        );
      }
      return SessionCheckResult(
        result: SessionResult.ok,
        storedCourses: courses,
      );
    }

    for (final course in courses) {
      final result = await _verifyWithServer(course.studentId, deviceId);

      if (result['offline'] == true) continue;

      if (result['valid'] == true) {
        course.offlineCounter = 0;
        course.lastVerified = DateTime.now().toIso8601String();
      } else {
        final reason = result['reason'] as String? ?? 'invalid';
        return SessionCheckResult(
          result: SessionResult.blocked,
          blockedReason: reason,
          blockedServerCode: course.serverCode,
          storedCourses: courses,
        );
      }
    }

    session['courses'] = courses.map((c) => c.toJson()).toList();
    await _writeSession(session);
    _lastVerifyTime = DateTime.now();
    _lastVerifyResult = true;

    return SessionCheckResult(result: SessionResult.ok, storedCourses: courses);
  }

  /// Re-verify a specific course using server code + password.
  static Future<String?> reVerifyCourse(
    StoredCourse course,
    String password,
  ) async {
    final client = HttpClient();
    try {
      final deviceId = await _getDeviceId();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.postUrl(
        Uri.parse('${AuthService.workerUrl}/auth/login'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.write(
        jsonEncode({
          'serverCode': course.serverCode,
          'password': password,
          'platform': PlatformIdentity.current,
          'deviceId': deviceId,
        }),
      );

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['success'] == true) {
        final session = await _readSession();
        if (session != null) {
          final courses = _parseCourses(session);
          for (final c in courses) {
            if (c.studentId == course.studentId) {
              c.offlineCounter = 0;
              c.lastVerified = DateTime.now().toIso8601String();
            }
          }
          session['courses'] = courses.map((c) => c.toJson()).toList();
          await _writeSession(session);
        }
        _lastVerifyTime = DateTime.now();
        _lastVerifyResult = true;
        return null;
      } else {
        return localizeServerError(LocaleService.instance.strings, data);
      }
    } on SocketException {
      return LocaleService.instance.strings.errCannotConnectDialog;
    } catch (e) {
      return LocaleService.instance.strings.errConnectionFailed('$e');
    } finally {
      client.close(force: true);
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
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.sd_storage_outlined,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AmoL10n.of(context).courseFilesOnDeviceLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              sizeLabel,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AmoL10n.of(context).courseFilesOnDeviceBody,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (offerDelete) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: deleting
                        ? null
                        : () async {
                            setDialogState(() => deleting = true);
                            await CourseFilesService.delete(code!, leftovers);
                            if (!ctx.mounted) return;
                            leave(ctx);
                          },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: BorderSide(
                        color: AppColors.error.withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: deleting
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.error,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(AmoL10n.of(context).courseFilesDeleting),
                            ],
                          )
                        : Text(
                            AmoL10n.of(context).courseFilesDelete(sizeLabel),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                  ),
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
