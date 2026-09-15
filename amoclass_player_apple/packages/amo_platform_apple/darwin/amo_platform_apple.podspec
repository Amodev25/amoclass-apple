#
# Shared iOS + macOS pod for the Lockclass player's platform layer.
# One `darwin/` source tree serves both platforms (sharedDarwinSource).
#
Pod::Spec.new do |s|
  s.name             = 'amo_platform_apple'
  s.version          = '0.0.1'
  s.summary          = 'Lockclass player platform channels and in-process decryption for Apple platforms.'
  s.description      = <<-DESC
Implements the anti-capture, audio output, storage and amo://
stream channels on iOS and macOS, plus the C AES-256-CTR decryptor that mpv
reads through.
                       DESC
  s.homepage         = 'https://github.com/Amodev25/amoclass-apple'
  # Proprietary — see ../LICENSE. Not an open-source licence.
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = { 'Lockclass' => 'https://github.com/Amodev25' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.{h,m,c}'
  s.public_header_files = 'Classes/AmoPlatformPlugin.h'

  # Required-reason API declarations for this plugin's own code.
  s.resource_bundles = {
    'amo_platform_apple_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  # Matches the app (IPHONEOS_DEPLOYMENT_TARGET = 13.0). The capture shield
  # relies on UIWindowScene, which does not exist below iOS 13.
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.osx.frameworks = 'Cocoa', 'CoreAudio', 'IOKit', 'Security'
  s.ios.frameworks = 'UIKit', 'AVFoundation', 'Security'

  # 64-bit file offsets, matching the Android CMake build.
  s.compiler_flags = '-D_FILE_OFFSET_BITS=64'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
