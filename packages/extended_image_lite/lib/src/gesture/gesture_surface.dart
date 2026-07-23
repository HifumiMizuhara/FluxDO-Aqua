import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../typedef.dart';
import '../utils.dart';
import 'gesture_controller.dart';
import 'page_view/gesture_page_view.dart';
import 'slide_page.dart';
import 'utils.dart';

/// 双击回调(新架构:回传常驻手势层 State)
typedef SurfaceDoubleTap = void Function(GestureSurfaceState state);

/// 常驻手势层 —— 查看器会话内一次挂载、终身不换的事件载体。
///
/// 替代旧架构中会随 LoadState 树切换销毁的两个载体
/// (ExtendedImageGesture / ExtendedImageSlidePageHandler):
/// 手势结果全部写入 [ImageGestureController],绘制层监听 controller
/// 重绘;载体不死,rebindSlideTarget/dispose 兜底等补丁失去存在必要。
///
/// 手势处理逻辑(缩放/平移/slide 仲裁/PageView 让渡/惯性边界)自
/// gesture.dart 的 ExtendedImageGestureState 逐段搬运,物理与仲裁
/// 数值零改动;唯一差异是状态读写从 State 字段换成 controller。
class GestureSurface extends StatefulWidget {
  const GestureSurface({
    super.key,
    required this.controller,
    required this.child,
    this.onDoubleTap,
    CanScaleImage? canScaleImage,
    this.enableSlideOutPage = false,
    this.inPageView = false,
  }) : canScaleImage = canScaleImage ?? _defaultCanScaleImage;

  final ImageGestureController controller;
  final Widget child;
  final SurfaceDoubleTap? onDoubleTap;
  final CanScaleImage canScaleImage;

  /// 是否参与祖先 ExtendedImageSlidePage 的下滑关闭
  final bool enableSlideOutPage;

  /// 是否在 ExtendedImageGesturePageView 中(需要注册仲裁)
  final bool inPageView;

  static bool _defaultCanScaleImage(GestureDetails? details) => true;

  @override
  GestureSurfaceState createState() => GestureSurfaceState();
}

