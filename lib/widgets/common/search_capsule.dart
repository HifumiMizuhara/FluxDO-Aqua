import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';

/// 首页搜索胶囊 ↔ 搜索页搜索框的跨页 Hero tag
const kSearchCapsuleHeroTag = 'topics-search-capsule';

/// 搜索胶囊静态视觉：首页头部 morph 层与 Hero flight shuttle 共用。
///
/// [iconLeftPadding]/[hintOpacity] 由 morph 进度驱动（整行态 16/1.0，
/// 收拢成 40×40 图标态 10/0.0），几何由外层 Positioned.fromRect 控制，
/// 本组件只负责内容排布，任意宽度下都成立。
class SearchCapsule extends StatelessWidget {
  const SearchCapsule({
    super.key,
    this.onTap,
    this.hintOpacity = 1.0,
    this.iconLeftPadding = 16.0,
    this.iconSize = 20.0,
    this.backgroundOpacity = 1.0,
  });

  final VoidCallback? onTap;
  final double hintOpacity;
  final double iconLeftPadding;

  /// glyph 尺寸：整行胶囊态 20（配 14 号 hint 文字），morph 落位后
  /// 插值到 24 与工具栏其他图标（🔔 等默认 24）同大
  final double iconSize;

  /// 灰底不透明度：morph 收尾阶段渐隐到 0，落位后是纯图标
  /// （与工具栏 🔔 等裸图标按钮同族，不带背景色块）
  final double backgroundOpacity;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 固定 40px 高的胶囊必须钳制系统字体缩放（AppBar 标题同款处理）：
    // HyperOS 等大字体档位下 hint 会被放大到撑破胶囊、顶着上下边缘
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5 * backgroundOpacity,
        ),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Row(
            children: [
              SizedBox(width: iconLeftPadding),
              Icon(
                Symbols.search_rounded,
                size: iconSize,
                color: colorScheme.onSurfaceVariant,
              ),
              Expanded(
                child: hintOpacity <= 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 8, right: 12),
                        child: Opacity(
                          opacity: hintOpacity,
                          child: Text(
                            S.current.topics_searchHint,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero flight 期间的静态胶囊（两端都是灰底圆角胶囊，用无 TextField 的
/// 静态版飞行，避免输入框参与 flight 造成焦点/光标闪烁）
Widget searchCapsuleFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  return const SearchCapsule();
}
