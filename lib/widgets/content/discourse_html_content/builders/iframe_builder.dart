import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../../constants.dart';
import '../../../../utils/layout_lock.dart';
import '../../../../utils/url_helper.dart';
import '../../../../pages/webview_page.dart';
import '../../../../l10n/s.dart';
import '../../../../services/navigation/app_route_observer.dart';
import '../../../../services/webview_settings.dart';
import '../../../../services/windows_webview_environment_service.dart';

/// 是否需要交互遮罩（macOS 上 WebView 会捕获滚动事件）
bool get _needsInteractionMask => !kIsWeb && Platform.isMacOS;

/// iframe 属性解析结果
class IframeAttributes {
  final String src;
  final double? width;
  final double? height;
  final Set<String>? sandbox;
  final Set<String> allow;
  final bool allowFullscreen;
  final String? referrerPolicy;
  final bool lazyLoad;
  final String? title;
  final Set<String> classes;

  IframeAttributes({
    required this.src,
    this.width,
    this.height,
    this.sandbox,
    this.allow = const {},
    this.allowFullscreen = false,
    this.referrerPolicy,
    this.lazyLoad = false,
    this.title,
    this.classes = const {},
  });

  /// 从 HTML element 解析 iframe 属性
  factory IframeAttributes.fromElement(dynamic element) {
    final attrs = element.attributes;

    // src 属性
    final src =
        (attrs['src'] as String?) ?? (attrs['data-src'] as String?) ?? '';

    // 宽高属性
    final width = double.tryParse(attrs['width'] as String? ?? '');
    final height = double.tryParse(attrs['height'] as String? ?? '');

    // class 属性
    final classAttr = attrs['class'] as String?;
    final classes = classAttr?.split(RegExp(r'\s+')).toSet() ?? {};

    // sandbox 属性
    final sandboxAttr = attrs['sandbox'] as String?;
    final sandbox = sandboxAttr?.split(RegExp(r'\s+')).toSet();

    // allow 属性 (Permissions Policy)
    final allowAttr = attrs['allow'] as String?;
    final allow =
        allowAttr
            ?.split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        {};

    // allowfullscreen 属性
    final allowFullscreen =
        attrs.containsKey('allowfullscreen') ||
        attrs['allowfullscreen'] == 'true' ||
        attrs['allowfullscreen'] == '' ||
        allow.any((p) => p.startsWith('fullscreen'));

    // referrerpolicy 属性
    final referrerPolicy = attrs['referrerpolicy'] as String?;

    // loading 属性
    final loadingAttr = attrs['loading'] as String?;
    final lazyLoad = loadingAttr == 'lazy';

    // title 属性
    final title = attrs['title'] as String?;

    return IframeAttributes(
      src: src,
      width: width,
      height: height,
      sandbox: sandbox,
      allow: allow,
      allowFullscreen: allowFullscreen,
      referrerPolicy: referrerPolicy,
      lazyLoad: lazyLoad,
      title: title,
      classes: classes,
    );
  }

  /// 是否允许脚本执行
  bool get allowScripts =>
      sandbox == null || sandbox!.contains('allow-scripts');

  /// 是否允许自动播放
  bool get allowAutoplay => allow.any((p) => p.startsWith('autoplay'));

  /// 计算宽高比
  double get aspectRatio {
    // 视频 onebox 强制使用 16:9（遵循 Discourse CSS 规则）
    if (classes.contains('youtube-onebox') ||
        classes.contains('lazyYT') ||
        classes.contains('vimeo-onebox') ||
        classes.contains('loom-onebox')) {
      return 16 / 9;
    }

    // 其他情况：如果有明确的宽高，使用计算值
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! / height!;
    }

    // 默认 16:9
    return 16 / 9;
  }

  /// 获取完整 URL
  String get fullUrl => UrlHelper.resolveUrl(src);
}

/// iframe Widget
class IframeWidget extends StatefulWidget {
  final IframeAttributes attributes;

  const IframeWidget({super.key, required this.attributes});

  @override
  State<IframeWidget> createState() => _IframeWidgetState();
}

