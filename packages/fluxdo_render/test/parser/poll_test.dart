import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser poll 识别', () {
    test('基础 div.poll → PollNode + 默认 pollName', () {
      final result = parser.parse(
        '<div class="poll" data-poll-name="poll">'
        '<ul><li>A</li><li>B</li></ul>'
        '</div>',
      );
      expect(result, hasLength(1));
      final p = result[0] as PollNode;
      expect(p.pollName, 'poll');
      expect(p.rawHtml, contains('data-poll-name'));
    });

    test('自定义 data-poll-name', () {
      final result = parser.parse(
        '<div class="poll" data-poll-name="favorite"><ul><li>x</li></ul></div>',
      );
      expect((result[0] as PollNode).pollName, 'favorite');
    });

    test('无 data-poll-name → 默认 "poll"', () {
      final result = parser.parse(
        '<div class="poll"><ul><li>x</li></ul></div>',
      );
      expect((result[0] as PollNode).pollName, 'poll');
    });

    test('标题优先级:data-poll-question 最高', () {
      final result = parser.parse(
        '<div class="poll" data-poll-question="问题Q" data-poll-title="标题T">'
        '<div class="poll-title">DOM标题</div>'
        '</div>',
      );
      expect((result[0] as PollNode).title, '问题Q');
    });

    test('标题 fallback data-poll-title', () {
      final result = parser.parse(
        '<div class="poll" data-poll-title="标题T">'
        '<div class="poll-title">DOM标题</div></div>',
      );
      expect((result[0] as PollNode).title, '标题T');
    });

    test('标题 fallback .poll-title 文本', () {
      final result = parser.parse(
        '<div class="poll"><div class="poll-title">DOM标题</div></div>',
      );
      expect((result[0] as PollNode).title, 'DOM标题');
    });

    test('标题 fallback .poll-question 文本', () {
      final result = parser.parse(
        '<div class="poll"><div class="poll-question">问题文本</div></div>',
      );
      expect((result[0] as PollNode).title, '问题文本');
    });

    test('无标题 → title null', () {
      final result = parser.parse(
        '<div class="poll"><ul><li>x</li></ul></div>',
      );
      expect((result[0] as PollNode).title, isNull);
    });

    test('普通 div 不识别为 poll', () {
      final result = parser.parse('<div><ul><li>x</li></ul></div>');
      expect(result.whereType<PollNode>(), isEmpty);
    });

    test('countImageRuns 不计 poll(数据在 API)', () {
      final result = parser.parse(
        '<p><img src="a.png"></p>'
        '<div class="poll"><img src="inside.png"><ul><li>x</li></ul></div>',
      );
      // poll 内的图不计入(poll 数据由 API 提供,cooked img 不渲染)
      expect(countImageRuns(result), 1);
    });

    test('rawHtml 保留完整 outerHtml', () {
      final result = parser.parse(
        '<div class="poll" data-poll-name="p"><ul><li>opt</li></ul></div>',
      );
      final p = result[0] as PollNode;
      expect(p.rawHtml, contains('class="poll"'));
      expect(p.rawHtml, contains('opt'));
    });

    test('id 唯一(多个 poll)', () {
      final result = parser.parse(
        '<div class="poll" data-poll-name="a"><ul><li>1</li></ul></div>'
        '<div class="poll" data-poll-name="b"><ul><li>2</li></ul></div>',
      );
      expect(result, hasLength(2));
      expect((result[0] as PollNode).id, isNot((result[1] as PollNode).id));
    });

    test('PollNode ==/hashCode 按 name+title+rawHtml', () {
      const a = PollNode(id: 'b_0', pollName: 'p', title: 'T', rawHtml: 'x');
      const b = PollNode(id: 'b_9', pollName: 'p', title: 'T', rawHtml: 'x');
      const c = PollNode(id: 'b_0', pollName: 'q', title: 'T', rawHtml: 'x');
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
