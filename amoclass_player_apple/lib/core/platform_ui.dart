import 'dart:io' show Platform;

/// Which platform conventions this build should follow.
///
/// One Flutter target serves both Apple platforms, but they are not one device
/// class: iOS is a touch phone and macOS is a windowed desktop. Rather than
/// scatter `Platform.isMacOS` through the widget tree, capabilities are named
/// here by what they mean for the UI, so a screen asks "can I lock the
/// orientation" rather than "am I on a Mac".
class PlatformUi {
  const PlatformUi._();

  /// A windowed desktop: mouse, keyboard, resizable window, no orientation.
  static bool get isDesktop => Platform.isMacOS;

  /// A handheld touch device: fixed screen, rotation, system chrome overlays.
  static bool get isMobile => Platform.isIOS;

  /// Whether `SystemChrome.setPreferredOrientations` and
  /// `setEnabledSystemUIMode` mean anything.
  ///
  /// On macOS they are silently ignored at best; forcing landscape on a desktop
  /// window is meaningless, and immersive mode has no counterpart.
  static bool get supportsOrientationLock => isMobile;

  /// Whether the player should offer pinch/scroll zoom and keyboard shortcuts.
  ///
  /// These came from the Windows player and belong to a pointer-and-keyboard
  /// machine. On a phone the double-tap skip zones cover the same ground.
  static bool get supportsPointerAndKeyboard => isDesktop;
}
