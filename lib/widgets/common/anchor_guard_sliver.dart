import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../utils/frame_jank_monitor.dart';

/// 滚动锚定哨兵:浏览器 scroll anchoring 的 Flutter 等价物。
///
/// 问题:双向列表(center 锚点 CustomScrollView)里,视口上方已物化的帖子
/// 在**静止阅读**时改变高度(msgbus 滚停回放的 reaction 行、boost 气泡、
/// 编辑后内容增减、未知尺寸图片加载完成),下方内容整体平移,视觉上正在
/// 读的文字突然"被拉一下"。浏览器有原生 scroll anchoring 自动补偿滚动
/// 偏移(Discourse 官方端全靠它消化 msgbus 更新的高度变化),Flutter
/// viewport 没有 —— 本哨兵用 sliver 协议自带的
/// [SliverGeometry.scrollOffsetCorrection] 在**同一帧内**补上这层。
///
/// 用法:slivers 首尾各挂一个(零尺寸,不占布局)。viewport 布局 reverse
/// 区时从近 center 到远依次进行,首位哨兵最后布局;forward 区顺序布局,
/// 末位哨兵最后 —— 各自布局时本区兄弟的位置都是新鲜值。**必须两个**:
/// `child.layout()` 在约束不变时跳过 performLayout,而 before 区高度变化
/// 不改 forward 区哨兵的约束(centerOffset/precedingScrollExtent 都算不到
/// 对面区),单哨兵会整半场失明。
///
/// 每趟布局:
/// 1. 空闲态、滚动偏移与基线逐位一致、结构签名未变 → 量锚元素(上一趟
///    "视口上沿所在的帖子")现在相对视口上沿的位移 Δ,超阈值即返回
///    scrollOffsetCorrection(reverse 区取负,viewport 对该区修正值会
///    再取反),viewport `correctBy(Δ)` 同帧重排 —— 像素纹丝不动,且
///    correctBy 不发滚动通知,eyeline/已读上报等一概不受扰动;
/// 2. 其余情况(滚动中/偏移变了/视口尺寸或 anchor 变了/结构变了/锚失效)
///    → 只重建基线。滚动、跳楼、刷新锚定都会改 pixels,天然全部跳过,
///    不需要外部挂起开关。
///
/// 终止性:修正被应用后 pixels 立即偏离两个哨兵的基线,viewport 同帧
/// 重试趟里必然都走重建基线分支 —— 一帧至多一次修正,远够不着 viewport
/// 的布局循环上限;[_correctionStreak] 是额外保险丝。
///
/// 与"滚动中冻结 msgbus 更新"互补:冻结管滚动中(修正会被惯性模拟每帧
/// 覆写,那半场只能冻结),哨兵管静止时 —— 滚停回放 deferred 更新产生的
/// 高度变化正好落进哨兵的管辖窗口被消化。
class AnchorGuardSliver extends LeafRenderObjectWidget {
  const AnchorGuardSliver({
    super.key,
    this.enabled = true,
    this.structureSignature = 0,
  });

  final bool enabled;

  /// 列表结构签名(segment 序列摘要)。签名变化 = 有帖子/分块被插入、
  /// 移除、换页 —— sliver child 按 index 复用,此时同一 RenderBox 可能
  /// 已换了内容,继续按旧基线修正会锚错对象,该帧只重建基线。纯数据
  /// 更新(点赞/reaction,列表身份变但结构不变)不改签名,正是哨兵要
  /// 消化的场景。
  final int structureSignature;

  @override
  RenderAnchorGuardSliver createRenderObject(BuildContext context) =>
      RenderAnchorGuardSliver(
        enabled: enabled,
        structureSignature: structureSignature,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAnchorGuardSliver renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..structureSignature = structureSignature;
  }
}

class RenderAnchorGuardSliver extends RenderSliver {
  RenderAnchorGuardSliver({
    required bool enabled,
    required int structureSignature,
  }) : _enabled = enabled,
       _structureSignature = structureSignature;

