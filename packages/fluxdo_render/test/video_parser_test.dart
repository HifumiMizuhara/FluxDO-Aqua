// VideoNode parser 测试:三种 cooked 形态都正确产 VideoNode。
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  final parser = ParagraphParser();

  test(
    'video-placeholder-container → VideoNode(src=data-video-src, poster=data-thumbnail-src)',
    () {
      const html =
          '<p><div class="video-placeholder-container" '
          'data-video-src="/uploads/x.mp4" '
          'data-thumbnail-src="/uploads/x.png" '
          'data-orig-src="upload://abc.mp4"></div></p>';
      final nodes = parser.parse(html);
      final video = nodes.whereType<VideoNode>().single;
      expect(video.src, '/uploads/x.mp4');
      expect(video.poster, '/uploads/x.png');
      expect(video.width, isNull);
      expect(video.height, isNull);
    },
  );

  test('placeholder 无 data-video-src 时回退 data-orig-src', () {
    const html =
        '<div class="video-placeholder-container" '
        'data-orig-src="upload://abc.mp4"></div>';
    final video = parser.parse(html).whereType<VideoNode>().single;
    expect(video.src, 'upload://abc.mp4');
  });

  test('div.video-onebox 内 <video><source> → src=source[src], mime, 16:9', () {
    const html =
        '<div class="onebox video-onebox">'
        '<video width="100%" height="100%" controls>'
        '<source src="https://e.com/r.mp4" type="video/mp4">'
        '<a href="https://e.com/r.mp4">x</a></video></div>';
    final video = parser.parse(html).whereType<VideoNode>().single;
    expect(video.src, 'https://e.com/r.mp4');
    expect(video.mime, 'video/mp4');
    expect(video.width, isNull); // "100%" 非数字
  });

  test('裸 <video poster width height loop> 顶层标签', () {
    const html =
        '<video poster="/p.png" width="640" height="360" loop>'
        '<source src="/v.mp4" type="video/mp4"></video>';
    final video = parser.parse(html).whereType<VideoNode>().single;
    expect(video.src, '/v.mp4');
    expect(video.poster, '/p.png');
    expect(video.width, 640);
    expect(video.height, 360);
    expect(video.loop, isTrue);
  });
}
