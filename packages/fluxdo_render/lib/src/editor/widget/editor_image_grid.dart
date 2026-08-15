/// 编辑器网格(grid 岛的专属交互视图)—— 官方 composer 内聚布局 1:1:
///
/// ```
/// ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ [网格|轮播] ┐   ← 容器右上常驻
/// ╎ ┌────────┐ ┌────────┐                      ╎
/// ╎ │[删|出] │ │        │   ← 子选中瓦片左上叠工具条
/// ╎ │  img   │ │  img   │
/// ╎ │alt 标签│ └────────┘   ← 子选中瓦片底部 alt 标签(点击原位编辑)
/// ╎ └────────┘                    [移除网格]   ← 容器右下常驻
/// └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
/// ```
///
/// - 布局 = rich-editor.scss `.composer-image-grid`:flex-wrap 等大方块
///   (img 200px / 窄容器 150px, cover)+ **虚线边框** + 内边距;
/// - 全部动作内聚(不再走 app Overlay 浮层):模式切换/移除网格/瓦片
///   删除/移出网格/alt 编辑,由 FluxdoEditor 接子包命令,宿主只管
///   [onImageOpen](查看器);
/// - 鼠标样式(官方 CSS 同款):未选中瓦片 hover = click(pointer),
///   已选中 = zoomIn(再点开查看器);按钮 = click;
/// - 瓦片区在 [kEditorSelfManagedRegion] 自管区内;网格空白/边缘走岛
///   整选(外层 GestureDetector)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../node/node.dart';
import '../../render/image_handler.dart';
import '../../render/node_factory.dart';
import 'editor_table_grid.dart' show kEditorSelfManagedRegion;

/// grid 内图片子选中事件(宿主开查看器用)。
@immutable
class GridImageSelection {
  const GridImageSelection({
    required this.islandId,
    required this.imageIndex,
    required this.image,
    required this.globalRect,
  });

  /// grid 岛块 id。
  final String islandId;

  /// 在 ImageGridNode.images 中的下标。
  final int imageIndex;

  final ImageRun image;

  /// 瓦片全局矩形。
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GridImageSelection &&
          islandId == other.islandId &&
          imageIndex == other.imageIndex &&
          image == other.image &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(islandId, imageIndex, image, globalRect);
}

class EditorImageGrid extends StatefulWidget {
  const EditorImageGrid({
    super.key,
    required this.node,
    required this.islandId,
    required this.nodeFactory,
    this.selectedIndex,
    this.onImageTap,
    this.onImageOpen,
    this.onModeChange,
    this.onRemoveGrid,
    this.onRemoveImage,
    this.onMoveImageOut,
    this.onAltChanged,
    this.onReorder,
  });

  final ImageGridNode node;
  final String islandId;
  final NodeFactory nodeFactory;

  /// 当前子选中的图下标(FluxdoEditor 持有;null = 无子选中)。
  final int? selectedIndex;

  /// 瓦片单击(未选中态)→ 请求子选中。
  final ValueChanged<GridImageSelection>? onImageTap;

  /// 已子选中的瓦片再点 → 请求打开查看器(宿主)。
  final ValueChanged<GridImageSelection>? onImageOpen;

  /// 容器右上 [网格|轮播] 切换。
  final ValueChanged<ImageGridMode>? onModeChange;

  /// 容器右下 [移除网格](拆壳保图)。
  final VoidCallback? onRemoveGrid;

  /// 子选中瓦片工具条:删除本图。
  final ValueChanged<int>? onRemoveImage;

  /// 子选中瓦片工具条:移出网格。
  final ValueChanged<int>? onMoveImageOut;

  /// 瓦片 alt 原位编辑保存(index, 新 alt)。
  final void Function(int index, String alt)? onAltChanged;

  /// 瓦片拖拽排序:第 [from] 张拖放到第 [to] 张瓦片上(落位 to 下标,
  /// 目标侧让位)。null = 不可排序。
  final void Function(int from, int to)? onReorder;

  @override
  State<EditorImageGrid> createState() => _EditorImageGridState();
}

class _EditorImageGridState extends State<EditorImageGrid> {
  final Map<int, GlobalKey> _tileKeys = {};

  /// 正在原位编辑 alt 的瓦片下标(null = 无)。
  int? _editingAlt;
  final TextEditingController _altController = TextEditingController();
  final FocusNode _altFocus = FocusNode(debugLabel: 'grid-tile-alt');

