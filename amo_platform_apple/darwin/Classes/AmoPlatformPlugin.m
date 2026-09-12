#import "AmoPlatformPlugin.h"
#import "amo_stream_apple.h"

#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#else
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#endif

static NSString *const kAntiCaptureChannel = @"com.amoplayer/anti_capture";
static NSString *const kFocusChannel       = @"com.amoplayer/focus_mode";
static NSString *const kStreamChannel      = @"com.amoplayer/amo_stream";
static NSString *const kAudioChannel       = @"com.amoplayer/audio_output";

/* Keychain account under which the persistent device id is stored. Unlike
   identifierForVendor, a Keychain item survives app deletion, so a licence
   stays bound to the same device across a reinstall. */
static NSString *const kDeviceIdService = @"com.amoplayer.deviceid";
static NSString *const kDeviceIdAccount = @"device_id";

@interface AmoPlatformPlugin ()
@property(nonatomic, weak) NSObject<FlutterPluginRegistrar> *registrar;
#if TARGET_OS_OSX
@property(nonatomic, assign) NSApplicationPresentationOptions savedPresentationOptions;
@property(nonatomic, assign) BOOL focusLocked;
#else
@property(nonatomic, strong) UIView *captureShield;
@property(nonatomic, assign) BOOL captureObserverInstalled;
#endif
@end

@implementation AmoPlatformPlugin

