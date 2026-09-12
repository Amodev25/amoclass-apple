#
# Shared iOS + macOS pod for the AMO player's platform layer.
# One `darwin/` source tree serves both platforms (sharedDarwinSource).
#
Pod::Spec.new do |s|
  s.name             = 'amo_platform_apple'
  s.version          = '0.0.1'
  s.summary          = 'AMO player platform channels and in-process decryption for Apple platforms.'
  s.description      = <<-DESC
Implements the anti-capture, focus mode, audio output and amo:// stream
channels on iOS and macOS, plus the C AES-256-CTR decryptor that mpv reads
through.
                       DESC
  s.homepage         = 'https://amoclass.local'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AMO' => 'dev@amoclass.local' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.{h,m,c}'
  s.public_header_files = 'Classes/AmoPlatformPlugin.h'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '12.0'
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
