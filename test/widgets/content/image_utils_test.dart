import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/image_utils.dart';

void main() {
  setUp(() {
    UrlHelper.debugSetOverrides(
      baseUri: '',
      cdnUrl: 'https://cdn.example.com',
      s3CdnUrl: 'https://cdn3.example.com',
      s3BaseUrl: '//uploads.example.com',
    );
  });

  tearDown(() {
    UrlHelper.debugClearOverrides();
  });

  group('DiscourseImageUtils.isUploadUrl', () {
    test('recognizes upload:// scheme', () {
      expect(DiscourseImageUtils.isUploadUrl('upload://abc123.png'), isTrue);
    });

    test('recognizes relative short-url paths (video/audio hand-written src)',
        () {
      expect(
        DiscourseImageUtils.isUploadUrl(
          '/uploads/short-url/lwDn83PDeB3xOUoEeZI9v77qGJa.xz',
        ),
        isTrue,
      );
      expect(
        DiscourseImageUtils.isUploadUrl('/uploads/short-url/abc.mp3'),
        isTrue,
      );
    });

    test('recognizes absolute short-url on origin / CDN hosts only', () {
      expect(
        DiscourseImageUtils.isUploadUrl(
          'https://linux.do/uploads/short-url/abc.xz',
        ),
        isTrue,
      );
      expect(
        DiscourseImageUtils.isUploadUrl(
          'https://cdn.example.com/uploads/short-url/abc.xz',
        ),
        isTrue,
      );
      // 外站同形路径不接管(无法用本站 lookup-urls 解析)
      expect(
        DiscourseImageUtils.isUploadUrl(
          'https://meta.discourse.org/uploads/short-url/abc.xz',
        ),
        isFalse,
      );
    });

    test('ignores normal upload paths', () {
      expect(
        DiscourseImageUtils.isUploadUrl(
          '/uploads/default/original/4X/a/b/c/abc.png',
        ),
        isFalse,
      );
      expect(DiscourseImageUtils.isUploadUrl('https://example.com/a.mp4'),
          isFalse);
    });
  });

  group('DiscourseImageUtils cache key normalization', () {
    test('short-url path shares cache entry with upload:// form', () {
      DiscourseImageUtils.seedUploadUrl(
        'upload://lwDn83PDeB3xOUoEeZI9v77qGJa.xz',
        'https://cdn3.example.com/original/4X/9/6/d/96de.mp4',
      );
      expect(
        DiscourseImageUtils.getCachedUploadUrl(
          '/uploads/short-url/lwDn83PDeB3xOUoEeZI9v77qGJa.xz',
        ),
        'https://cdn3.example.com/original/4X/9/6/d/96de.mp4',
      );
      expect(
        DiscourseImageUtils.getCachedUploadUrl(
          'https://linux.do/uploads/short-url/lwDn83PDeB3xOUoEeZI9v77qGJa.xz',
        ),
        'https://cdn3.example.com/original/4X/9/6/d/96de.mp4',
      );
    });

    test('non-upload URL passes through getCachedUploadUrl', () {
      expect(
        DiscourseImageUtils.getCachedUploadUrl('https://example.com/a.png'),
        'https://example.com/a.png',
      );
    });
  });
}
