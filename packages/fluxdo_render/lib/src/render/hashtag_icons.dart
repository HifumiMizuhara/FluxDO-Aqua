import 'package:flutter/widgets.dart';

/// 解析 hashtag 药丸的图标。
///
/// [iconName] 是 cooked 里 `<use href="#...">` 的名字(站点 `hashtag_icons`;
/// 分类没自定义时 Discourse 给的是色块 `square-full`),[href] 是药丸链接
/// (`/c/slug/4` 或 `/tag/xxx`)—— 宿主可以据此去查分类自己配的图标,拿到
/// 与编辑器 `#` 补全下拉一致的那个。
///
/// 子包不依赖 Font Awesome(名字到字形的表在宿主那边),所以留成注入点。
/// 返回 null = 认不出来,渲染侧按分类/标签兜底。
typedef HashtagIconResolver =
    IconData? Function(BuildContext context, String? iconName, String href);

/// 宿主在启动时赋值一次(同 EmojiHandler 的单例口径)。
HashtagIconResolver? hashtagIconResolver;

/// 点击 hashtag 药丸。比普通 linkHandler 多给两样东西:
///
/// - [ref]:cooked 里 `data-ref`/`data-slug` 的原值(如 `女装`、
///   `女装::tag`)。这是**服务端写下的引用串**,也就是标签/分类此刻的
///   真名 —— URL 段对中文标签是 Discourse 生成的 `<id>-tag` slug,
///   推不回真名,而 `/tag/<真名>/l/latest.json` 才是服务端认的路径。
/// - [label]:药丸上的显示文字(去掉前导 `#`),ref 缺失时的兜底。
///
/// 返回 true = 已接管;false/null = 退回普通 linkHandler。
typedef HashtagTapHandler =
    bool Function(BuildContext context, String href, String? ref, String label);

HashtagTapHandler? hashtagTapHandler;
