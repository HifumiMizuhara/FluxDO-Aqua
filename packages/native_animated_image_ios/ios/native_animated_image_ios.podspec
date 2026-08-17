#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'native_animated_image_ios'
  s.version          = '0.1.2'
  s.summary          = 'iOS implementation of native_animated_image (Rust-based GIF/APNG/WebP decoder).'
  s.description      = <<-DESC
A native Rust decoder for animated images, bypassing Flutter's built-in Skia
multi-frame codec to avoid upstream bugs.
                       DESC
  s.homepage         = 'https://github.com/Lingyan000/native_animated_image'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Lingyan000' => 'noreply@github.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.dependency 'Flutter'

  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'VALID_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }
  s.swift_version = '5.0'

  # native_animated_image_codec 包装为动态 framework(dylib in .framework bundle),
  # xcframework 内 ios-arm64/ + ios-arm64-simulator/ 各自一个 .framework slice。
  #
  # 为什么用 dylib 而不是 static .a:
  # iOS 静态库的 FFI 符号会被 Xcode dead-strip 掉(dart:ffi 是 runtime lookup,
  # linker 看不到 caller),需要 -force_load 强制保留;但 Xcode 16 严格 build-input
  # check 会把 -force_load 的 path 当 missing input 报错。
  # 动态库由 dyld 在 app 启动时整库 load,所有 exported symbols 直接进 process,
  # `DynamicLibrary.process()` 直接可见,不需要 force_load。
  s.vendored_frameworks = 'Libs/native_animated_image_codec.xcframework'
end
