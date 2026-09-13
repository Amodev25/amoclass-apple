import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/services/auth_service.dart';
import 'package:amo_player_apple/services/session_service.dart';

/// The student's password is kept per enrolment for the lesson watermark
/// (owner decision 2026-09-14). Pure data, no I/O.
///
/// The failure modes are silent: a field dropped by `toJson` shows the password
/// until the app restarts, and a token refresh that rebuilds the record without
/// it quietly downgrades the watermark to the name alone.
void main() {
  StoredCourse stored({String? password}) => StoredCourse(
    studentId: 7,
    studentName: 'Hoda Samir Fathy',
    teacherId: 1,
    teacherName: 'Instructor',
    courseName: 'A Course',
    serverCode: 'SERVERCODE-AA',
    sessionToken: 'old-token',
    password: password,
  );

  group('StoredCourse password', () {
    test('survives the round-trip through the session entry', () {
      final reread = StoredCourse.fromJson(
        stored(password: 'pa55-word').toJson(),
      );
      expect(reread.password, 'pa55-word');
    });

    test('a session written before passwords were kept parses to null', () {
      final reread = StoredCourse.fromJson(const {
        'studentId': 7,
        'studentName': 'Hoda Samir Fathy',
        'teacherId': 1,
        'teacherName': 'Instructor',
        'courseName': 'A Course',
        'serverCode': 'SERVERCODE-AA',
        'sessionToken': 'old-token',
        'offlineCounter': 0,
      });
      expect(reread.password, isNull);
    });

    test('is carried from the login CourseSession into storage', () {
      const session = CourseSession(
        studentId: 7,
        studentName: 'Hoda Samir Fathy',
        teacherId: 1,
        teacherName: 'Instructor',
        courseName: 'A Course',
        password: 'pa55-word',
      );
      final s = StoredCourse.fromSession(session, 'SERVERCODE-AA');
      expect(StoredCourse.fromJson(s.toJson()).password, 'pa55-word');
    });
  });

  group('token refresh keeps the password', () {
    test(
      'verify-session refresh (in place) keeps it through the write',
      () async {
        final course = stored(password: 'pa55-word');
        await SessionService.applyRefreshForTest(course, const {
          'sessionToken': 'new-token',
          'seatNo': 42,
          'requireHeadphones': true,
        });
        expect(course.sessionToken, 'new-token');
        final reread = StoredCourse.fromJson(course.toJson());
        expect(reread.sessionToken, 'new-token');
        expect(reread.password, 'pa55-word');
      },
    );

    test('in-memory refresh keeps it, and the active getter reports it', () {
      AuthService.restoreFromSession([stored(password: 'pa55-word')]);
      expect(AuthService.activePassword, 'pa55-word');

      AuthService.applyRefresh(7, sessionToken: 'new-token', seatNo: 42);
      expect(AuthService.courses.single.sessionToken, 'new-token');
      expect(AuthService.courses.single.password, 'pa55-word');
      expect(AuthService.activePassword, 'pa55-word');
    });

    test('CourseSession.copyWith without a password keeps it', () {
      const c = CourseSession(
        studentId: 7,
        studentName: 'Hoda Samir Fathy',
        teacherId: 1,
        teacherName: 'Instructor',
        courseName: 'A Course',
        sessionToken: 'old-token',
        password: 'pa55-word',
      );
      final refreshed = c.copyWith(sessionToken: 'new-token');
      expect(refreshed.password, 'pa55-word');
    });
  });
}
