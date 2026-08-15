/// D2 守护:spoiler 遮罩效果(GPU shader 粒子)。
/// - reduce-motion(MediaQuery.disableAnimations):静态遮罩,无粒子 painter、无
///   Ticker(确保 golden/pumpAndSettle 能 settle)。
/// - 动画态:未揭示时挂 SpoilerEffectPainter(shader 粒子尘埃遮盖)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/render/spoiler_effect.dart';
import 'package:fluxdo_render/src/widget/fluxdo_render.dart';

void main() {
  Finder effectPainter() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is SpoilerEffectPainter,
  );

  const spoilerHtml = '<p>答案 <span class="spoiler">42</span> 完</p>';

  testWidgets('reduce-motion:spoiler 静态遮罩,无粒子 painter(可 settle)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => MediaQuery(
              data: MediaQuery.of(c).copyWith(disableAnimations: true),
              child: const FluxdoRender(cookedHtml: spoilerHtml),
            ),
          ),
        ),
      ),
    );
    // 能 settle(无限 Ticker 被 reduce-motion 关掉)。
    await tester.pumpAndSettle();
    expect(
      effectPainter(),
      findsNothing,
      reason: 'reduce-motion 应走静态遮罩,不挂粒子 painter',
    );
  });

  testWidgets('动画态:未揭示 spoiler 挂粒子 painter', (tester) async {
    // fromAsset 是真实异步 IO,fake-async 区内不会完成 → runAsync 预加载。
    await tester.runAsync(() => SpoilerShader.ensureLoaded());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FluxdoRender(cookedHtml: spoilerHtml)),
      ),
    );
    await tester.pump(); // 布局
    await tester.pump(const Duration(milliseconds: 16)); // 推进一帧
    expect(
      effectPainter(),
      findsWidgets,
      reason: '动画态未揭示应挂 SpoilerEffectPainter',
    );
    // 卸载以 dispose Ticker(避免活动 ticker 跨测试)。
    await tester.pumpWidget(const SizedBox());
  });
}