class GestureSurfaceState extends State<GestureSurface>
    with TickerProviderStateMixin
    implements DoubleTapTarget, GesturePageViewArbiter {
  late Offset _normalizedOffset;
  double? _startingScale;
  late Offset _startingOffset;
  Offset? _pointerDownPosition;
  late GestureAnimation _gestureAnimation;

  ExtendedImageSlidePageState? _slidePageState;
  ExtendedImageGesturePageViewState? _pageViewState;

  ImageGestureController get controller => widget.controller;
  GestureConfig get _gestureConfig => controller.config;

  @override
  GestureDetails? get gestureDetails => controller.details;

  @override
  set gestureDetails(GestureDetails? value) {
    controller.details = value;
  }

  @override
  Offset? get pointerDownPosition => _pointerDownPosition;

  ExtendedImageSlidePageState? get extendedImageSlidePageState =>
      _slidePageState;

  @override
  void initState() {
    super.initState();
    _gestureAnimation = GestureAnimation(
      this,
      offsetCallBack: (Offset value) {
        gestureDetails = GestureDetails(
          offset: value,
          totalScale: gestureDetails!.totalScale,
          gestureDetails: gestureDetails,
        );
      },
      scaleCallBack: (double scale) {
        gestureDetails = GestureDetails(
          offset: gestureDetails!.offset,
          totalScale: scale,
          gestureDetails: gestureDetails,
          actionType: ActionType.zoom,
          userOffset: false,
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slidePageState = null;
    if (widget.enableSlideOutPage) {
      _slidePageState =
          context.findAncestorStateOfType<ExtendedImageSlidePageState>();
    }
    _pageViewState = null;
    if (widget.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.registerArbiter(this);
    }
  }

  @override
  void dispose() {
    _gestureAnimation.stop();
    _gestureAnimation.dispose();
    _pageViewState?.unregisterArbiter(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget result = GestureDetector(
      onScaleStart: handleScaleStart,
      onScaleUpdate: handleScaleUpdate,
      onScaleEnd: handleScaleEnd,
      onDoubleTap: _handleDoubleTap,
      behavior: _gestureConfig.hitTestBehavior,
      child: widget.child,
    );

    result = Listener(
      onPointerDown: _handlePointerDown,
      onPointerSignal: _handlePointerSignal,
      behavior: _gestureConfig.hitTestBehavior,
      child: result,
    );

    return result;
  }

  // ===== DoubleTapTarget =====

  @override
  void handleDoubleTap({double? scale, Offset? doubleTapPosition}) {
    doubleTapPosition ??= _pointerDownPosition;
    scale ??= _gestureConfig.initialScale;
    handleScaleStart(ScaleStartDetails(focalPoint: doubleTapPosition!));
    handleScaleUpdate(
      ScaleUpdateDetails(
        focalPoint: doubleTapPosition,
        scale: scale / _startingScale!,
        focalPointDelta: Offset.zero,
      ),
    );
    if (scale < _gestureConfig.minScale || scale > _gestureConfig.maxScale) {
      handleScaleEnd(ScaleEndDetails());
    }
  }

  void _handleDoubleTap() {
    if (widget.onDoubleTap != null) {
      widget.onDoubleTap!(this);
      return;
    }
    if (!mounted) {
      return;
    }
    gestureDetails = GestureDetails(
      offset: Offset.zero,
      totalScale: _gestureConfig.initialScale,
    );
  }

  // ===== 指针事件 =====

  void _handlePointerDown(PointerDownEvent pointerDownEvent) {
    _pointerDownPosition = pointerDownEvent.position;
    _gestureAnimation.stop();
    _pageViewState?.registerArbiter(this);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.kind == PointerDeviceKind.mouse) {
      handleScaleStart(ScaleStartDetails(focalPoint: event.position));
      final double dy = event.scrollDelta.dy;
      final double dx = event.scrollDelta.dx;
      handleScaleUpdate(
        ScaleUpdateDetails(
          focalPoint: event.position,
          scale:
              1.0 +
              _reverseIf(
                (dy.abs() > dx.abs() ? dy : dx) * _gestureConfig.speed / 1000.0,
              ),
          focalPointDelta: Offset.zero,
        ),
      );
      handleScaleEnd(ScaleEndDetails());
    }
  }

  double _reverseIf(double scaleDetal) {
    if (_gestureConfig.reverseMousePointerScrollDirection) {
      return -scaleDetal;
    } else {
      return scaleDetal;
    }
  }

  // ===== 缩放/平移状态机(自 ExtendedImageGestureState 逐段搬运)=====

  @override
  void handleScaleStart(ScaleStartDetails details) {
    _gestureAnimation.stop();
    _normalizedOffset =
        (details.focalPoint - gestureDetails!.offset!) /
        gestureDetails!.totalScale!;
    _startingScale = gestureDetails!.totalScale;
    _startingOffset = details.focalPoint;
  }

  @override
  void handleScaleUpdate(ScaleUpdateDetails details) {
    if (_slidePageState != null &&
        details.scale == 1.0 &&
        (gestureDetails!.totalScale ?? 1) <= 1 &&
        gestureDetails!.userOffset &&
        gestureDetails!.actionType == ActionType.pan) {
      final Offset totalDelta = details.focalPointDelta;
      bool updateGesture = false;
      if (!_slidePageState!.isSliding) {
        final slideAxis = _slidePageState!.widget.slideAxis;
        // 水平方向主导：仅当 slideAxis 包含水平方向时才触发 slide
        if (slideAxis != SlideAxis.vertical &&
            totalDelta.dx != 0 &&
            totalDelta.dx.abs().greaterThan(totalDelta.dy.abs())) {
          if (gestureDetails!.computeHorizontalBoundary) {
            if (totalDelta.dx > 0) {
              updateGesture = gestureDetails!.boundary.left;
            } else {
              updateGesture = gestureDetails!.boundary.right;
            }
          } else {
            updateGesture = true;
          }
        }
        // 垂直方向主导：仅当 slideAxis 包含垂直方向时才触发 slide
        if (slideAxis != SlideAxis.horizontal &&
            totalDelta.dy != 0 &&
            totalDelta.dy.abs().greaterThan(totalDelta.dx.abs())) {
          if (gestureDetails!.computeVerticalBoundary) {
            if (totalDelta.dy < 0) {
              updateGesture = gestureDetails!.boundary.bottom;
            } else {
              updateGesture = gestureDetails!.boundary.top;
            }
          } else {
            updateGesture = true;
          }
        }
      } else {
        updateGesture = true;
      }
      final double delta = (details.focalPoint - _startingOffset).distance;
      if (delta.greaterThan(minGesturePageDelta) && updateGesture) {
        _slidePageState!.slide(details.focalPointDelta, controller: controller);
      }
    }

    if (_slidePageState != null && _slidePageState!.isSliding) {
      return;
    }

    // totalScale > 1 and page view is starting to move
    if (_pageViewState != null) {
      final ExtendedImageGesturePageViewState pageViewState = _pageViewState!;

      final Axis axis = pageViewState.widget.scrollDirection;
      final bool movePage =
          _pageViewState!.isDraging ||
          (details.pointerCount == 1 &&
              details.scale == 1 &&
              gestureDetails!.movePage(details.focalPointDelta, axis));

      if (movePage) {
        if (!pageViewState.isDraging) {
          pageViewState.onDragDown(
            DragDownDetails(globalPosition: details.focalPoint),
          );
          pageViewState.onDragStart(
            DragStartDetails(globalPosition: details.focalPoint),
          );
        }
        Offset delta = details.focalPointDelta;
        delta =
            axis == Axis.horizontal ? Offset(delta.dx, 0) : Offset(0, delta.dy);

        pageViewState.onDragUpdate(
          DragUpdateDetails(
            globalPosition: details.focalPoint,
            delta: delta,
            primaryDelta: axis == Axis.horizontal ? delta.dx : delta.dy,
          ),
        );

        return;
      }
    }
    final double? scale =
        widget.canScaleImage(gestureDetails)
            ? clampScale(
              _startingScale! * details.scale * _gestureConfig.speed,
              _gestureConfig.animationMinScale,
              _gestureConfig.animationMaxScale,
            )
            : gestureDetails!.totalScale;

    //no more zoom
    if (details.scale != 1.0 &&
        ((gestureDetails!.totalScale!.equalTo(
                  _gestureConfig.animationMinScale,
                ) &&
                scale!.lessThanOrEqualTo(gestureDetails!.totalScale!)) ||
            (gestureDetails!.totalScale!.equalTo(
                  _gestureConfig.animationMaxScale,
                ) &&
                scale!.greaterThanOrEqualTo(gestureDetails!.totalScale!)))) {
      return;
    }

    Offset offset =
        (details.scale == 1.0
            ? details.focalPoint * _gestureConfig.speed
            : _startingOffset) -
        _normalizedOffset * scale!;

    if (mounted &&
        (offset != gestureDetails!.offset ||
            scale != gestureDetails!.totalScale)) {
      gestureDetails = GestureDetails(
        offset: offset,
        totalScale: scale,
        gestureDetails: gestureDetails,
        actionType: details.scale != 1.0 ? ActionType.zoom : ActionType.pan,
      );
    }
  }

  @override
  void handleScaleEnd(ScaleEndDetails details) {
    if (_slidePageState != null && _slidePageState!.isSliding) {
      _slidePageState!.endSlide(details);
      return;
    }

    if (_pageViewState != null && _pageViewState!.isDraging) {
      _pageViewState!.onDragEnd(
        DragEndDetails(
          velocity:
              _pageViewState!.widget.scrollDirection == Axis.horizontal
                  ? Velocity(
                    pixelsPerSecond: Offset(
                      details.velocity.pixelsPerSecond.dx,
                      0,
                    ),
                  )
                  : Velocity(
                    pixelsPerSecond: Offset(
                      0,
                      details.velocity.pixelsPerSecond.dy,
                    ),
                  ),
          primaryVelocity:
              _pageViewState!.widget.scrollDirection == Axis.horizontal
                  ? details.velocity.pixelsPerSecond.dx
                  : details.velocity.pixelsPerSecond.dy,
        ),
      );
      return;
    }

    //animate back to maxScale if gesture exceeded the maxScale specified
    if (gestureDetails!.totalScale!.greaterThan(_gestureConfig.maxScale)) {
      final double velocity =
          (gestureDetails!.totalScale! - _gestureConfig.maxScale) /
          _gestureConfig.maxScale;

      _gestureAnimation.animationScale(
        gestureDetails!.totalScale,
        _gestureConfig.maxScale,
        velocity,
      );
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (gestureDetails!.totalScale!.lessThan(_gestureConfig.minScale)) {
      final double velocity =
          (_gestureConfig.minScale - gestureDetails!.totalScale!) /
          _gestureConfig.minScale;

      _gestureAnimation.animationScale(
        gestureDetails!.totalScale,
        _gestureConfig.minScale,
        velocity,
      );
      return;
    }

    // ===== 惯性滑动处理 =====
    if (gestureDetails!.actionType == ActionType.pan) {
      final layoutRect = gestureDetails!.layoutRect;
      final destinationRect = gestureDetails!.destinationRect;
      final currentOffset = gestureDetails!.offset!;
      final physics = _gestureConfig.inertiaPhysics;

      // 处理惯性滑动
      final double magnitude = details.velocity.pixelsPerSecond.distance;

      if (magnitude >= physics.minVelocity &&
          layoutRect != null &&
          destinationRect != null) {
        // 基于当前 destinationRect 与 layoutRect 的相对位置计算边界
        double minX, maxX, minY, maxY;

        if (destinationRect.width > layoutRect.width) {
          // 图片比视口宽，计算允许的滑动范围
          // 往左滑动（offset.dx 减小）的极限：图片右边与视口右边对齐
          minX = currentOffset.dx - (destinationRect.right - layoutRect.right);
          // 往右滑动（offset.dx 增大）的极限：图片左边与视口左边对齐
          maxX = currentOffset.dx + (layoutRect.left - destinationRect.left);
        } else {
          // 图片比视口窄，不允许水平滑动
          minX = currentOffset.dx;
          maxX = currentOffset.dx;
        }

        if (destinationRect.height > layoutRect.height) {
          // 图片比视口高，计算允许的滑动范围
          // 往上滑动（offset.dy 减小）的极限：图片底边与视口底边对齐
          minY =
              currentOffset.dy - (destinationRect.bottom - layoutRect.bottom);
          // 往下滑动（offset.dy 增大）的极限：图片顶边与视口顶边对齐
          maxY = currentOffset.dy + (layoutRect.top - destinationRect.top);
        } else {
          // 图片比视口矮，不允许垂直滑动
          minY = currentOffset.dy;
          maxY = currentOffset.dy;
        }

        // 启动惯性滑动动画
        _gestureAnimation.animateInertia(
          currentOffset,
          details.velocity.pixelsPerSecond,
          physics,
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
        );
      }
    }
  }
}
