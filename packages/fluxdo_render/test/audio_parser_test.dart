// AudioNode parser 测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  final parser = ParagraphParser();

  test('<audio><source src .. type ..><a>文本</a> → AudioNode', () {
    const html =
        '<p><audio preload="metadata" controls>'
        '<source src="/uploads/x.mp3" type="audio/mpeg" data-orig-src="upload://abc.mp3">'
        '<a href="/uploads/x.mp3">/uploads/x.mp3</a></audio></p>';
    final audio = parser.parse(html).whereType<AudioNode>().single;
    expect(audio.src, '/uploads/x.mp3');
    expect(audio.mime, 'audio/mpeg');
    expect(audio.title, '/uploads/x.mp3');
  });

  test('source 无 src 时回退 data-orig-src', () {
    const html =
        '<audio controls><source data-orig-src="upload://abc.mp3"></audio>';
    final audio = parser.parse(html).whereType<AudioNode>().single;
    expect(audio.src, 'upload://abc.mp3');
  });

  group('语音消息([wrap=voice] 容器)', () {
    test('d-wrap voice 内 audio → AudioNode(voice:true)', () {
      const html =
          '<div class="d-wrap" data-wrap="voice">\n'
          '<audio controls>\n'
          '  <source src="/uploads/short-url/abc123.xz" type="audio/mp4">\n'
          '</audio>\n'
          '</div>';
      final audio = ParagraphParser().parse(html).whereType<AudioNode>().single;
      expect(audio.voice, isTrue);
      expect(audio.src, '/uploads/short-url/abc123.xz');
      expect(audio.mime, 'audio/mp4');
    });

    test('普通 audio voice=false;别的 wrap 值不升格', () {
      const html =
          '<audio controls><source src="/x.mp3"></audio>'
          '<div class="d-wrap" data-wrap="spoiler">'
          '<audio controls><source src="/y.mp3"></audio></div>';
      final audios = ParagraphParser()
          .parse(html)
          .whereType<AudioNode>()
          .toList();
      // 顶层 audio 正常且非语音;非 voice 的 d-wrap 不走升格分支
      // (其内 audio 维持既有通用 div 行为,不在本特判范围)
      expect(audios.first.voice, isFalse);
      expect(audios.where((a) => a.voice), isEmpty);
    });

    test('空 wrap=voice(无 audio)不炸,走普通容器', () {
      const html = '<div class="d-wrap" data-wrap="voice"><p>只有文字</p></div>';
      final nodes = ParagraphParser().parse(html);
      expect(nodes.whereType<AudioNode>(), isEmpty);
      expect(nodes, isNotEmpty);
    });
  });
}
