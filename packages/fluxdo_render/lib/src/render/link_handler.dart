/// 点击链接时主项目要执行的回调签名。
///
/// 子包不实现 URL 路由(主项目有 launchContentLink 处理 launchUrl /
/// 内部 topic 跳转 / 用户卡 / 下载附件 / lightbox 兜底 等),通过
/// 这个 typedef 注入,子包只负责"触发"。
///
/// 调用方:
/// ```dart
/// NodeFactory(linkHandler: (context, href) {
///   launchContentLink(context, href, onInternalLinkTap: ...);
/// })
/// ```

library;

import 'package:flutter/widgets.dart';

typedef LinkActionHandler = void Function(BuildContext context, String href);

/// 默认 link handler — 仅打印 debug 信息,不执行 URL 路由。
///
/// 主项目调用方必须自行注入实际处理 callback;留这个 default 是
/// 为了让子包单测能跑(没有 launchUrl 的环境)+ 让早期 dogfood
/// 不至于因为忘记注入而崩。
void defaultLinkHandler(BuildContext context, String href) {
  debugPrint('[fluxdo_render] link tapped without handler: $href');
}

/// 点击附件链接(`<a class="attachment">`)时主项目要执行的回调签名。
///
/// 比 [LinkActionHandler] 多带 [filename](parser 从锚点文本抓的文件名),
/// 主项目据此调内置下载器(startDownload 的 suggestedFilename)。
///
/// 调用方:
/// ```dart
/// NodeFactory(onDownloadAttachment: (context, href, filename) {
///   launchContentLink(context, href, onDownloadAttachment: (url) {
///     ref.read(downloadProvider.notifier)
///        .startDownload(url: url, suggestedFilename: filename);
///   });
/// })
/// ```
typedef AttachmentDownloadHandler =
    void Function(BuildContext context, String href, String filename);
