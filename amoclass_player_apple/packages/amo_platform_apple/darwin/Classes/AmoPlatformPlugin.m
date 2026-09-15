#import "AmoPlatformPlugin.h"
#import "amo_stream_apple.h"

#import <TargetConditionals.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#else
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#endif

static NSString *const kAntiCaptureChannel = @"com.lockclass/anti_capture";
static NSString *const kStreamChannel      = @"com.lockclass/amo_stream";
static NSString *const kAudioChannel       = @"com.lockclass/audio_output";
static NSString *const kStorageChannel     = @"com.lockclass/storage";

/* Keychain item holding the persistent device id. Unlike identifierForVendor,
   a Keychain item survives app deletion, so a licence stays bound to the same
   device across a reinstall.

   The account is versioned: v2 items are written with
   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, which keeps them out of
   backups restored onto ANOTHER device (a plain AfterFirstUnlock item would
   travel with an encrypted backup and clone the seat binding). Renaming the
   account is what makes every installation get a correctly-protected item
   instead of silently keeping the old one. */
static NSString *const kDeviceIdService = @"com.lockclass.deviceid";
static NSString *const kDeviceIdAccount = @"device_id.v2";

#if TARGET_OS_OSX
/* App-specific salt for the Mac hardware id. IOPlatformUUID is readable by any
   process on the Mac, so it is never sent raw: the server only ever sees
   SHA-256(salt || uuid), which is stable for this app and useless to anyone
   correlating the machine across other services. */
static NSString *const kMacIdSalt = @"com.lockclass.player/device-id/v1:";
#else
/* Fallback for the capture shield when Dart did not pass a localized string. */
static NSString *const kDefaultShieldMessage = @"Screen recording is not allowed";
#endif

#pragma mark - Argument checking

/* Flutter delivers a Dart null as NSNull, and `arguments` itself may be nil or
   not a dictionary at all. Nothing below trusts the shape of a call: every
   argument goes through these, and a wrong type becomes a FlutterError rather
   than an unrecognized-selector crash. */

static BOOL AmoArgPresent(FlutterMethodCall *call, NSString *key) {
  id args = call.arguments;
  if (![args isKindOfClass:[NSDictionary class]]) return NO;
  id value = ((NSDictionary *)args)[key];
  return value != nil && value != (id)[NSNull null];
}

static id AmoArg(FlutterMethodCall *call, NSString *key, Class cls) {
  if (!AmoArgPresent(call, key)) return nil;
  id value = ((NSDictionary *)call.arguments)[key];
  return [value isKindOfClass:cls] ? value : nil;
}

static FlutterError *AmoBadArgument(NSString *method, NSString *key, NSString *type) {
  return [FlutterError
      errorWithCode:@"BAD_ARGUMENT"
            message:[NSString stringWithFormat:@"%@: argument '%@' must be a non-null %@",
                                               method, key, type]
            details:nil];
}

#if TARGET_OS_OSX
static NSString *AmoSha256Hex(NSString *input) {
  NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}
#endif

@interface AmoPlatformPlugin ()
@property(nonatomic, weak) NSObject<FlutterPluginRegistrar> *registrar;
#if TARGET_OS_OSX
@property(nonatomic, assign) BOOL protectionWanted;
@property(nonatomic, assign) BOOL windowObserversInstalled;
#else
@property(nonatomic, strong) UIView *captureShield;
@property(nonatomic, strong) UILabel *captureLabel;
@property(nonatomic, copy) NSString *shieldMessage;
@property(nonatomic, assign) BOOL protectionWanted;
@property(nonatomic, assign) BOOL captureObserversInstalled;
#endif
@end

@implementation AmoPlatformPlugin

