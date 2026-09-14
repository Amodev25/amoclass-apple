import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/core/amo_native_bridge.dart';

/// The iOS simulator build logged "type 'int' is not a subtype of type 'bool?'"
/// on every setContentKey: Objective-C sent the result of `@(ok == 1)` as an
/// int. The key WAS stored, but the app read the failure as "no key" and
/// refused to open files.
void main() {
  test('a native yes arrives as a bool or as a non-zero number', () {
    expect(AmoNativeBridge.channelBool(true), isTrue);
    expect(AmoNativeBridge.channelBool(1), isTrue);
  });

  test('a native no, a missing reply or anything else is false', () {
    expect(AmoNativeBridge.channelBool(false), isFalse);
    expect(AmoNativeBridge.channelBool(0), isFalse);
    expect(AmoNativeBridge.channelBool(null), isFalse);
    expect(AmoNativeBridge.channelBool('true'), isFalse);
  });
}
