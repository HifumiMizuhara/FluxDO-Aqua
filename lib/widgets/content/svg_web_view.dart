import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/svg_utils.dart';
import 'animated_svg_view.dart';

/// 用系统 WebView 绘制一个 SVG 文档。
///
/// 该组件只由签名 SVG 的显式设置开关接入，不改变正文和查看器的默认
/// SVG 管线。WebView 保留浏览器的 CSS / SMIL 动画行为，
/// 但使用了平台视图，因此不适合默认用于大量帖子列表。
class SvgWebView extends StatelessWidget {
  final String svgSource;
  final double? width;
  final double? height;
  final Alignment alignment;

  const SvgWebView({
    super.key,
    required this.svgSource,
    this.width,
    this.height,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    final geometry = AnimatedSvgView.rootGeometryOf(svgSource);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fallbackWidth = MediaQuery.sizeOf(context).width;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : fallbackWidth;
        final availableWidth = width ?? maxWidth;

        double displayWidth;
        double displayHeight;
        if (width != null && height != null) {
          displayWidth = width!;
          displayHeight = height!;
        } else if (height != null) {
          displayHeight = height!;
          displayWidth = displayHeight * geometry.aspect;
        } else {
          // <img> の置換要素と同じく、height だけ指定された SVG は
          // 比率から不足する自然幅を補う。
          final naturalWidth =
              geometry.naturalW ??
              (geometry.naturalH != null
                  ? geometry.naturalH! * geometry.aspect
                  : null);
          displayWidth = naturalWidth == null
              ? availableWidth
              : math.min(availableWidth, naturalWidth);
          if (!displayWidth.isFinite || displayWidth <= 0) {
            displayWidth = fallbackWidth;
          }
          displayHeight = displayWidth / geometry.aspect;
        }

        if (constraints.maxHeight.isFinite &&
            displayHeight > constraints.maxHeight &&
            displayHeight > 0) {
          final scale = constraints.maxHeight / displayHeight;
          displayWidth *= scale;
          displayHeight = constraints.maxHeight;
        }
        if (!displayWidth.isFinite || displayWidth <= 0) displayWidth = 1;
        if (!displayHeight.isFinite || displayHeight <= 0) displayHeight = 1;

        return Align(
          alignment: alignment,
          heightFactor: 1,
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: _SvgWebViewSurface(svgSource: svgSource),
          ),
        );
      },
    );
  }
}

class _SvgWebViewSurface extends StatelessWidget {
  final String svgSource;

  const _SvgWebViewSurface({required this.svgSource});

  @override
  Widget build(BuildContext context) {
    final windowsWebView =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    return InAppWebView(
      webViewEnvironment: windowsWebView
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialData: InAppWebViewInitialData(
        data: _buildDocument(SvgUtils.stripActiveContent(svgSource)),
        baseUrl: WebUri(AppConstants.baseUrl),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        // 签名SVGはユーザー入力のため、CSS/SMILだけを許可し、
        // script・on*イベント属性はSVG側でも除去する。
        javaScriptEnabled: false,
        domStorageEnabled: true,
        transparentBackground: true,
        cacheEnabled: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        userAgent: AppConstants.webViewUserAgentOverride,
        supportZoom: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        allowsInlineMediaPlayback: true,
        useHybridComposition: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: WebViewSettings.registerJsErrorReporter,
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      shouldOverrideUrlLoading: (_, action) async {
        // SVG内的リンクや script によるトップレベル遷移は、署名表示枠の
        // 外へ出さない。画像・CSS等のサブリソース読込は影響を受けない。
        if (action.isForMainFrame == true) {
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
    );
  }
}

String _buildDocument(String source) {
  final withoutXmlDeclaration = source.replaceFirst(
    RegExp(r'^\s*<\?xml[^>]*\?>', caseSensitive: false),
    '',
  );
  return '''<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html, body { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
body { display: flex; align-items: stretch; justify-content: stretch; }
svg { display: block; width: 100% !important; height: 100% !important; }
</style>
</head>
<body>$withoutXmlDeclaration</body>
</html>''';
}