#pragma mark - Registration

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  AmoPlatformPlugin *instance = [[AmoPlatformPlugin alloc] init];
  instance.registrar = registrar;

  NSObject<FlutterBinaryMessenger> *messenger = [registrar messenger];

  for (NSString *name in @[ kAntiCaptureChannel, kStreamChannel,
                            kAudioChannel, kStorageChannel ]) {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:name binaryMessenger:messenger];
    [registrar addMethodCallDelegate:instance channel:channel];
  }
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *m = call.method;

  /* ── Anti-capture channel ─────────────────────────────────────────────── */
  if ([m isEqualToString:@"enableProtection"]) {
    NSString *message = nil;
    if (AmoArgPresent(call, @"message")) {
      message = AmoArg(call, @"message", [NSString class]);
      if (message == nil) {
        result(AmoBadArgument(m, @"message", @"String"));
        return;
      }
    }
    result(@([self enableProtectionWithMessage:message]));
  } else if ([m isEqualToString:@"disableProtection"]) {
    result(@([self disableProtection]));
  } else if ([m isEqualToString:@"isProtected"]) {
    result(@([self isProtected]));
  } else if ([m isEqualToString:@"getDeviceId"]) {
    NSString *deviceId = [self deviceId];
    result(deviceId ?: [NSNull null]);

  /* ── AMO stream channel (in-process decryption) ───────────────────────── */
  } else if ([m isEqualToString:@"registerProtocol"]) {
    NSNumber *handle = AmoArg(call, @"mpvHandle", [NSNumber class]);
    if (handle == nil) {
      result(AmoBadArgument(m, @"mpvHandle", @"int"));
      return;
    }
    int ret = amo_register_protocol((int64_t)[handle longLongValue]);
    /* numberWithBool, not @(ret == 0): a C comparison is an int, which the
       channel sends as an int and Dart's invokeMethod<bool> refuses. */
    result([NSNumber numberWithBool:(ret == 0)]);
  } else if ([m isEqualToString:@"setContentKey"]) {
    NSString *contentKey = AmoArg(call, @"contentKey", [NSString class]);
    if (contentKey == nil) {
      /* A failed set must not leave the previous course's key usable. */
      amo_apple_clear_content_key();
      result(AmoBadArgument(m, @"contentKey", @"String"));
      return;
    }
    int ok = amo_apple_set_content_key([contentKey UTF8String]);
    result([NSNumber numberWithBool:(ok == 1)]);
  } else if ([m isEqualToString:@"clearContentKey"]) {
    amo_apple_clear_content_key();
    result(nil);

  /* ── Audio output channel ─────────────────────────────────────────────── */
  } else if ([m isEqualToString:@"headphonesConnected"]) {
    result(@([self headphonesConnected]));

  /* ── Storage channel ──────────────────────────────────────────────────── */
  } else if ([m isEqualToString:@"freeBytes"]) {
    NSString *path = AmoArg(call, @"path", [NSString class]);
    if (path == nil) {
      result(AmoBadArgument(m, @"path", @"String"));
      return;
    }
    result([self freeBytesAtPath:path]);
  } else if ([m isEqualToString:@"excludeFromBackup"]) {
    NSString *path = AmoArg(call, @"path", [NSString class]);
    if (path == nil) {
      result(AmoBadArgument(m, @"path", @"String"));
      return;
    }
    result(@([self excludeFromBackupAtPath:path]));

  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - Storage

/* Bytes an import or download may use on the volume holding `path`, or NSNull
   when it cannot be told. On iOS the "important usage" figure is the honest
   one: it counts space the system would purge (caches, offloadable apps) to
   make room for something the user asked for, which the plain free-size
   figure does not. The Dart side treats NSNull as "unknown" and proceeds.

   Required-reason API (disk space, E174.1): used only to check there is room
   before writing a file. Declared in Resources/PrivacyInfo.xcprivacy. */
- (id)freeBytesAtPath:(NSString *)path {
  if (path.length == 0) return [NSNull null];
  NSURL *url = [NSURL fileURLWithPath:path];
  NSDictionary *values =
      [url resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ]
                           error:nil];
  NSNumber *important = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
  if ([important isKindOfClass:[NSNumber class]] && important.longLongValue > 0) {
    return important;
  }

  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
  NSNumber *free = attrs[NSFileSystemFreeSize];
  return [free isKindOfClass:[NSNumber class]] ? free : [NSNull null];
}

/* Course content (downloads, imports, previews) is re-downloadable and bound
   to this device's seat, so it has no business in an iCloud backup (iOS) or a
   Time Machine snapshot (macOS). Set on the content directories when they are
   created; the flag applies to everything beneath them. */
- (BOOL)excludeFromBackupAtPath:(NSString *)path {
  if (path.length == 0) return NO;
  BOOL isDirectory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
    return NO;
  }
  NSURL *url = [NSURL fileURLWithPath:path isDirectory:isDirectory];
  NSError *error = nil;
  BOOL ok = [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error];
  if (!ok) {
    NSLog(@"[AmoPlatform] could not exclude %@ from backup: %@", path, error);
  }
  return ok;
}

#pragma mark - Device id (Keychain-backed, survives reinstall)

- (NSDictionary *)deviceIdBaseQuery {
  return @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : kDeviceIdService,
    (__bridge id)kSecAttrAccount : kDeviceIdAccount,
  };
}

