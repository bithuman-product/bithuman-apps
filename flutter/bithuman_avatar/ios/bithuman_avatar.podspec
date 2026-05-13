# bithuman_avatar — iOS native podspec.
#
# Vendors libessence + all C++ deps from the sibling bithuman-sdk repo.
# Static .a archives are referenced by build-setting path
# ($(PODS_TARGET_SRCROOT)/.../...) inside OTHER_LDFLAGS — NOT via
# vendored_libraries — because CocoaPods does not validate paths that
# use Xcode build variables at install time. The libs only need to
# exist at xcodebuild time.
#
# Workspace assumption (sibling repos under ~/bithuman):
#   ~/bithuman/bithuman-apps/flutter/bithuman_avatar/   ← this plugin
#   ~/bithuman/bithuman-sdk/cpp/                        ← libessence sources + prebuilt libs
#
# Apache-2.0; (c) bitHuman.

Pod::Spec.new do |s|
  s.name             = 'bithuman_avatar'
  s.version          = '0.0.1'
  s.summary          = 'bitHuman avatar Flutter plugin'
  s.description      = 'Real-time avatar rendering + OpenAI Realtime chat (iOS/macOS/Android)'
  s.homepage         = 'https://bithuman.ai'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'bitHuman' => 'hello@bithuman.ai' }
  s.source           = { :http => 'https://github.com/bithuman-product/bithuman-apps' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'
  # The bithuman_avatar.framework references libessence symbols (via the
  # static .a files). A dynamic framework would need every symbol resolved
  # at framework link time, but we want the final app to link them. Make
  # the framework static so unresolved symbols carry through to the app.
  s.static_framework = true

  # CLibessence module map lives at Classes/CLibessence/module.modulemap.
  # We DON'T use s.module_map (that would override the pod's own Swift
  # module map). Instead inject -fmodule-map-file= via OTHER_SWIFT_FLAGS
  # below so `import CLibessence` works AND the Swift plugin still gets
  # its auto-generated module map.
  s.preserve_paths   = 'Classes/CLibessence/**/*'

  # onnxruntime.xcframework — symlinked from the sibling bithuman-sdk repo
  # into Frameworks/. CocoaPods only accepts relative paths inside
  # vendored_frameworks.
  s.vendored_frameworks = 'Frameworks/onnxruntime.xcframework'

  # ----------------------------------------------------------------
  # Per-SDK linker flags. We resolve the .a paths to absolutes at
  # podspec eval time. Inside pod_target_xcconfig we use
  # $(PODS_TARGET_SRCROOT)/Vendor (the symlink tree) — CocoaPods does
  # NOT rewrite that. Inside user_target_xcconfig we substitute the
  # absolute path (PODS_TARGET_SRCROOT isn't defined on the Runner
  # target, so the build-setting variable doesn't expand there).
  # ----------------------------------------------------------------
  be_cpp     = '$(PODS_TARGET_SRCROOT)/Vendor'
  be_cpp_abs = File.expand_path('Vendor', __dir__)

  common_frameworks =
    '-lz -liconv -lc++ ' \
    '-framework Foundation -framework CoreML -framework CoreFoundation ' \
    '-framework Accelerate -framework VideoToolbox -framework AudioToolbox ' \
    '-framework CoreMedia -framework CoreVideo -framework UIKit'

  # NB: -force_load on libavcodec.a is required so the FFmpeg parser
  # registry (h264_parser etc., registered via static initializers) doesn't
  # get dead-stripped by ld --gc-sections. Without it,
  # avformat_find_stream_info populates codecpar but width/height stay 0
  # and libessence's H264Decoder fails with "invalid codec dimensions".
  iphoneos_libs =
    "#{be_cpp}/build-ios/Release-iphoneos/libessence.a " \
    "#{be_cpp}/third_party/webp-ios/lib/iphoneos/libwebp.a " \
    "#{be_cpp}/third_party/jpeg-turbo-ios/lib/iphoneos/libjpeg.a " \
    "#{be_cpp}/third_party/hdf5-ios/lib/iphoneos/libhdf5_hl.a " \
    "#{be_cpp}/third_party/hdf5-ios/lib/iphoneos/libhdf5.a " \
    "-force_load #{be_cpp}/third_party/ffmpeg-ios/lib/iphoneos/libavformat.a " \
    "-force_load #{be_cpp}/third_party/ffmpeg-ios/lib/iphoneos/libavcodec.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphoneos/libswscale.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphoneos/libswresample.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphoneos/libavutil.a"

  iphonesim_libs =
    "#{be_cpp}/build-ios-sim/Release-iphonesimulator/libessence.a " \
    "#{be_cpp}/third_party/webp-ios/lib/iphonesimulator/libwebp.a " \
    "#{be_cpp}/third_party/webp-ios/lib/iphonesimulator/libsharpyuv.a " \
    "#{be_cpp}/third_party/jpeg-turbo-ios/lib/iphonesimulator/libjpeg.a " \
    "#{be_cpp}/third_party/hdf5-ios/lib/iphonesimulator/libhdf5_hl.a " \
    "#{be_cpp}/third_party/hdf5-ios/lib/iphonesimulator/libhdf5.a " \
    "-force_load #{be_cpp}/third_party/ffmpeg-ios/lib/iphonesimulator/libavformat.a " \
    "-force_load #{be_cpp}/third_party/ffmpeg-ios/lib/iphonesimulator/libavcodec.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphonesimulator/libswscale.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphonesimulator/libswresample.a " \
    "#{be_cpp}/third_party/ffmpeg-ios/lib/iphonesimulator/libavutil.a"

  # Pod-target xcconfig: applies to the bithuman_avatar pod build itself.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                       => 'YES',
    # libessence.a sim slice is arm64-only — Xcode/Flutter sometimes tries a
    # fat x86_64+arm64 sim build which fails linking on Apple Silicon hosts.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'HEADER_SEARCH_PATHS'                  => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/CLibessence',
    'SWIFT_INCLUDE_PATHS'                  => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/CLibessence',
    # Make `import CLibessence` resolve from Swift without overriding the
    # pod's own auto-generated Swift module map.
    'OTHER_SWIFT_FLAGS'                    => '$(inherited) -Xcc -fmodule-map-file=$(PODS_TARGET_SRCROOT)/Classes/CLibessence/module.modulemap',
    'CLANG_CXX_LANGUAGE_STANDARD'          => 'c++17',
    'CLANG_CXX_LIBRARY'                    => 'libc++',
    'ENABLE_BITCODE'                       => 'NO',
  }

  # User-target xcconfig: applies to the consuming app (Runner) target so
  # its final link step pulls in libessence + all C++ deps. Without this,
  # the app would link bithuman_avatar.framework but every libessence
  # symbol the Swift code references would be undefined.
  iphoneos_libs_abs  = iphoneos_libs.gsub(be_cpp, be_cpp_abs)
  iphonesim_libs_abs = iphonesim_libs.gsub(be_cpp, be_cpp_abs)
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]'        => "$(inherited) #{iphoneos_libs_abs} #{common_frameworks}",
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => "$(inherited) #{iphonesim_libs_abs} #{common_frameworks}",
    # Propagate the arch restriction so the example app target doesn't
    # try to build a fat x86_64+arm64 sim slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
  }
end
