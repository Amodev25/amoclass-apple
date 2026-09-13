import 'package:amo_core/amo_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.rtl,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Stack(children: [const SizedBox.expand(), child]),
      ),
    );

void main() {
  testWidgets('draws the name and the password', (tester) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'أحمد علي', password: 'pw-1234')),
    );
    expect(find.text('أحمد علي'), findsOneWidget);
    expect(find.text('pw-1234'), findsOneWidget);
  });

  testWidgets('a session without a stored password shows the name only', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'Sara', password: '  ')),
    );
    expect(find.text('Sara'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('never takes touches from the player underneath', (tester) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'Sara', password: 'x')),
    );
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(of: find.text('Sara'), matching: find.byType(IgnorePointer))
          .first,
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('moves to a new spot every interval', (tester) async {
    await tester.pumpWidget(
      _host(
        const StudentWatermark(
          name: 'Sara',
          password: 'x',
          interval: Duration(seconds: 5),
        ),
      ),
    );
    Alignment current() => tester
        .widget<AnimatedAlign>(find.byType(AnimatedAlign))
        .alignment as Alignment;
    final before = current();
    await tester.pump(const Duration(seconds: 5));
    expect(current(), isNot(before));
    // Removing the widget cancels its timer (a leaked timer fails the test).
    await tester.pumpWidget(_host(const SizedBox()));
  });
}