#pragma mark - Registration

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  AmoPlatformPlugin *instance = [[AmoPlatformPlugin alloc] init];
  instance.registrar = registrar;

  NSObject<FlutterBinaryMessenger> *messenger = [registrar messenger];

  for (NSString *name in @[ kAntiCaptureChannel, kFocusChannel,
                            kStreamChannel, kAudioChannel ]) {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:name binaryMessenger:messenger];
    [registrar addMethodCallDelegate:instance channel:channel];
  }
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *m = call.method;

  /* ── Anti-capture channel ─────────────────────────────────────────────── */
  if ([m isEqualToString:@"enableProtection"]) {
    result(@([self enableProtection]));
  } else if ([m isEqualToString:@"disableProtection"]) {
    result(@([self disableProtection]));
  } else if ([m isEqualToString:@"getDeviceId"]) {
    result([self deviceId]);

  /* ── AMO stream channel (in-process decryption) ───────────────────────── */
  } else if ([m isEqualToString:@"registerProtocol"]) {
    NSNumber *handle = call.arguments[@"mpvHandle"];
    if (handle == nil) {
      result([FlutterError errorWithCode:@"REGISTER_FAILED"
                                 message:@"mpvHandle is missing"
                                 details:nil]);
      return;
    }
    int ret = amo_register_protocol((int64_t)[handle longLongValue]);
    result(@(ret == 0));
  } else if ([m isEqualToString:@"setCredentials"]) {
    NSString *credential = call.arguments[@"credential"];
    NSString *courseSecret = call.arguments[@"courseSecret"];
    if (credential == nil || courseSecret == nil) {
      result([FlutterError errorWithCode:@"CREDENTIALS_FAILED"
                                 message:@"credential or courseSecret is missing"
                                 details:nil]);
      return;
    }
    amo_apple_set_credentials([credential UTF8String], [courseSecret UTF8String]);
    result(nil);
  } else if ([m isEqualToString:@"clearCredentials"]) {
    amo_apple_clear_credentials();
    result(nil);

  /* ── Audio output channel ─────────────────────────────────────────────── */
  } else if ([m isEqualToString:@"headphonesConnected"]) {
    result(@([self headphonesConnected]));

  /* ── Focus mode channel ───────────────────────────────────────────────── */
  } else if ([m isEqualToString:@"startLockTask"]) {
    result(@([self startLock]));
  } else if ([m isEqualToString:@"stopLockTask"]) {
    result(@([self stopLock]));
  } else if ([m isEqualToString:@"emergencyStart"]) {
    [self stopLock];
    result(@(YES));
  } else if ([m isEqualToString:@"emergencyEnd"]) {
    result(@([self startLock]));

  /* Do Not Disturb cannot be toggled programmatically on either Apple
     platform — mirror the Windows player, which also reports no support. */
  } else if ([m isEqualToString:@"hasDndPermission"]) {
    result(@(NO));
  } else if ([m isEqualToString:@"enableDnd"] ||
             [m isEqualToString:@"disableDnd"] ||
             [m isEqualToString:@"requestDndPermission"]) {
    result(nil);

  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - Device id (Keychain-backed, survives reinstall)

- (NSString *)deviceId {
  NSDictionary *query = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : kDeviceIdService,
    (__bridge id)kSecAttrAccount : kDeviceIdAccount,
    (__bridge id)kSecReturnData : @YES,
    (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
  };

  CFTypeRef found = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
  if (status == errSecSuccess && found != NULL) {
    NSData *data = (__bridge_transfer NSData *)found;
    NSString *existing = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
    if (existing.length > 0) return existing;
  }

#if TARGET_OS_OSX
  NSString *generated = [self platformUUID];
#else
  NSString *generated = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
#endif
  if (generated.length == 0) generated = [[NSUUID UUID] UUIDString];

  NSDictionary *add = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : kDeviceIdService,
    (__bridge id)kSecAttrAccount : kDeviceIdAccount,
    (__bridge id)kSecValueData : [generated dataUsingEncoding:NSUTF8StringEncoding],
    (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
  };
  SecItemDelete((__bridge CFDictionaryRef)add);
  SecItemAdd((__bridge CFDictionaryRef)add, NULL);

  return generated;
}

#if TARGET_OS_OSX
/** Hardware UUID of the Mac — the closest analogue to Android's ANDROID_ID. */
- (NSString *)platformUUID {
  /* kIOMainPortDefault is macOS 12+; kIOMasterPortDefault is the older
     spelling, deprecated but still present. Both are MACH_PORT_NULL.
     Select on the DEPLOYMENT TARGET, not the SDK: building with a current SDK
     against a 10.15 target must still emit the old symbol, or the app links
     against something that does not exist on the OS it claims to support. */
#if defined(MAC_OS_VERSION_12_0) && __MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_VERSION_12_0
  mach_port_t mainPort = kIOMainPortDefault;
#else
  mach_port_t mainPort = kIOMasterPortDefault;
#endif
  io_service_t service = IOServiceGetMatchingService(
      mainPort, IOServiceMatching("IOPlatformExpertDevice"));
  if (!service) return @"";

  CFStringRef uuid = (CFStringRef)IORegistryEntryCreateCFProperty(
      service, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
  IOObjectRelease(service);
  if (!uuid) return @"";

  return (__bridge_transfer NSString *)uuid;
}
#endif


#pragma mark - Anti-capture

#if TARGET_OS_OSX

/**
 * macOS has a true equivalent of Android's FLAG_SECURE:
 * NSWindowSharingNone excludes the window from screen sharing and from
 * screen recording APIs, so the window is not captured at all.
 */
- (BOOL)enableProtection {
  NSWindow *window = [[self.registrar view] window];
  if (window == nil) return NO;
  window.sharingType = NSWindowSharingNone;
  return YES;
}

- (BOOL)disableProtection {
  NSWindow *window = [[self.registrar view] window];
  if (window == nil) return NO;
  window.sharingType = NSWindowSharingReadOnly;
  return YES;
}

#else

/**
 * iOS has NO equivalent of FLAG_SECURE — a screenshot or screen recording
 * cannot be blocked. The only mitigation the platform offers is detection:
 * UIScreen.isCaptured reports when the screen is being recorded or mirrored,
 * so cover the window while that is true.
 *
 * This is materially weaker than Android: the recording is not prevented, and
 * frames may leak in the instant before the shield is applied. It is the
 * standard iOS approach and the best available.
 */
- (BOOL)enableProtection {
  if (self.captureObserverInstalled) {
    [self applyCaptureShield];
    return YES;
  }

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(captureStateChanged:)
             name:UIScreenCapturedDidChangeNotification
           object:nil];
  self.captureObserverInstalled = YES;
  [self applyCaptureShield];
  return YES;
}

- (BOOL)disableProtection {
  if (self.captureObserverInstalled) {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:UIScreenCapturedDidChangeNotification
                object:nil];
    self.captureObserverInstalled = NO;
  }
  [self.captureShield removeFromSuperview];
  self.captureShield = nil;
  return YES;
}