  @override
  void didUpdateWidget(covariant EditorImageGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 子选中变化/图列表变化 → 退出 alt 编辑态
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.node != widget.node) {
      _editingAlt = null;
    }
  }

  @override
  void dispose() {
    _altController.dispose();
    _altFocus.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int index) => _tileKeys.putIfAbsent(index, GlobalKey.new);

  GridImageSelection? _selectionOf(int index) {
    final box =
        _tileKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) return null;
    return GridImageSelection(
      islandId: widget.islandId,
      imageIndex: index,
      image: widget.node.images[index],
      globalRect: topLeft & box.size,
    );
  }

  void _onTileTap(int index) {
    final sel = _selectionOf(index);
    if (sel == null) return;
    if (widget.selectedIndex == index) {
      widget.onImageOpen?.call(sel);
    } else {
      widget.onImageTap?.call(sel);
    }
  }

  void _startAltEdit(int index) {
    setState(() {
      _editingAlt = index;
      _altController.text = widget.node.images[index].alt;
      _altController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _altController.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingAlt == index) _altFocus.requestFocus();
    });
  }

  void _commitAlt() {
    final i = _editingAlt;
    if (i == null) return;
    setState(() => _editingAlt = null);
    final text = _altController.text.trim();
    if (i < widget.node.images.length && text != widget.node.images[i].alt) {
      widget.onAltChanged?.call(i, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = widget.node.images;
    final builder =
        widget.nodeFactory.imageContentBuilder ?? defaultImageContentBuilder;

    if (images.isEmpty) return const SizedBox.shrink();

    return MetaData(
      metaData: kEditorSelfManagedRegion,
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 官方:viewport <md 150px,≥md 200px(编辑器列宽近似判)
          final tileSize = constraints.maxWidth < 640 ? 150.0 : 200.0;
          return CustomPaint(
            foregroundPainter: _DashedBorderPainter(
              color: scheme.outlineVariant,
              radius: 8,
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶行:右上角 [网格|轮播] 常驻(官方 mode-buttons)
                  if (widget.onModeChange != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _ModeSegment(
                        mode: widget.node.mode,
                        onChange: widget.onModeChange!,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < images.length; i++)
                        _tile(
                          context,
                          scheme,
                          builder,
                          i,
                          images[i],
                          tileSize,
                          images.length,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 底行:右下角 [移除网格] 常驻(官方 remove-btn)
                  if (widget.onRemoveGrid != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _FlatButton(
                        icon: Icons.grid_off_rounded,
                        label: '移除网格',
                        onTap: widget.onRemoveGrid!,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    ColorScheme scheme,
    ImageContentBuilder builder,
    int index,
    ImageRun img,
    double size,
    int total,
  ) {
    final body = _tileBody(context, scheme, builder, index, img, size, total);
    if (widget.onReorder == null || total < 2) return body;

    // 拖拽排序:长按提起(触摸/鼠标同一手势 —— 立即拖会抢瓦片单击与
    // 页面滚动的竞技场);每瓦片同时是放置目标,drop = 落位该瓦片下标。
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => widget.onReorder!(d.data, index),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: candidates.isEmpty ? Colors.transparent : scheme.primary,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: LongPressDraggable<int>(
          data: index,
          maxSimultaneousDrags: 1,
          feedback: _dragFeedback(context, builder, img, size, total),
          childWhenDragging: Opacity(opacity: 0.35, child: body),
          child: body,
        ),
      ),
    );
  }

  /// 拖拽影像:瓦片同尺寸缩略 + 提起阴影(脱离树,需自带 Material)。
  Widget _dragFeedback(
    BuildContext context,
    ImageContentBuilder builder,
    ImageRun img,
    double size,
    int total,
  ) {
    return Material(
      color: Colors.transparent,
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: 0.9,
        child: SizedBox(
          width: size,
          height: size,
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: AbsorbPointer(child: builder(context, img, total)),
          ),
        ),
      ),
    );
  }

  Widget _tileBody(
    BuildContext context,
    ColorScheme scheme,
    ImageContentBuilder builder,
    int index,
    ImageRun img,
    double size,
    int total,
  ) {
    final selected = widget.selectedIndex == index;
    final editingAlt = _editingAlt == index;
    return MouseRegion(
      // 官方 CSS:未选中 hover = pointer,选中 = zoom-in(再点开灯箱)
      cursor: selected ? SystemMouseCursors.zoomIn : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTileTap(index),
        child: SizedBox(
          key: _keyFor(index),
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 图
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: AbsorbPointer(child: builder(context, img, total)),
                  ),
                ),
              ),
              // 子选中:左上叠 [删除|移出] 工具条(官方 menu top-start)
              if (selected)
                Positioned(
                  left: 6,
                  top: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TileIconBtn(
                          icon: Icons.delete_outline_rounded,
                          tooltip: '删除图片',
                          onTap: () => widget.onRemoveImage?.call(index),
                        ),
                        _TileIconBtn(
                          icon: Icons.grid_off_rounded,
                          tooltip: '移出网格',
                          onTap: () => widget.onMoveImageOut?.call(index),
                        ),
                      ],
                    ),
                  ),
                ),
              // 子选中:底部 alt 标签 / 原位编辑
              if (selected)
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: editingAlt
                      ? Focus(
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey == LogicalKeyboardKey.escape) {
                              setState(() => _editingAlt = null);
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: TextField(
                              controller: _altController,
                              focusNode: _altFocus,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: '替代文本',
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _commitAlt(),
                              onTapOutside: (_) => _commitAlt(),
                            ),
                          ),
                        )
                      : MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => _startAltEdit(index),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                img.alt.isEmpty ? '替代文本' : img.alt,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: img.alt.isEmpty
                                      ? Colors.white54
                                      : Colors.white,
                                ),
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

/// [网格|轮播] 分段按钮(官方 mode-buttons:active 主色底)。
class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.mode, required this.onChange});

  final ImageGridMode mode;
  final ValueChanged<ImageGridMode> onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(String label, IconData icon, ImageGridMode m) {
      final active = mode == m;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: active ? null : () => onChange(m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active ? scheme.primary : scheme.surfaceContainerLow,
              border: Border.all(
                color: active
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn('网格', Icons.grid_view_rounded, ImageGridMode.grid),
          btn('轮播', Icons.view_carousel_rounded, ImageGridMode.carousel),
        ],
      ),
    );
  }
}

/// 扁平文字按钮(官方 remove-btn:细边框 + hover 提亮)。
class _FlatButton extends StatelessWidget {
  const _FlatButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TileIconBtn extends StatelessWidget {
  const _TileIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 虚线圆角边框(官方 `border: 2px dashed`;Flutter 无原生 dashed)。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(1);
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, (d + dash).clamp(0, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
