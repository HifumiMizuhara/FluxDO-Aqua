// full_svg_flutter の内部 DOM / painter を使う再生最適化層。
// ignore_for_file: implementation_imports

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:full_svg_flutter/src/animation/animated_svg_painter.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_animation.dart';
import 'package:full_svg_flutter/src/animation/svg_dom.dart';

final RegExp _cssPathFnRe = RegExp(r'''^path\(\s*["']([\s\S]*)["']\s*\)$''');

/// 再生時に毎フレーム必要なノードだけを保持する索引と、静的レイヤー。
///
/// 構築時に一度だけ SVG DOM を走査し、その後の tick は opacity と d の
/// 候補ノードだけを見る。さらに z-order を保てる SVG では静的 subtree
/// を一枚の ui.Picture に録画し、毎フレームの painter から外す。
class SignatureSvgPlaybackPlan {
  SignatureSvgPlaybackPlan({
    required this.document,
    required List<SmilAnimation> animations,
  }) {
    _indexTargets(animations);
    _buildLayerPlan(animations);
  }

  final SvgDocument document;

  final List<SvgNode> _opacityCandidates = <SvgNode>[];
  final List<SvgNode> _pathCandidates = <SvgNode>[];
  final Map<SvgNode, AnimatableSvgAttribute?> _opacityDisplayOverrides =
      <SvgNode, AnimatableSvgAttribute?>{};

  final List<SvgNode> _staticCutRoots = <SvgNode>[];
  final List<SvgNode> _dynamicRoots = <SvgNode>[];
  final Map<SvgNode, AnimatableSvgAttribute?> _staticDisplayOverrides =
      <SvgNode, AnimatableSvgAttribute?>{};

  bool _layeringEnabled = false;
  ui.Picture? _staticPicture;
  ui.Size? _staticPictureSize;

  bool get layeringEnabled => _layeringEnabled;
  int get debugOpacityCandidateCount => _opacityCandidates.length;
  int get debugPathCandidateCount => _pathCandidates.length;
  int get debugStaticCutCount => _staticCutRoots.length;

