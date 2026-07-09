/// 预览缩放胶囊改 raw:官方 IMAGE_MARKDOWN_REGEX 语义(index 定位 +
/// `, N%` 后缀替换)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ImageRun;

ImageRun _img(int index, {double? scale}) => ImageRun(
      src: 'upload://x.jpeg',
      scale: scale ?? 100,
      previewImageIndex: index,
    );

void main() {
  test('无后缀 → 加 `, 75%`', () {
    final raw = '前文\n\n![a|690x388](upload://aaa.jpeg)\n\n后文';
    expect(
      applyImageScaleToRaw(raw, _img(0), 75),
      '前文\n\n![a|690x388, 75%](upload://aaa.jpeg)\n\n后文',
    );
  });

  test('已有 `, 50%` → 换 `, 100%`(后缀整体替换不叠加)', () {
    final raw = '![a|690x388, 50%](upload://aaa.jpeg)';
    expect(
      applyImageScaleToRaw(raw, _img(0), 100),
      '![a|690x388, 100%](upload://aaa.jpeg)',
    );
  });

  test('index 定位第 N 个 upload 图(跳过外链图)', () {
    final raw = '![外链|10x10](https://x/a.png)\n'
        '![p0|100x100](upload://p0.png)\n'
        '![p1|200x200](upload://p1.png)';
    expect(
      applyImageScaleToRaw(raw, _img(1), 50),
      '![外链|10x10](https://x/a.png)\n'
      '![p0|100x100](upload://p0.png)\n'
      '![p1|200x200, 50%](upload://p1.png)',
    );
  });

  test('alt 带竖线/额外后缀保留(第 4 捕获组段)', () {
    final raw = '![带|线的 alt|690x388, 50%|thumbnail](upload://a.jpeg)';
    expect(
      applyImageScaleToRaw(raw, _img(0), 75),
      '![带|线的 alt|690x388, 75%|thumbnail](upload://a.jpeg)',
    );
  });

  test('index 越界/缺失 → null 不动 raw', () {
    final raw = '![a|690x388](upload://aaa.jpeg)';
    expect(applyImageScaleToRaw(raw, _img(3), 75), isNull);
    expect(
      applyImageScaleToRaw(
        raw,
        const ImageRun(src: 'upload://x', scale: 100),
        75,
      ),
      isNull,
    );
  });

  test('行内 code 里的图片语法不计数(尾随反引号排除)', () {
    final raw = '`![c|10x10](upload://code.png)` 后\n'
        '![真图|100x100](upload://real.png)';
    // code 里的匹配被 (?!(.*`)) 排除 → index 0 = 真图
    expect(
      applyImageScaleToRaw(raw, _img(0), 50),
      '`![c|10x10](upload://code.png)` 后\n'
      '![真图|100x100, 50%](upload://real.png)',
    );
  });
}