  bool get enabled => _enabled;
  bool _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) _invalidateBaseline();
  }

  int get structureSignature => _structureSignature;
  int _structureSignature;
  set structureSignature(int value) {
    if (_structureSignature == value) return;
    _structureSignature = value;
    // 结构变了:旧锚的 RenderBox 可能被 index 复用换了内容,基线作废。
    // updateRenderObject 在 build 期执行,先于本帧布局,时序正确。
    _invalidateBaseline();
  }

  // —— 基线:上一趟布局结束时的锚元素与环境快照 ——
  // 锚元素 = 含视口上沿的帖子(退而求其次:上沿下方最近的帖子)。持有
  // RenderBox 引用:数据更新只换 Post 内容,Element/RenderObject 按
  // index 复用不变;被回收(detach/keptAlive)则基线自动作废。
  RenderBox? _anchorBox;
  double _anchorTop = 0.0;
  double _basePixels = 0.0;
  double _baseViewportAnchor = 0.0;
  Size _baseViewportSize = Size.zero;

  /// 连续修正保险丝:修正后 pixels 必然偏离基线、下一趟只能重建基线,
  /// 理论上不存在连环修正;万一有布局怪癖打破该假设,到 3 次直接放弃,
  /// 宁可跳一下也不逼近 viewport 的布局循环上限。
  int _correctionStreak = 0;

  /// 位移小于该值不修正:吸收文本重排的亚像素噪音,避免无意义的重排趟数
  static const _minCorrection = 0.5;

  void _invalidateBaseline() {
    _anchorBox = null;
  }

  @override
  void performLayout() {
    geometry = SliverGeometry.zero;
    if (!_enabled || constraints.axis != Axis.vertical) {
      _invalidateBaseline();
      return;
    }
    final viewport = _findViewport();
    final offset = viewport?.offset;
    if (viewport == null ||
        offset is! ScrollPosition ||
        !offset.hasPixels ||
        !viewport.hasSize) {
      _invalidateBaseline();
      return;
    }

    // 跨子树量兄弟 sliver 的 child 尺寸/位置属于"布局期越界访问",debug
    // 断言只对 layout callback 放行(invokeLayoutCallback 正是框架给
    // viewport 系"布局中做树外读取"留的正门)。本区兄弟本趟已布局完毕,
    // 读到的是新鲜值;若发出修正,viewport 整趟重排,一致性由协议保证。
    double? correction;
    invokeLayoutCallback<SliverConstraints>((_) {
      correction = _measure(viewport, offset);
    });
    if (correction != null) {
      // reverse 区:viewport 对该区子级的修正值取反后 correctBy,这里
      // 预先反号,保证语义统一为"pixels += Δ"
      final sign = constraints.growthDirection == GrowthDirection.reverse
          ? -1.0
          : 1.0;
      geometry = SliverGeometry(scrollOffsetCorrection: sign * correction!);
    }
  }

  /// 返回本趟要发出的修正值(语义:pixels 应增加多少);null = 不修正
  /// (基线已按需重建)
  double? _measure(RenderViewport viewport, ScrollPosition offset) {
    final anchor = _anchorBox;
    // pixels 用逐位相等:空闲期没人动它,双精度原样保留;任何滚动/跳转/
    // 修正都会让它偏离基线,正是"这趟只重建基线"的信号。
    final canCompare =
        !offset.isScrollingNotifier.value &&
        anchor != null &&
        _anchorStillValid(anchor, viewport) &&
        offset.pixels == _basePixels &&
        viewport.anchor == _baseViewportAnchor &&
        viewport.size == _baseViewportSize;

    if (canCompare && _correctionStreak < 3) {
      final top = _boxTopInViewport(anchor, viewport);
      final delta = top - _anchorTop;
      if (delta.abs() > _minCorrection) {
        // 锚往下移 Δ(上方内容变高)→ pixels 需同增 Δ 把它拉回原位;
        // 变矮同理(Δ 为负)
        _correctionStreak++;
        _pendingLogDelta += delta;
        _scheduleLog();
        return delta;
      }
    }

    _correctionStreak = 0;
    _captureBaseline(viewport, offset);
    return null;
  }

  /// 锚元素仍可参与比较:还挂在树上、有尺寸、没被挪进 keepAlive 桶
  /// (桶里的 child 仍 attached 但 layoutOffset 是陈旧值),且确实在本
  /// viewport 之下(getTransformTo 对非祖先会 assert)。
  bool _anchorStillValid(RenderBox anchor, RenderViewport viewport) {
    if (!anchor.attached || !anchor.hasSize) return false;
    final parentData = anchor.parentData;
    if (parentData is! SliverMultiBoxAdaptorParentData ||
        parentData.keptAlive ||
        parentData.layoutOffset == null) {
      return false;
    }
    RenderObject? node = anchor.parent;
    while (node != null) {
      if (identical(node, viewport)) return true;
      node = node.parent;
    }
    return false;
  }

  /// box 顶边在 viewport 坐标系(0 = 视口上沿)里的 y
  double _boxTopInViewport(RenderBox box, RenderViewport viewport) {
    return MatrixUtils.transformPoint(
      box.getTransformTo(viewport),
      Offset.zero,
    ).dy;
  }

  /// 重建基线:遍历 viewport 下所有帖子列表(RenderSliverMultiBoxAdaptor;
  /// header/typing/分页指示器都是单 box 适配器,自动排除 —— 与 Discourse
  /// 官方"只有帖子能当锚,占位/动态元素 overflow-anchor:none"同构),
  /// 选含视口上沿的 child 为锚。只走活跃 child 链,不碰 keepAlive 桶。
  void _captureBaseline(RenderViewport viewport, ScrollPosition offset) {
    RenderBox? containing;
    double containingTop = 0;
    RenderBox? below;
    double belowTop = double.infinity;

    void visit(RenderObject node) {
      if (node is RenderSliverMultiBoxAdaptor) {
        RenderBox? child = node.firstChild;
        while (child != null) {
          final parentData = child.parentData;
          if (parentData is SliverMultiBoxAdaptorParentData &&
              parentData.layoutOffset != null &&
              child.hasSize) {
            final top = _boxTopInViewport(child, viewport);
            final bottom = top + child.size.height;
            if (top <= 0 && bottom > 0) {
              // 多个候选(理论上仅重叠边界)取顶边最贴近上沿的
              if (containing == null || top > containingTop) {
                containing = child;
                containingTop = top;
              }
            } else if (top > 0 && top < belowTop) {
              below = child;
              belowTop = top;
            }
          }
          child = node.childAfter(child);
        }
      } else if (node is RenderSliver) {
        node.visitChildren(visit);
      }
    }

    viewport.visitChildren(visit);

    final anchorBox = containing ?? below;
    if (anchorBox == null) {
      _invalidateBaseline();
      return;
    }
    _anchorBox = anchorBox;
    _anchorTop = containing != null ? containingTop : belowTop;
    _basePixels = offset.pixels;
    _baseViewportAnchor = viewport.anchor;
    _baseViewportSize = viewport.size;
  }

  RenderViewport? _findViewport() {
    RenderObject? node = parent;
    while (node != null) {
      if (node is RenderViewport) return node;
      node = node.parent;
    }
    return null;
  }

  @override
  void detach() {
    _invalidateBaseline();
    super.detach();
  }

  // —— 诊断:修正事件汇入性能时间轴,生产日志可见哨兵工作频率与幅度 ——
  // 布局期不能碰 FrameJankMonitor(revision 通知会触发监听方 setState),
  // 攒到帧末统一上报。
  static double _pendingLogDelta = 0;
  static bool _logScheduled = false;

  static void _scheduleLog() {
    if (_logScheduled) return;
    _logScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _logScheduled = false;
      final delta = _pendingLogDelta;
      _pendingLogDelta = 0;
      FrameJankMonitor.logEvent(
        'ANCHOR',
        '空闲期布局位移已锚定修正 Δ${delta.toStringAsFixed(1)}px',
      );
    });
  }
}