  void _indexTargets(List<SmilAnimation> animations) {
    final opacitySet = <SvgNode>{};
    final pathSet = <SvgNode>{};

    // 静的 opacity=0 も一度だけ索引する。従来はこれを毎 tick 全木走査
    // していたため、数百ノードの署名ほどコストが線形に増えていた。
    void walk(SvgNode node) {
      if (node.getAttribute('opacity') != null) opacitySet.add(node);
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(document.root);

    for (final animation in animations) {
      final name = animation.attributeName.toLowerCase();
      if (name == 'opacity' || name == 'style') {
        opacitySet.add(animation.targetNode);
      }
      if (name == 'd') {
        pathSet.add(animation.targetNode);
      }
    }

    _opacityCandidates.addAll(opacitySet);
    _pathCandidates.addAll(pathSet);
  }

  /// timeline.seek() 後に呼ぶ。計算量は SVG 全ノード数ではなく、実際に
  /// opacity/d を更新し得る候補数に比例する。
  void syncAfterSeek() {
    for (final node in _opacityCandidates) {
      final value = node.getAttributeValue('opacity');
      final opacity = value is num
          ? value.toDouble()
          : double.tryParse(value?.toString() ?? '');
      final shouldHide = opacity != null && opacity <= 0.01;
      final hiddenNow = _opacityDisplayOverrides.containsKey(node);

      if (shouldHide && !hiddenNow) {
        _opacityDisplayOverrides[node] = node.getAttribute('display');
        node.setAttribute('display', 'none', rawValue: 'none');
      } else if (!shouldHide && hiddenNow) {
        _restoreDisplay(node, _opacityDisplayOverrides.remove(node));
      }
    }

    for (final node in _pathCandidates) {
      final attr = node.getAttribute('d');
      final value = attr?.effectiveValue;
      if (value is! String) continue;
      final match = _cssPathFnRe.firstMatch(value.trim());
      if (match != null) attr!.setAnimatedValue(match.group(1)!);
    }
  }

  void _buildLayerPlan(List<SmilAnimation> animations) {
    if (animations.isEmpty) return;

    final root = document.root;
    final rootStyle = root.getAttributeValue('style')?.toString().toLowerCase();
    if (root.getAttributeValue('background-color') != null ||
        (rootStyle?.contains('background-color') ?? false)) {
      return;
    }

    final targets = animations.map((a) => a.targetNode).toSet();
    if (targets.contains(root)) return;

    const definitionTags = <String>{
      'defs',
      'linearGradient',
      'radialGradient',
      'filter',
      'mask',
      'clipPath',
      'pattern',
      'marker',
    };

    // 定义側の动画は複数の見かけ上静的なノードへ波及し得るため分離しない。
    for (final target in targets) {
      SvgNode? cursor = target;
      while (cursor != null && !identical(cursor, root)) {
        if (definitionTags.contains(cursor.tagName)) return;
        cursor = cursor.parent;
      }
    }

    final dynamicAncestors = <SvgNode>{root};
    for (final target in targets) {
      SvgNode? cursor = target;
      while (cursor != null) {
        dynamicAncestors.add(cursor);
        if (identical(cursor, root)) break;
        cursor = cursor.parent;
      }
    }

    // target の中に target が入る場合、外側だけ隠せば静的 picture から
    // 動的 subtree 全体を除外できる。
    for (final target in targets) {
      var hasTargetAncestor = false;
      SvgNode? parent = target.parent;
      while (parent != null && !identical(parent, root)) {
        if (targets.contains(parent)) {
          hasTargetAncestor = true;
          break;
        }
        parent = parent.parent;
      }
      if (!hasTargetAncestor) _dynamicRoots.add(target);
    }

    var safeOrder = true;

    void collectCuts(SvgNode node) {
      if (targets.contains(node)) return; // target subtree は全部动态扱い
      var seenDynamicChild = false;
      for (final child in node.children) {
        final dynamic = dynamicAncestors.contains(child);
        if (dynamic) {
          seenDynamicChild = true;
          collectCuts(child);
        } else {
          // 静的要素が動的要素の後ろにあると、static picture→dynamic の
          // 二層合成で z-order が逆転するので分離を無効化する。
          if (seenDynamicChild) safeOrder = false;
          _staticCutRoots.add(child);
        }
      }
    }

    collectCuts(root);
    _layeringEnabled =
        safeOrder && _dynamicRoots.isNotEmpty && _staticCutRoots.isNotEmpty;
    if (!_layeringEnabled) {
      _dynamicRoots.clear();
      _staticCutRoots.clear();
    }
  }

  void paint(ui.Canvas canvas, ui.Size size, AnimatedSvgPainter livePainter) {
    if (!_layeringEnabled) {
      livePainter.paint(canvas, size);
      return;
    }

    _ensureStaticPicture(size);
    final picture = _staticPicture;
    if (picture != null) canvas.drawPicture(picture);
    livePainter.paint(canvas, size);
  }

  void _ensureStaticPicture(ui.Size size) {
    if (_staticPicture != null && _staticPictureSize == size) return;

    _restoreStaticCuts();
    _staticPicture?.dispose();
    _staticPicture = null;
    _staticPictureSize = null;

    final dynamicOverrides = <SvgNode, AnimatableSvgAttribute?>{};
    for (final node in _dynamicRoots) {
      dynamicOverrides[node] = node.getAttribute('display');
      node.setAttribute('display', 'none', rawValue: 'none');
    }

    final recorder = ui.PictureRecorder();
    try {
      AnimatedSvgPainter(
        document: document,
        hasAnimations: false,
        animationTime: 0.0,
        clipToViewBox: true,
      ).paint(ui.Canvas(recorder), size);
      _staticPicture = recorder.endRecording();
      _staticPictureSize = size;
    } catch (_) {
      // endRecording 前の例外でも recorder を閉じる。以後は全描画へ退避。
      try {
        recorder.endRecording().dispose();
      } catch (_) {}
      _layeringEnabled = false;
      _staticPicture?.dispose();
      _staticPicture = null;
      _staticPictureSize = null;
    } finally {
      for (final entry in dynamicOverrides.entries) {
        _restoreDisplay(entry.key, entry.value);
      }
    }

    if (!_layeringEnabled) return;

    // 静的 subtree は picture に入ったので live painter から恒久的に外す。
    for (final node in _staticCutRoots) {
      _staticDisplayOverrides[node] = node.getAttribute('display');
      node.setAttribute('display', 'none', rawValue: 'none');
    }
  }

  void _restoreStaticCuts() {
    for (final entry in _staticDisplayOverrides.entries) {
      _restoreDisplay(entry.key, entry.value);
    }
    _staticDisplayOverrides.clear();
  }

  void _restoreDisplay(SvgNode node, AnimatableSvgAttribute? original) {
    if (original == null) {
      node.attributes.remove('display');
    } else {
      node.attributes['display'] = original;
    }
  }

  void dispose() {
    _restoreStaticCuts();
    for (final entry in _opacityDisplayOverrides.entries) {
      _restoreDisplay(entry.key, entry.value);
    }
    _opacityDisplayOverrides.clear();
    _staticPicture?.dispose();
    _staticPicture = null;
    _staticPictureSize = null;
  }
}

/// repaint Listenable から直接再描画する播放器。delegate の生存中は
/// AnimatedSvgPainter 自体も使い回し、内部 render cache を毎 tick 捨てない。
class SignatureSvgPlayerPainter extends CustomPainter {
  SignatureSvgPlayerPainter({
    required this.document,
    required this.plan,
    required Listenable repaint,
  }) : _livePainter = AnimatedSvgPainter(
         document: document,
         hasAnimations: true,
         animationTime: 0.0,
         clipToViewBox: true,
       ),
       super(repaint: repaint);

  final SvgDocument document;
  final SignatureSvgPlaybackPlan plan;
  final AnimatedSvgPainter _livePainter;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    plan.paint(canvas, size, _livePainter);
  }

  @override
  bool shouldRepaint(SignatureSvgPlayerPainter oldDelegate) =>
      !identical(oldDelegate.document, document) ||
      !identical(oldDelegate.plan, plan);
}
