import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/core/app_build.dart';

/// The worker refuses an app whose X-Lockclass-Build is below MIN_APP_BUILD.
/// If kAppBuild is not bumped together with pubspec.yaml, a release would
/// claim to be an older build than it is — and be locked out the moment the
/// server raises the minimum to the version that fixed something.
void main() {
  test('kAppBuild equals the +N build number in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*[^\s+]+\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml version has no +build part');
    expect(kAppBuild, int.parse(match!.group(1)!));
  });

  test('the header carries the build number as a plain integer', () {
    expect(kAppBuildHeaders[kAppBuildHeader], '$kAppBuild');
    expect(int.tryParse(kAppBuildHeaders[kAppBuildHeader]!), kAppBuild);
  });
}