/* Returns the device id, or nil when none can be produced — the Dart side then
   uses its own persisted random id. Never returns the literal "unknown". */
- (NSString *)deviceId {
  NSMutableDictionary *query = [[self deviceIdBaseQuery] mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

  CFTypeRef found = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
  if (status == errSecSuccess && found != NULL) {
    NSData *data = (__bridge_transfer NSData *)found;
    NSString *existing = [data isKindOfClass:[NSData class]]
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : nil;
    if (existing.length > 0) return existing;
  } else if (found != NULL) {
    CFRelease(found);
  }

  NSString *stable = [self stableHardwareId];

  if (status != errSecSuccess && status != errSecItemNotFound) {
    /* The item may well exist but be unreadable right now (for example
       errSecInteractionNotAllowed before the first unlock after a reboot).
       Overwriting it would re-bind the seat, so do not touch it. */
    NSLog(@"[AmoPlatform] device id keychain read failed: %d", (int)status);
    return stable;
  }

  NSString *generated = stable ?: [[NSUUID UUID] UUIDString];
  NSData *value = [generated dataUsingEncoding:NSUTF8StringEncoding];

  NSMutableDictionary *add = [[self deviceIdBaseQuery] mutableCopy];
  add[(__bridge id)kSecValueData] = value;
  add[(__bridge id)kSecAttrAccessible] =
      (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;

  /* Only reached with no item, or an item holding empty data. */
  SecItemDelete((__bridge CFDictionaryRef)[self deviceIdBaseQuery]);
  OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (addStatus != errSecSuccess) {
    NSLog(@"[AmoPlatform] device id keychain write failed: %d", (int)addStatus);
    /* A hardware-derived id is the same on the next launch even without the
       keychain; a random one is not, so hand that case to Dart, which keeps
       its own persisted copy. */
    return stable;
  }
  return generated;
}

#if TARGET_OS_OSX
/** SHA-256 of an app salt and the Mac's hardware UUID, as 64 hex digits. */
- (NSString *)stableHardwareId {
  NSString *uuid = [self platformUUID];
  if (uuid.length == 0) return nil;
  return AmoSha256Hex([kMacIdSalt stringByAppendingString:uuid]);
}

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

  CFTypeRef uuid = IORegistryEntryCreateCFProperty(
      service, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
  IOObjectRelease(service);
  if (!uuid) return @"";
  if (CFGetTypeID(uuid) != CFStringGetTypeID()) {
    CFRelease(uuid);
    return @"";
  }
  return (__bridge_transfer NSString *)uuid;
}
#else
/** identifierForVendor — nil until the device has been unlocked once. */
- (NSString *)stableHardwareId {
  return [[[UIDevice currentDevice] identifierForVendor] UUIDString];
}
#endif


#pragma mark - Anti-capture

#if TARGET_OS_OSX

/**
 * macOS has a true equivalent of Android's FLAG_SECURE:
 * NSWindowSharingNone excludes the window from screen sharing and from
 * screen recording APIs, so the window is not captured at all.
 *
 * Dart asks for protection before the first frame, when the Flutter view may
 * not be in a window yet. The request is therefore remembered, and re-applied
 * whenever the window becomes key/main or changes full-screen state. The
 * return value and `isProtected` report the window's real sharing type, never
 * the intent.
 */
- (NSWindow *)flutterWindow {
  return [[self.registrar view] window];
}

- (BOOL)applyProtectionToWindow {
  NSWindow *window = [self flutterWindow];
  if (window == nil) return NO;
  if (window.sharingType != NSWindowSharingNone) {
    window.sharingType = NSWindowSharingNone;
  }
  return window.sharingType == NSWindowSharingNone;
}

- (BOOL)enableProtectionWithMessage:(NSString *)message {
  (void)message; /* nothing to label: the window is simply not captured */
  self.protectionWanted = YES;
  [self installWindowObservers];
  return [self applyProtectionToWindow];
}

- (BOOL)disableProtection {
  self.protectionWanted = NO;
  NSWindow *window = [self flutterWindow];
  if (window == nil) return NO;
  window.sharingType = NSWindowSharingReadOnly;
  return YES;
}

- (BOOL)isProtected {
  NSWindow *window = [self flutterWindow];
  return window != nil && window.sharingType == NSWindowSharingNone;
}

- (void)installWindowObservers {
  if (self.windowObserversInstalled) return;
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  for (NSString *name in @[ NSWindowDidBecomeKeyNotification,
                            NSWindowDidBecomeMainNotification,
                            NSWindowDidEnterFullScreenNotification,
                            NSWindowDidExitFullScreenNotification ]) {
    [center addObserver:self
               selector:@selector(windowStateChanged:)
                   name:name
                 object:nil];
  }
  self.windowObserversInstalled = YES;
}

- (void)windowStateChanged:(NSNotification *)note {
  NSWindow *window = [self flutterWindow];
  if (window == nil || note.object != window) return;
  if (self.protectionWanted) [self applyProtectionToWindow];
}

#else

/**
 * iOS has NO equivalent of FLAG_SECURE — a screenshot or screen recording
 * cannot be blocked. The only mitigation the platform offers is detection:
 * the screen's `isCaptured` reports recording, AirPlay or mirroring, so cover
 * the window while that is true.
 *
 * This is materially weaker than Android: the recording is not prevented, and
 * frames may leak in the instant before the shield is applied. It is the
 * standard iOS approach and the best available.
 *
 * The state is checked when protection is enabled, whenever a window becomes
 * key, whenever the scene or app becomes active, and on every capture change —
 * a recording that was already running when the app launched or came back to
 * the foreground produces no "did change" notification at all.
 */
- (BOOL)enableProtectionWithMessage:(NSString *)message {
  if (message.length > 0) {
    self.shieldMessage = message;
    self.captureLabel.text = message;
  }
  self.protectionWanted = YES;
  [self installCaptureObservers];
  [self applyCaptureShield];
  return YES;
}

- (BOOL)disableProtection {
  self.protectionWanted = NO;
  if (self.captureObserversInstalled) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in [self captureNotificationNames]) {
      [center removeObserver:self name:name object:nil];
    }
    self.captureObserversInstalled = NO;
  }
  [self removeCaptureShield];
  return YES;
}

