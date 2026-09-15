import 'package:amo_player_apple/amo_core/amo_core.dart';
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

  testWidgets('keeps moving and never stops', (tester) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'Sara', password: 'x')),
    );
    Alignment current() => tester
        .widget<Align>(
          find.ancestor(of: find.text('Sara'), matching: find.byType(Align)).first,
        )
        .alignment as Alignment;

    // Every half second for two minutes — past several edge bounces — the mark
    // is somewhere new and still inside the frame.
    var previous = current();
    for (var i = 0; i < 240; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final now = current();
      expect(now, isNot(previous), reason: 'stopped at step $i');
      expect(now.x.abs(), lessThanOrEqualTo(0.85));
      expect(now.y.abs(), lessThanOrEqualTo(0.85));
      previous = now;
    }
    // Removing the widget disposes its ticker (a live ticker fails the test).
    await tester.pumpWidget(_host(const SizedBox()));
  });

  testWidgets('moves at a calm speed, not in jumps', (tester) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'Sara', password: 'x')),
    );
    Alignment current() => tester
        .widget<Align>(
          find.ancestor(of: find.text('Sara'), matching: find.byType(Align)).first,
        )
        .alignment as Alignment;
    // One 60 fps frame moves it a sliver: 1.7 of alignment per 13 s at most.
    final before = current();
    await tester.pump(const Duration(milliseconds: 16));
    final after = current();
    expect((after.x - before.x).abs(), lessThan(0.01));
    expect((after.y - before.y).abs(), lessThan(0.01));
    await tester.pumpWidget(_host(const SizedBox()));
  });

  testWidgets('the mark is clearly visible', (tester) async {
    await tester.pumpWidget(
      _host(const StudentWatermark(name: 'Sara', password: 'x')),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('Sara'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, greaterThanOrEqualTo(0.8));
    await tester.pumpWidget(_host(const SizedBox()));
  });
}
