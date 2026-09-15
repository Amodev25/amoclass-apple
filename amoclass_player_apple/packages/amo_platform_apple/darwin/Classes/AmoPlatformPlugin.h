/**
 * AmoPlatformPlugin.h — the Apple side of the four platform channels the
 * player expects. The channel names and method names mirror the Android
 * MainActivity exactly, so the Dart code needs no changes.
 */

#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface AmoPlatformPlugin : NSObject <FlutterPlugin>
@end