- (void)captureStateChanged:(NSNotification *)note {
  [self applyCaptureShield];
}

- (UIWindow *)keyWindow {
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w.isKeyWindow) return w;
    }
  }
  return nil;
}

/** Cover the window whenever the screen is being captured, uncover when not. */
- (void)applyCaptureShield {
  UIWindow *window = [self keyWindow];
  if (window == nil) return;

  BOOL captured = [UIScreen mainScreen].isCaptured;
  if (!captured) {
    [self.captureShield removeFromSuperview];
    self.captureShield = nil;
    return;
  }

  if (self.captureShield.superview == window) return;

  UIView *shield = [[UIView alloc] initWithFrame:window.bounds];
  shield.backgroundColor = [UIColor blackColor];
  shield.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  UILabel *label = [[UILabel alloc] initWithFrame:shield.bounds];
  label.text = @"تسجيل الشاشة غير مسموح";
  label.textColor = [UIColor whiteColor];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [shield addSubview:label];

  [window addSubview:shield];
  self.captureShield = shield;
}

#endif

#pragma mark - Focus mode

#if TARGET_OS_OSX

/**
 * macOS kiosk mode. This is weaker than Android's lock task: it hides the Dock
 * and menu bar and blocks Cmd+Tab, force quit and log-out, but the app must
 * NOT be sandboxed for DisableProcessSwitching to take effect.
 */
- (BOOL)startLock {
  if (self.focusLocked) return YES;
  self.savedPresentationOptions = [NSApplication sharedApplication].presentationOptions;
  @try {
    [NSApplication sharedApplication].presentationOptions =
        NSApplicationPresentationHideDock |
        NSApplicationPresentationHideMenuBar |
        NSApplicationPresentationDisableProcessSwitching |
        NSApplicationPresentationDisableForceQuit |
        NSApplicationPresentationDisableSessionTermination |
        NSApplicationPresentationDisableHideApplication;
  } @catch (NSException *e) {
    return NO;
  }
  self.focusLocked = YES;
  return YES;
}

- (BOOL)stopLock {
  if (!self.focusLocked) return YES;
  @try {
    [NSApplication sharedApplication].presentationOptions = self.savedPresentationOptions;
  } @catch (NSException *e) {
    return NO;
  }
  self.focusLocked = NO;
  return YES;
}

#else

/**
 * iOS cannot pin an app programmatically. Guided Access is switched on by the
 * user, and Single App Mode needs a supervised device under MDM — neither is
 * something an App Store app can trigger. Report failure honestly so the Dart
 * layer can hide the feature rather than pretend it locked.
 */
- (BOOL)startLock { return NO; }
- (BOOL)stopLock  { return NO; }

#endif

#pragma mark - Headphone detection

/* Both implementations fail OPEN — on any error they report YES, so a
   detection problem never wrongly blocks a student from their content. This
   mirrors the Android behaviour. */

#if TARGET_OS_OSX

- (BOOL)headphonesConnected {
  AudioDeviceID deviceID = kAudioObjectUnknown;
  UInt32 size = sizeof(deviceID);
  AudioObjectPropertyAddress defaultOut = {
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };

  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultOut,
                                 0, NULL, &size, &deviceID) != noErr) {
    return YES;
  }
  if (deviceID == kAudioObjectUnknown) return YES;

  UInt32 transport = 0;
  size = sizeof(transport);
  AudioObjectPropertyAddress transportAddr = {
      kAudioDevicePropertyTransportType,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };

  if (AudioObjectGetPropertyData(deviceID, &transportAddr,
                                 0, NULL, &size, &transport) != noErr) {
    return YES;
  }

  return transport == kAudioDeviceTransportTypeBluetooth ||
         transport == kAudioDeviceTransportTypeBluetoothLE ||
         transport == kAudioDeviceTransportTypeUSB;
}

#else

- (BOOL)headphonesConnected {
  AVAudioSessionRouteDescription *route =
      [[AVAudioSession sharedInstance] currentRoute];
  if (route == nil) return YES;

  for (AVAudioSessionPortDescription *output in route.outputs) {
    NSString *type = output.portType;
    if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
        [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortUSBAudio]) {
      return YES;
    }
  }
  return NO;
}

#endif

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