/* Prevention is not available on iOS; see AntiCapture.isSupported. */
- (BOOL)isProtected {
  return NO;
}

- (NSArray<NSString *> *)captureNotificationNames {
  return @[ UIScreenCapturedDidChangeNotification,
            UISceneDidActivateNotification,
            UIApplicationDidBecomeActiveNotification,
            UIWindowDidBecomeKeyNotification ];
}

- (void)installCaptureObservers {
  if (self.captureObserversInstalled) return;
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  for (NSString *name in [self captureNotificationNames]) {
    [center addObserver:self
               selector:@selector(captureStateChanged:)
                   name:name
                 object:nil];
  }
  self.captureObserversInstalled = YES;
}

- (void)captureStateChanged:(NSNotification *)note {
  (void)note;
  if ([NSThread isMainThread]) {
    [self applyCaptureShield];
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self applyCaptureShield];
    });
  }
}

/* The app's window, found through its scene (UIScreen.mainScreen and
   UIApplication.keyWindow are deprecated). Falls back to the app delegate's
   window for the moment before any scene window is key. */
- (UIWindow *)hostWindow {
  UIWindow *fallback = nil;
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w.isKeyWindow) return w;
      if (fallback == nil && !w.hidden) fallback = w;
    }
  }
  if (fallback != nil) return fallback;
  id<UIApplicationDelegate> delegate = [UIApplication sharedApplication].delegate;
  if ([delegate respondsToSelector:@selector(window)]) return delegate.window;
  return nil;
}

- (BOOL)screenIsCapturedForWindow:(UIWindow *)window {
  UIScreen *screen = window.windowScene.screen;
  if (screen != nil) return screen.isCaptured;
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    if (((UIWindowScene *)scene).screen.isCaptured) return YES;
  }
  return NO;
}

- (void)removeCaptureShield {
  [self.captureShield removeFromSuperview];
  self.captureShield = nil;
  self.captureLabel = nil;
}

/** Cover the window whenever the screen is being captured, uncover when not. */
- (void)applyCaptureShield {
  if (!self.protectionWanted) {
    [self removeCaptureShield];
    return;
  }
  UIWindow *window = [self hostWindow];
  if (window == nil) return;

  if (![self screenIsCapturedForWindow:window]) {
    [self removeCaptureShield];
    return;
  }

  if (self.captureShield.superview == window) {
    [window bringSubviewToFront:self.captureShield];
    return;
  }
  [self removeCaptureShield];

  UIView *shield = [[UIView alloc] initWithFrame:window.bounds];
  shield.backgroundColor = [UIColor blackColor];
  shield.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(shield.bounds, 24, 24)];
  label.text = self.shieldMessage.length > 0 ? self.shieldMessage : kDefaultShieldMessage;
  label.textColor = [UIColor whiteColor];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [shield addSubview:label];

  [window addSubview:shield];
  self.captureShield = shield;
  self.captureLabel = label;
}

