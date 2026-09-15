/// Registration-only package.
///
/// The player talks to the native side over the same MethodChannel names it
/// uses on Android (`com.lockclass/anti_capture`, `/amo_stream`,
/// `/audio_output`, `/storage`), so there is no Dart API here — depending on this package
/// is what links the Apple implementation into the app.
library;
