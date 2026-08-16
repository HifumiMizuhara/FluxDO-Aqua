import 'package:emoji_extension/emoji_extension.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../utils/emoji_shortcodes.dart';
import 'emoji_handler.dart';

/// 「EmojiをDiscourse風に統一」実験機能の共有ポリシー。
///
/// OFF時は既存のUnicode/system-font描画を維持する。ON時だけUnicode emoji
/// をDiscourse互換shortcodeへ正規化し、各描画経路が既存のemoji画像管線を
/// 利用できるようにする。
class EmojiDisplayPolicy {
  EmojiDisplayPolicy._();

  static bool _enabled = false;

  static bool get enabled => _enabled;

  static void configure(bool enabled) {
    _enabled = enabled;
  }

  /// Unicode emojiをDiscourse互換shortcodeへ変換する。
  static String normalizeUnicodeEmoji(String text) {
    if (!_enabled || text.isEmpty) return text;
    return text.emojis.toDiscordShortcodes();
  }

  /// Markdownのコードブロック/インラインコードを保護しつつ変換する。
  static String normalizeMarkdown(String markdown) {
    if (!_enabled || markdown.isEmpty) return markdown;

    final lines = markdown.split('\n');
    var inFence = false;
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        inFence = !inFence;
        out.add(line);
      } else if (inFence) {
        out.add(line);
      } else {
        out.add(_normalizeOutsideInlineCode(line));
      }
    }
    return out.join('\n');
  }

  static String _normalizeOutsideInlineCode(String line) {
    final out = StringBuffer();
    var cursor = 0;
    while (cursor < line.length) {
      final tick = line.indexOf('`', cursor);
      if (tick < 0) {
        out.write(normalizeUnicodeEmoji(line.substring(cursor)));
        break;
      }

      out.write(normalizeUnicodeEmoji(line.substring(cursor, tick)));
      var runEnd = tick;
      while (runEnd < line.length && line[runEnd] == '`') {
        runEnd++;
      }
      final run = line.substring(tick, runEnd);
      final close = line.indexOf(run, runEnd);
      if (close < 0) {
        out.write(normalizeUnicodeEmoji(line.substring(tick)));
        break;
      }
      out.write(line.substring(tick, close + run.length));
      cursor = close + run.length;
    }
    return out.toString();
  }

  /// cooked HTML内の生Unicode emojiを既存のemoji imgへ置換する。
  /// code/pre/script/style内はDiscourseのコード表示を壊さないため保持する。
  static String normalizeCookedHtml(String cookedHtml) {
    if (!_enabled || cookedHtml.isEmpty) return cookedHtml;

    final fragment = html_parser.parseFragment(cookedHtml);
    void visit(dom.Node node, bool protectedByCode) {
      if (node is! dom.Element) return;
      final tag = node.localName?.toLowerCase();
      final protectedHere =
          protectedByCode ||
          tag == 'code' ||
          tag == 'pre' ||
          tag == 'script' ||
          tag == 'style';

      for (final child in List<dom.Node>.from(node.nodes)) {
        if (child is dom.Text && !protectedHere) {
          final replacement = _emojiNodes(child.text);
          if (replacement == null) continue;
          final index = node.nodes.indexOf(child);
          node.nodes.removeAt(index);
          node.nodes.insertAll(index, replacement);
        } else {
          visit(child, protectedHere);
        }
      }
    }

    for (final child in List<dom.Node>.from(fragment.nodes)) {
      if (child is dom.Text) {
        final replacement = _emojiNodes(child.text);
        if (replacement == null) continue;
        final index = fragment.nodes.indexOf(child);
        fragment.nodes.removeAt(index);
        fragment.nodes.insertAll(index, replacement);
      } else {
        visit(child, false);
      }
    }
    return fragment.outerHtml;
  }

  static List<dom.Node>? _emojiNodes(String text) {
    final normalized = normalizeUnicodeEmoji(text);
    if (normalized == text) return null;

    final nodes = <dom.Node>[];
    var cursor = 0;
    final matches = emojiShortcodeRegex.allMatches(normalized);
    for (final match in matches) {
      if (match.start > cursor) {
        nodes.add(dom.Text(normalized.substring(cursor, match.start)));
      }
      final name = match.group(1)!;
      final image = dom.Element.tag('img')
        ..classes.add('emoji')
        ..attributes['src'] = EmojiHandler().getEmojiUrl(name)
        ..attributes['alt'] = ':$name:'
        ..attributes['title'] = ':$name:';
      nodes.add(image);
      cursor = match.end;
    }
    if (cursor < normalized.length) {
      nodes.add(dom.Text(normalized.substring(cursor)));
    }
    return nodes;
  }
}