#endif

#pragma mark - Headphone detection

/* Both implementations fail OPEN on an ERROR — if the output route cannot be
   read at all they report YES, so a detection problem never wrongly blocks a
   student from their content. This mirrors the Android behaviour. */

#if TARGET_OS_OSX

typedef NS_ENUM(NSInteger, AmoTerminalKind) {
  AmoTerminalUnknown = 0,
  AmoTerminalHeadphones,
  AmoTerminalSpeaker,
};

static BOOL AmoReadUInt32(AudioObjectID object, AudioObjectPropertySelector selector,
                          AudioObjectPropertyScope scope, UInt32 *out) {
  AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
  if (!AudioObjectHasProperty(object, &address)) return NO;
  UInt32 size = sizeof(UInt32);
  return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, out) == noErr;
}

static UInt32 AmoStreamCount(AudioObjectID device, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, scope,
                                        kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr) return 0;
  return size / sizeof(AudioStreamID);
}

/* kAudioStreamPropertyTerminalType carries either a USB Audio terminal type
   (0x0301 speaker, 0x0302 headphones, 0x0304 desktop speaker, 0x0305 room
   speaker, 0x0401 handset, 0x0402 headset) or Core Audio's four-char code. */
static AmoTerminalKind AmoOutputTerminalKind(AudioObjectID device) {
  AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams,
                                        kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr ||
      size < sizeof(AudioStreamID)) {
    return AmoTerminalUnknown;
  }
  AudioStreamID *streams = (AudioStreamID *)malloc(size);
  if (streams == NULL) return AmoTerminalUnknown;

  AmoTerminalKind kind = AmoTerminalUnknown;
  if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, streams) == noErr) {
    UInt32 count = size / sizeof(AudioStreamID);
    for (UInt32 i = 0; i < count; i++) {
      UInt32 terminal = 0;
      if (!AmoReadUInt32(streams[i], kAudioStreamPropertyTerminalType,
                         kAudioObjectPropertyScopeGlobal, &terminal)) {
        continue;
      }
      if (terminal == 0x0302 || terminal == 0x0401 || terminal == 0x0402 ||
          terminal == 'hdph') {
        kind = AmoTerminalHeadphones;
        break;
      }
      if (terminal == 0x0301 || terminal == 0x0304 || terminal == 0x0305 ||
          terminal == 'spkr') {
        kind = AmoTerminalSpeaker;
      }
    }
  }
  free(streams);
  return kind;
}

/**
 * Heuristic, by transport of the DEFAULT output device:
 *
 * - Bluetooth / Bluetooth LE: private listening → YES.
 * - Built-in: the headphone jack and the internal speakers are the same
 *   transport, so read the output data source: 'hdpn' (headphones) → YES,
 *   anything else ('ispk' internal speakers, line out) → NO. A built-in device
 *   without a data source falls back to the stream terminal type; if that says
 *   nothing either, it fails open (YES).
 * - USB: YES only when it looks like a headset or headphones — a
 *   headphone/headset/handset terminal type, or a device with both output and
 *   input streams (a USB headset carries a microphone). A USB DAC feeding
 *   desk speakers has neither and is NOT counted.
 * - HDMI, DisplayPort, Thunderbolt, AirPlay, aggregate, virtual and anything
 *   unknown: NO. Displays and receivers are loudspeakers, and virtual devices
 *   are exactly what a capture tool installs.
 */
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
  if (!AmoReadUInt32(deviceID, kAudioDevicePropertyTransportType,
                     kAudioObjectPropertyScopeGlobal, &transport)) {
    return YES;
  }

  switch (transport) {
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE:
      return YES;

    case kAudioDeviceTransportTypeBuiltIn: {
      UInt32 source = 0;
      if (AmoReadUInt32(deviceID, kAudioDevicePropertyDataSource,
                        kAudioObjectPropertyScopeOutput, &source)) {
        return source == 'hdpn';
      }
      return AmoOutputTerminalKind(deviceID) != AmoTerminalSpeaker;
    }

    case kAudioDeviceTransportTypeUSB:
      if (AmoOutputTerminalKind(deviceID) == AmoTerminalHeadphones) return YES;
      return AmoStreamCount(deviceID, kAudioObjectPropertyScopeOutput) > 0 &&
             AmoStreamCount(deviceID, kAudioObjectPropertyScopeInput) > 0;

    default:
      return NO;
  }
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
