import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/projection.dart';

void main() {
  // 模拟一个含行内代码的段落:
  //   文本: "说 [pad]`var x`[pad] 完"
  //   render:  说(0)空(1) pad(2) v a r 空 x (3..7) pad(8) 空(9) 完(10)
  //   logical: 说 空 v a r 空 x 空 完   (pad 逻辑长 0)
  final proj = RenderTextProjection(const [
    ProjectionEntry(
      renderStart: 0,
      renderLen: 2,
      logicalText: '说 ',
      kind: ProjectionKind.text,
    ),
    ProjectionEntry(
      renderStart: 2,
      renderLen: 1,
      logicalText: '',
      kind: ProjectionKind.codePad,
    ),
    ProjectionEntry(
      renderStart: 3,
      renderLen: 5,
      logicalText: 'var x',
      kind: ProjectionKind.inlineCode,
    ),
    ProjectionEntry(
      renderStart: 8,
      renderLen: 1,
      logicalText: '',
      kind: ProjectionKind.codePad,
    ),
    ProjectionEntry(
      renderStart: 9,
      renderLen: 2,
      logicalText: ' 完',
      kind: ProjectionKind.text,
    ),
  ]);

  group('renderOffsetForContent', () {
    test('文本段线性', () {
      expect(proj.renderOffsetForContent(0), 0);
      expect(proj.renderOffsetForContent(1), 1);
    });

    test('跳过 codePad(NBSP 粘性内边距)', () {
      // logical 2 = 'v' 起点 → render 3(跳过 pad@2)
      expect(proj.renderOffsetForContent(2), 3);
      expect(proj.renderOffsetForContent(4), 5);
    });

    test('代码段末与后续文本', () {
      // logical 7 = 'var x' 后(= ' 完' 起点)→ render 9(跳过 pad@8)
      expect(proj.renderOffsetForContent(7), 9);
      expect(proj.renderOffsetForContent(9), 11);
    });

    test('越界 clamp', () {
      expect(proj.renderOffsetForContent(-5), 0);
      expect(proj.renderOffsetForContent(999), proj.renderLength);
    });
  });

  group('contentOffsetForRender', () {
    test('文本段线性', () {
      expect(proj.contentOffsetForRender(0), 0);
      expect(proj.contentOffsetForRender(2), 2);
    });

    test('codePad 归到其前逻辑位置', () {
      // render 2(pad 内部)→ logical 2;render 3('v')→ logical 2
      expect(proj.contentOffsetForRender(3), 2);
      expect(proj.contentOffsetForRender(8), 7);
      expect(proj.contentOffsetForRender(9), 7);
    });

    test('两方向往返(文本位置)', () {
      for (final logical in [0, 1, 2, 5, 7, 8, 9]) {
        final render = proj.renderOffsetForContent(logical);
        expect(
          proj.contentOffsetForRender(render),
          logical,
          reason: 'logical=$logical → render=$render 应可逆',
        );
      }
    });
  });

  group('原子占位符(M2:emoji/mention 内容宽 1 = 一个 FFFC 哨兵)', () {
    // "a[emoji]b": render a(0) ￼(1) b(2);内容 a ￼ b(宽 3)
    final atomProj = RenderTextProjection(const [
      ProjectionEntry(
        renderStart: 0,
        renderLen: 1,
        logicalText: 'a',
        kind: ProjectionKind.text,
      ),
      ProjectionEntry(
        renderStart: 1,
        renderLen: 1,
        logicalText: ':heart:',
        kind: ProjectionKind.emoji,
      ),
      ProjectionEntry(
        renderStart: 2,
        renderLen: 1,
        logicalText: 'b',
        kind: ProjectionKind.text,
      ),
    ]);

    test('contentLength:原子计 1', () {
      expect(atomProj.contentLength, 3);
    });

    test('内容→渲染:原子前后各 1', () {
      expect(atomProj.renderOffsetForContent(0), 0);
      expect(atomProj.renderOffsetForContent(1), 1); // 原子前
      expect(atomProj.renderOffsetForContent(2), 2); // 原子后
      expect(atomProj.renderOffsetForContent(3), 3);
    });

    test('渲染→内容:严格双射', () {
      for (var c = 0; c <= 3; c++) {
        final r = atomProj.renderOffsetForContent(c);
        expect(
          atomProj.contentOffsetForRender(r),
          c,
          reason: 'content=$c → render=$r 应可逆',
        );
      }
    });

    test('投影空间不受影响(复制仍出 :heart:)', () {
      expect(atomProj.projectAll(), 'a:heart:b');
      expect(atomProj.logicalLength, 9);
    });
  });

  group('混排双射(emoji+mention+行内代码+ZWSP)', () {
    // 内容: "hi ￼ @x前 [var x] ab"(原子宽1;代码段带 codePad;文本带 ZWSP)
    // render: h i ␠ ￼ ␠ ￼ pad v a r ␠ x pad a ​ b
    final proj = RenderTextProjection(const [
      ProjectionEntry(
        renderStart: 0,
        renderLen: 3,
        logicalText: 'hi ',
        kind: ProjectionKind.text,
      ),
      ProjectionEntry(
        renderStart: 3,
        renderLen: 1,
        logicalText: ':smile:',
        kind: ProjectionKind.emoji,
      ),
      ProjectionEntry(
        renderStart: 4,
        renderLen: 1,
        logicalText: ' ',
        kind: ProjectionKind.text,
      ),
      ProjectionEntry(
        renderStart: 5,
        renderLen: 1,
        logicalText: '@sam',
        kind: ProjectionKind.mention,
      ),
      ProjectionEntry(
        renderStart: 6,
        renderLen: 1,
        logicalText: '',
        kind: ProjectionKind.codePad,
      ),
      ProjectionEntry(
        renderStart: 7,
        renderLen: 5,
        logicalText: 'var x',
        kind: ProjectionKind.inlineCode,
      ),
      ProjectionEntry(
        renderStart: 12,
        renderLen: 1,
        logicalText: '',
        kind: ProjectionKind.codePad,
      ),
      ProjectionEntry(
        renderStart: 13,
        renderLen: 3,
        logicalText: 'a​b',
        kind: ProjectionKind.text,
      ),
    ]);

    test('contentLength = 3+1+1+1+5+2 = 13', () {
      expect(proj.contentLength, 13);
    });

    test('全偏移双向往返', () {
      for (var c = 0; c <= proj.contentLength; c++) {
        final r = proj.renderOffsetForContent(c);
        expect(
          proj.contentOffsetForRender(r),
          c,
          reason: 'content=$c → render=$r 应可逆',
        );
      }
    });
  });

  group('软换行 ZWSP(内容空间 vs 渲染空间 —— 长文本光标错乱的回归)', () {
    // 渲染文本 "ab​cd​ef"(soft_break 注入),内容 = "abcdef"
    final zwspProj = RenderTextProjection(const [
      ProjectionEntry(
        renderStart: 0,
        renderLen: 8,
        logicalText: 'ab​cd​ef',
        kind: ProjectionKind.text,
      ),
    ]);

    test('contentLength 不含 ZWSP', () {
      expect(zwspProj.renderLength, 8);
      expect(zwspProj.contentLength, 6);
    });

    test('内容→渲染:偏移跳过 ZWSP', () {
      expect(zwspProj.renderOffsetForContent(0), 0);
      expect(zwspProj.renderOffsetForContent(2), 2); // 'ab' 后(ZWSP 前)
      expect(zwspProj.renderOffsetForContent(3), 4); // 'c' 后(跳过 ZWSP)
      expect(zwspProj.renderOffsetForContent(4), 5); // 'd' 后
      expect(zwspProj.renderOffsetForContent(6), 8); // 段末
    });

    test('渲染→内容:ZWSP 不计数(旧 bug:直接减导致越界 clamp 到段尾)', () {
      expect(zwspProj.contentOffsetForRender(0), 0);
      expect(zwspProj.contentOffsetForRender(2), 2);
      expect(zwspProj.contentOffsetForRender(3), 2); // ZWSP 上 → 归前
      expect(zwspProj.contentOffsetForRender(4), 3); // 'c' 之后
      expect(zwspProj.contentOffsetForRender(8), 6);
    });

    test('往返可逆(内容位置)', () {
      for (var c = 0; c <= 6; c++) {
        final r = zwspProj.renderOffsetForContent(c);
        expect(
          zwspProj.contentOffsetForRender(r),
          c,
          reason: 'content=$c → render=$r 应可逆',
        );
      }
    });
  });
}
