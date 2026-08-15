/// hashtag(`#ref`)在编辑器里是**行内原子**(emoji/mention 同机制):
/// 模型里只占一个 FFFC,渲染成图标+名称药丸,序列化写回 `#ref` 而不是
/// 普通链接语法(写成 `[#x](/c/x)` 往返后就退化成死链接了)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_block.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  const hashtag = LinkRun(
    href: '/c/dev/4',
    hashtagRef: 'dev',
    children: [TextRun('#开发调优')],
  );

  test('hashtag 进编辑白名单(原子化,不再整段岛化)', () {
    expect(isEditableInline(hashtag), isTrue);
  });

  test('flatten 成 1 个哨兵字符 + 原子表身份', () {
    final c = EditableTextContent.fromInlines([
      const TextRun('看看 '),
      hashtag,
      const TextRun(' 板块'),
    ]);

    expect(c.text, '看看 ￼ 板块');
    expect(c.atoms[3], isA<LinkRun>());
    expect((c.atoms[3]! as LinkRun).hashtagRef, 'dev');
  });

  test('序列化写回 #ref 而不是链接语法', () {
    final c = EditableTextContent.fromInlines([const TextRun('看看 '), hashtag]);
    final md = docToMarkdown([TextBlock(id: 'b0', content: c)]);

    expect(md.trim(), '看看 #dev');
  });

  test('带消歧后缀的标签 ref 原样写回', () {
    final c = EditableTextContent.fromInlines([
      const LinkRun(
        href: '/tag/dev',
        hashtagRef: 'dev::tag',
        children: [TextRun('#dev')],
      ),
    ]);

    expect(
      docToMarkdown([TextBlock(id: 'b0', content: c)]).trim(),
      '#dev::tag',
    );
  });
}
