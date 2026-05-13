# bithuman_avatar — macOS native podspec.
#
# Links the macOS arm64 slice of libessence.a from the sibling
# bithuman-sdk repo + Homebrew-installed C++ deps at runtime via
# @rpath. Matches the pattern the `brew install bithuman` CLI uses.
#
# Workspace assumption:
#   ~/bithuman/bithuman-apps/flutter/bithuman_avatar/  ← this plugin
#   ~/bithuman/bithuman-sdk/cpp/                       ← sibling SDK repo with macOS libessence.a
#
# Homebrew runtime deps (the example app errors with a useful message
# if any are missing):
#   brew install onnxruntime hdf5 jpeg-turbo webp ffmpeg
#
# Apache-2.0; (c) bitHuman.

Pod::Spec.new do |s|
  s.name             = 'bithuman_avatar'
  s.version          = '0.0.1'
  s.summary          = 'bitHuman avatar Flutter plugin (macOS)'
  s.description      = 'Real-time avatar rendering + OpenAI Realtime chat'
  s.homepage         = 'https://bithuman.ai'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'bitHuman' => 'hello@bithuman.ai' }
  s.source           = { :http => 'https://github.com/bithuman-product/bithuman-apps' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '13.0'
  s.swift_version    = '5.9'
  s.static_framework = true
  # CLibessence module map lives under the iOS sibling so we can share the
  # header across iOS + macOS. Symlinked into the pod tree at install time.
  s.preserve_paths   = 'Classes/CLibessence/**/*'

  be_cpp     = '$(PODS_TARGET_SRCROOT)/Vendor'
  be_cpp_abs = File.expand_path('Vendor', __dir__)

  common_frameworks =
    '-lz -liconv -lc++ ' \
    '-framework Foundation -framework CoreML -framework CoreFoundation ' \
    '-framework Accelerate -framework VideoToolbox -framework AudioToolbox ' \
    '-framework CoreMedia -framework CoreVideo -framework AppKit'

  # Homebrew dylibs — link path + library names. The example app's xcconfig
  # also wires runtime DYLD_FRAMEWORK_PATH so the dylibs load at launch.
  brew_libs =
    '-L/opt/homebrew/lib ' \
    '-L/opt/homebrew/opt/onnxruntime/lib ' \
    '-L/opt/homebrew/opt/hdf5/lib ' \
    '-L/opt/homebrew/opt/jpeg-turbo/lib ' \
    '-L/opt/homebrew/opt/webp/lib ' \
    '-L/opt/homebrew/opt/ffmpeg/lib ' \
    '-lonnxruntime -lhdf5 -lhdf5_hl -ljpeg -lwebp -lsharpyuv ' \
    '-lavcodec -lavformat -lavutil -lswscale -lswresample'

  macos_libs = "#{be_cpp}/build/libessence.a"
  macos_libs_abs = "#{be_cpp_abs}/build/libessence.a"

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'              => 'YES',
    'HEADER_SEARCH_PATHS'         => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/CLibessence',
    'SWIFT_INCLUDE_PATHS'         => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/CLibessence',
    'OTHER_SWIFT_FLAGS'           => '$(inherited) -Xcc -fmodule-map-file=$(PODS_TARGET_SRCROOT)/Classes/CLibessence/module.modulemap',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
  }

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => "$(inherited) #{macos_libs_abs} #{brew_libs} #{common_frameworks}",
    # The Runner target needs to know about the CLibessence module map too
    # because bithuman_avatar.framework's swiftinterface references it
    # transitively. iOS gets away without this; macOS Swift is stricter.
    'OTHER_SWIFT_FLAGS' => "$(inherited) -Xcc -fmodule-map-file=#{File.expand_path('Classes/CLibessence/module.modulemap', __dir__)}",
    # Embed @rpath entries so the Homebrew dylibs resolve at run-time.
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) /opt/homebrew/lib /opt/homebrew/opt/onnxruntime/lib /opt/homebrew/opt/hdf5/lib /opt/homebrew/opt/jpeg-turbo/lib /opt/homebrew/opt/webp/lib /opt/homebrew/opt/ffmpeg/lib',
  }
end
