import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser policy 识别', () {
    test('最简 div.policy → PolicyNode + children 递归', () {
      final result = parser.parse(
        '<div class="policy" data-version="1">'
        '<p>policy 正文</p>'
        '</div>',
      );
      expect(result, hasLength(1));
      final p = result[0] as PolicyNode;
      expect(p.version, '1');
      expect(p.children, hasLength(1));
      expect(p.children[0], isA<ParagraphNode>());
    });

    test('提取 全套 data-* 属性', () {
      final result = parser.parse(
        '<div class="policy" '
        'data-version="2" '
        'data-groups="staff,trust_level_3" '
        'data-accept="同意" '
        'data-revoke="拒绝" '
        'data-renewal-days="30" '
        'data-renewal-start="2026-01-01" '
        'data-reminder="weekly" '
        'data-private="true">'
        '<p>x</p></div>',
      );
      final p = result[0] as PolicyNode;
      expect(p.version, '2');
      expect(p.groups, 'staff,trust_level_3');
      expect(p.acceptLabel, '同意');
      expect(p.revokeLabel, '拒绝');
      expect(p.renewalDays, '30');
      expect(p.renewalStart, '2026-01-01');
      expect(p.reminder, 'weekly');
      expect(p.isPrivate, isTrue);
    });

    test('.policy-body 单层包裹 → 剥外层 div 后递归内层', () {
      final result = parser.parse(
        '<div class="policy">'
        '<div class="policy-body">'
        '<p>内层段</p>'
        '<ul><li>项</li></ul>'
        '</div></div>',
      );
      final p = result[0] as PolicyNode;
      expect(p.children, hasLength(2));
      expect(p.children[0], isA<ParagraphNode>());
      expect(p.children[1], isA<ListNode>());
    });

    test('无 .policy-body → 直接递归 div.policy 自身子节点', () {
      final result = parser.parse(
        '<div class="policy">'
        '<p>直接正文</p>'
        '<blockquote><p>引用</p></blockquote>'
        '</div>',
      );
      final p = result[0] as PolicyNode;
      expect(p.children, hasLength(2));
      expect(p.children[0], isA<ParagraphNode>());
      expect(p.children[1], isA<BlockquoteNode>());
    });

    test('data-private 非 "true" → isPrivate=false', () {
      final r1 = parser.parse(
        '<div class="policy" data-private="false"><p>x</p></div>',
      );
      final r2 = parser.parse('<div class="policy"><p>x</p></div>');
      expect((r1[0] as PolicyNode).isPrivate, isFalse);
      expect((r2[0] as PolicyNode).isPrivate, isFalse);
    });

    test('空属性 → null', () {
      final result = parser.parse(
        '<div class="policy" data-accept="" data-revoke="   "><p>x</p></div>',
      );
      final p = result[0] as PolicyNode;
      expect(p.acceptLabel, isNull);
      expect(p.revokeLabel, isNull);
    });

    test('普通 div 不会被识别', () {
      final result = parser.parse('<div><p>x</p></div>');
      expect(result.whereType<PolicyNode>(), isEmpty);
    });

    test('countImageRuns 递归 policy.children 计图', () {
      final result = parser.parse(
        '<p><img src="outside.png"></p>'
        '<div class="policy"><p><img src="inside.png"></p></div>',
      );
      expect(countImageRuns(result), 2);
    });

    test('id 唯一', () {
      final result = parser.parse(
        '<div class="policy"><p>a</p></div>'
        '<div class="policy"><p>b</p></div>',
      );
      expect(result, hasLength(2));
      final p1 = result[0] as PolicyNode;
      final p2 = result[1] as PolicyNode;
      expect(p1.id, isNot(p2.id));
    });

    test('policy 内嵌 callout 等复杂块也能 parse', () {
      final result = parser.parse(
        '<div class="policy">'
        '<p>引言</p>'
        '<blockquote><p>[!warning] 重要<br>注意事项</p></blockquote>'
        '</div>',
      );
      final p = result[0] as PolicyNode;
      expect(p.children, hasLength(2));
      // blockquote 中的 callout 应被识别
      expect(p.children[1], isA<CalloutNode>());
    });
  });
}
