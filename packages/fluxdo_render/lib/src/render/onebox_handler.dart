/// 渲染 Onebox 卡片时主项目要提供的 builder 签名。
///
/// 子包不实现 6 种子类型(github/video/social/tech/user/default)的具体
/// 渲染,通过这个 typedef 让主项目 dispatch 到 legacy 6 个完整 builder
/// (`github_onebox_builder.dart` 等共 4000 行实现)。
///
/// 调用方:
/// ```dart
/// FluxdoRender(
///   cookedHtml: ...,
///   oneboxBuilder: (ctx, onebox) {
///     switch (onebox.kind) {
///       case OneboxKind.github:
///         return buildGithubOneboxFromHtml(
///           context: ctx,
///           rawHtml: onebox.rawHtml,
///           url: onebox.url ?? '',
///         );
///       case OneboxKind.video:
///         return buildVideoOnebox(...);
///       ...
///       default:
///         return null; // null 让子包走默认通用卡片
///     }
///   },
/// );
/// ```
///
/// 返回 null 时,子包用 [defaultOneboxFallback] 渲染(通用卡片样式)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

/// Onebox builder。返回 null 时 fallback 到子包内置通用卡片。
typedef OneboxBuilder =
    Widget? Function(BuildContext context, OneboxNode onebox);
