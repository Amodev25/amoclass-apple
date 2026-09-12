import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/services/auth_service.dart';
import 'package:amo_player_apple/services/session_service.dart';

/// T11 — the seat number's trip from the server to the screen (spec D7).
///
/// Pure data, no I/O. The reason it is worth a test is that the failure mode is
/// invisible in the app: `seatNo` reaches `CourseSession`, renders correctly on
/// the course card, and is then dropped by `StoredCourse.toJson` — so the seat
/// is there until the student restarts, and gone afterwards, with no error and
/// nothing on screen to suggest the field was ever meant to be there.
///
/// The session file is also read by installations that predate this field, which
/// is the second case below: a missing key must be null, never a crash and never
/// a zero.
void main() {
  group('CourseSession', () {
    test('reads seatNo from the login response', () {
      final c = CourseSession.fromJson(const {
        'studentId': 7,
        'studentName': 'Hoda Samir Fathy',
        'teacherId': 1,
        'teacherName': 'Instructor',
        'courseName': 'A Course',
        'seatNo': 300,
      });
      expect(c.seatNo, 300);
    });

    test('tolerates a response without one', () {
      // An older worker, or a row the allocator never reached.
      final c = CourseSession.fromJson(const {
        'studentId': 7,
        'studentName': 'Hoda Samir Fathy',
        'teacherId': 1,
        'teacherName': 'Instructor',
        'courseName': 'A Course',
      });
      expect(c.seatNo, isNull);
    });
  });

  group('StoredCourse', () {
    test('survives the round-trip through the session file', () {
      final stored = StoredCourse(
        studentId: 7,
        studentName: 'Hoda Samir Fathy',
        teacherId: 1,
        teacherName: 'Instructor',
        courseName: 'A Course',
        serverCode: 'SERVERCODE-AA',
        seatNo: 300,
      );
      final reread = StoredCourse.fromJson(stored.toJson());
      expect(reread.seatNo, 300,
          reason: 'dropped by toJson — the seat would vanish on app restart');
    });

    test('a session file written before T11 has no seat, not a zero', () {
      final reread = StoredCourse.fromJson(const {
        'studentId': 7,
        'studentName': 'Hoda Samir Fathy',
        'teacherId': 1,
        'teacherName': 'Instructor',
        'courseName': 'A Course',
        'serverCode': 'SERVERCODE-AA',
      });
      expect(reread.seatNo, isNull);
    });

    test('verify-session can correct it in place', () {
      // The field is mutable for this: /auth/verify-session returns the seat on
      // every check-in, so a teacher's correction reaches the student without a
      // re-login. A final field would have needed a whole new StoredCourse.
      final stored = StoredCourse(
        studentId: 7,
        studentName: 'Hoda Samir Fathy',
        teacherId: 1,
        teacherName: 'Instructor',
        courseName: 'A Course',
        serverCode: 'SERVERCODE-AA',
        seatNo: 300,
      );
      stored.seatNo = 42;
      expect(StoredCourse.fromJson(stored.toJson()).seatNo, 42);
    });
  });

  group('LoginFailure', () {
    test('carries the server code beside the translated message', () {
      // The login screen switches on `code` to decide whether to ask for the
      // student's name. Matching on `message` would break the moment it is
      // translated — which has already happened twice in this codebase.
      const f = LoginFailure('تمت الترجمة', 'INVALID_LOGIN');
      expect(f.code, 'INVALID_LOGIN');
      expect(f.message, 'تمت الترجمة');
    });

    test('a transport failure has a message and no code', () {
      const f = LoginFailure('Cannot connect');
      expect(f.code, isNull);
    });
  });
}