/// iframe 保活登记表(LRU,容量有界)。
///
/// 新引擎长帖按 chunk 做 sliver 虚拟化,iframe 所在 chunk(往往只有
/// 两三百 px 高)滚出 cacheExtent(500px)即 dispose —— 内嵌 WebView
/// 是 hybrid composition 平台视图,销毁/重建都是平台主线程百 ms 级
/// 重活,来回滚动 = 反复卡顿(旧引擎长帖是 Column 全量构建,iframe
/// 跟随整个 post 存活,同距离滚动几乎不重建,故"旧引擎没这么卡")。
///
/// 保活复刻旧引擎的长存活行为;LRU 限量防病态帖子(几十个 iframe)
/// 把 WebView 全部驻留导致内存无界 —— 超量时最久未挂载的先降级为
/// 可回收,滚出后正常销毁,滚回来重建时重新入表。
class _IframeKeepAliveRegistry {
  static const _capacity = 4;
  static final List<_IframeWidgetState> _active = [];

  static void touch(_IframeWidgetState state) {
    _active
      ..remove(state)
      ..add(state);
    while (_active.length > _capacity) {
      _active.removeAt(0)._setKeptAlive(false);
    }
  }

  static void remove(_IframeWidgetState state) {
    _active.remove(state);
  }
}

