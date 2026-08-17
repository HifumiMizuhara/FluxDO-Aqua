#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'native_animated_image_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS implementation of native_animated_image (Rust-based GIF/APNG/WebP decoder).'
  s.description      = <<-DESC
A native Rust decoder for animated images, bypassing Flutter's built-in Skia
multi-frame codec to avoid upstream bugs.
                       DESC
  s.homepage         = 'https://github.com/Lingyan000/native_animated_image'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Lingyan000' => 'noreply@github.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # 携带 Rust 编译出的 dylib(由 build_native.dart 脚本生成到 Libs/)
  # vendored_libraries 让 CocoaPods 自动 link 并 copy 到 app bundle 的 Frameworks/
  s.vendored_libraries = 'Libs/libnative_animated_image_codec.dylib'
end
