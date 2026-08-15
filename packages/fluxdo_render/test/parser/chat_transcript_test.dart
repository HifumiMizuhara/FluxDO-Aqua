import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser chat_transcript 识别', () {
    test('基础 div.chat-transcript → ChatTranscriptNode + 全字段', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="alice" '
        'data-datetime="2026-02-12T10:30:00Z" data-channel-name="general">'
        '<img class="avatar" src="https://x/a.png">'
        '<div class="chat-transcript-messages"><p>你好</p></div>'
        '</div>',
      );
      expect(result, hasLength(1));
      final c = result[0] as ChatTranscriptNode;
      expect(c.username, 'alice');
      expect(c.datetime, '2026-02-12T10:30:00Z');
      expect(c.channelName, 'general');
      expect(c.avatarUrl, 'https://x/a.png');
      expect(c.isChained, isFalse);
      expect(c.messagesHtml, contains('你好'));
    });

    test('chained class → isChained=true', () {
      final result = parser.parse(
        '<div class="chat-transcript chat-transcript-chained" '
        'data-username="bob"><div class="chat-transcript-messages">'
        '<p>x</p></div></div>',
      );
      expect((result[0] as ChatTranscriptNode).isChained, isTrue);
    });

    test('无 channel-name → null', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages"><p>x</p></div></div>',
      );
      expect((result[0] as ChatTranscriptNode).channelName, isNull);
    });

    test('无头像 → avatarUrl null', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages"><p>x</p></div></div>',
      );
      expect((result[0] as ChatTranscriptNode).avatarUrl, isNull);
    });

    test('messagesHtml 取 .chat-transcript-messages innerHtml', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages">'
        '<p>第一段</p><p>第二段</p></div></div>',
      );
      final html = (result[0] as ChatTranscriptNode).messagesHtml;
      expect(html, contains('第一段'));
      expect(html, contains('第二段'));
    });

    test('无 messages div → messagesHtml 空', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a"></div>',
      );
      expect((result[0] as ChatTranscriptNode).messagesHtml, isEmpty);
    });

    test('普通 div 不识别', () {
      final result = parser.parse('<div><p>x</p></div>');
      expect(result.whereType<ChatTranscriptNode>(), isEmpty);
    });

    test('rawHtml 保留完整 outerHtml', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages"><p>msg</p></div></div>',
      );
      final c = result[0] as ChatTranscriptNode;
      expect(c.rawHtml, contains('chat-transcript'));
      expect(c.rawHtml, contains('msg'));
    });

    test('countImageRuns 不计 chat-transcript 内图(messagesHtml 未解析)', () {
      final result = parser.parse(
        '<p><img src="out.png"></p>'
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages"><img src="in.png"></div></div>',
      );
      expect(countImageRuns(result), 1);
    });

    test('id 唯一(多条)', () {
      final result = parser.parse(
        '<div class="chat-transcript" data-username="a">'
        '<div class="chat-transcript-messages"><p>1</p></div></div>'
        '<div class="chat-transcript" data-username="b">'
        '<div class="chat-transcript-messages"><p>2</p></div></div>',
      );
      expect(result, hasLength(2));
      expect(
        (result[0] as ChatTranscriptNode).id,
        isNot((result[1] as ChatTranscriptNode).id),
      );
    });

    test('ChatTranscriptNode ==/hashCode 按字段', () {
      const a = ChatTranscriptNode(
        id: 'b_0',
        username: 'u',
        messagesHtml: 'm',
        rawHtml: 'r',
      );
      const b = ChatTranscriptNode(
        id: 'b_9',
        username: 'u',
        messagesHtml: 'm',
        rawHtml: 'r',
      );
      const c = ChatTranscriptNode(
        id: 'b_0',
        username: 'v',
        messagesHtml: 'm',
        rawHtml: 'r',
      );
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