class _IframeWidgetState extends State<IframeWidget>
    with RouteAware, AutomaticKeepAliveClientMixin {
  bool _isLoaded = false;
  bool _hasError = false;
  bool _didLockLayout = false;

  /// 是否处于保活期(在 LRU 表内)。被挤出后允许随 sliver 回收销毁。
  bool _keptAlive = true;

  @override
  bool get wantKeepAlive => _keptAlive;

  void _setKeptAlive(bool value) {
    if (_keptAlive == value) return;
    _keptAlive = value;
    if (mounted) updateKeepAlive();
  }

  /// 桌面平台：是否进入交互模式
  bool _interacting = false;
  OverlayEntry? _overlayEntry;

  /// 上层路由（对话框/BottomSheet）出现时隐藏 WebView，
  /// 避免 hybrid composition 持续脏帧触发 BackdropFilter 全屏重算。
  bool _routeOverlayed = false;

  @override
  void initState() {
    super.initState();
    _IframeKeepAliveRegistry.touch(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    if (!_routeOverlayed) setState(() => _routeOverlayed = true);
  }

  @override
  void didPopNext() {
    if (_routeOverlayed) setState(() => _routeOverlayed = false);
  }

  @override
  void dispose() {
    _IframeKeepAliveRegistry.remove(this);
    appRouteObserver.unsubscribe(this);
    _removeOverlay();
    _unlockLayoutIfNeeded();
    super.dispose();
  }

  void _enterInteractMode() {
    setState(() => _interacting = true);
    _showOverlay();
  }

  void _exitInteractMode() {
    _removeOverlay();
    setState(() => _interacting = false);
  }

  void _showOverlay() {
    _removeOverlay();
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _exitInteractMode,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Symbols.close_rounded, size: 18, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      S.current.iframe_exitInteraction,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 契约
    // 每次可见构建都触摸 LRU:保活期滚回视口不走 initState,
    // 这里是唯一能感知"它又被看到了"的时机(表容量 ≤4,开销可忽略)
    _IframeKeepAliveRegistry.touch(this);
    _keptAlive = true;
    final attrs = widget.attributes;
    final theme = Theme.of(context);
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    // 构建内容 Widget
    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          // WebView - 始终渲染
          // 直接加载 URL，通过设置 Referer 头解决 origin 验证问题
          Offstage(
            offstage: _routeOverlayed,
            child: InAppWebView(
            webViewEnvironment: windowsWebViewEnvironment,
            initialUrlRequest: URLRequest(
              url: WebUri(attrs.fullUrl),
              headers: {'Referer': AppConstants.baseUrl},
            ),
            initialSettings: _buildSettings(attrs),
            initialUserScripts: WebViewSettings.compatPolyfillScripts,
            onWebViewCreated: (controller) {
              WebViewSettings.registerJsErrorReporter(controller);
            },
            onReceivedServerTrustAuthRequest: (_, challenge) =>
                WebViewSettings.handleServerTrustAuthRequest(challenge),
            // 允许 WebView 接收水平滑动手势
            gestureRecognizers: {
              Factory<HorizontalDragGestureRecognizer>(
                () => HorizontalDragGestureRecognizer(),
              ),
            },
            onEnterFullscreen: (controller) {
              _lockLayout();
            },
            onExitFullscreen: (controller) {
              _unlockLayoutIfNeeded();
            },
            onLoadStart: (controller, url) {
              if (mounted) {
                setState(() {
                  _isLoaded = false;
                  _hasError = false;
                });
              }
            },
            onLoadStop: (controller, url) async {
              if (mounted) {
                setState(() => _isLoaded = true);
              }
              // 注入 viewport meta 标签，确保内容正确缩放
              await controller.evaluateJavascript(
                source: '''
                    (function() {
                      var meta = document.querySelector('meta[name="viewport"]');
                      if (!meta) {
                        meta = document.createElement('meta');
                        meta.name = 'viewport';
                        document.head.appendChild(meta);
                      }
                      meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                    })();
                  ''',
              );
            },
            onReceivedError: (controller, request, error) {
              // 只有主框架加载失败才显示错误
              // 忽略子资源（JS、图片、视频海报等）的加载错误
              if (mounted && request.isForMainFrame == true) {
                setState(() => _hasError = true);
              }
            },
            // 拦截用户点击的链接，使用 WebViewPage 打开
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              // 只拦截用户主动点击的链接
              if (navigationAction.navigationType !=
                  NavigationType.LINK_ACTIVATED) {
                return NavigationActionPolicy.ALLOW;
              }

              final url = navigationAction.request.url?.toString();
              if (url == null) {
                return NavigationActionPolicy.ALLOW;
              }

              // 使用 WebViewPage 打开
              if (mounted) {
                WebViewPage.open(context, url);
              }
              return NavigationActionPolicy.CANCEL;
            },
          ),
          ),
          // 加载指示器
          if (!_isLoaded && !_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: CircularProgressIndicator()),
            ),
          // 错误状态
          if (_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.error_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.current.common_loadFailed,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 桌面平台：交互遮罩
          if (_needsInteractionMask && !_interacting && _isLoaded && !_hasError)
            Positioned.fill(
              child: GestureDetector(
                onTap: _enterInteractMode,
                child: Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Icon(
                      Symbols.touch_app_rounded,
                      size: 48,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 始终使用响应式宽高比布局，忽略固定像素尺寸
    // 这样可以适配不同屏幕尺寸，避免在小屏幕上溢出或在大屏幕上显得太小
    Widget sizedContent;

    // 特殊情况：如果只有固定高度（没有宽度或宽度是百分比），使用固定高度
    // 例如：width="100%" height="111"
    if (attrs.height != null && attrs.height! > 0 && attrs.width == null) {
      sizedContent = SizedBox(
        width: double.infinity,
        height: attrs.height,
        child: content,
      );
    } else {
      // 其他情况使用宽高比
      sizedContent = AspectRatio(
        aspectRatio: attrs.aspectRatio,
        child: content,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: sizedContent,
    );
  }

  InAppWebViewSettings _buildSettings(IframeAttributes attrs) {
    return InAppWebViewSettings(
      // User-Agent
      userAgent: AppConstants.webViewUserAgentOverride,

      // JavaScript（根据 sandbox 属性决定）
      javaScriptEnabled: attrs.allowScripts,

      // 媒体播放
      mediaPlaybackRequiresUserGesture: !attrs.allowAutoplay,
      allowsInlineMediaPlayback: true,

      // 全屏（根据 allowfullscreen 属性决定）
      iframeAllowFullscreen: attrs.allowFullscreen,

      // 外观
      transparentBackground: true,

      // 安全
      javaScriptCanOpenWindowsAutomatically: false,

      // 性能
      useHybridComposition: true,

      // 内容模式
      preferredContentMode: UserPreferredContentMode.RECOMMENDED,

      // 允许混合内容和第三方 cookies
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      thirdPartyCookiesEnabled: true,
    );
  }

  void _lockLayout() {
    if (_didLockLayout) return;
    _didLockLayout = true;
    LayoutLock.acquire();
  }

  void _unlockLayoutIfNeeded() {
    if (!_didLockLayout) return;
    _didLockLayout = false;
    LayoutLock.release();
  }
}
