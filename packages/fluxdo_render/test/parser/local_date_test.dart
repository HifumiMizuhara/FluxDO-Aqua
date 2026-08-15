import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser local_date 识别', () {
    test('基础 date+time+timezone → LocalDateRun + 字段完整', () {
      final result = parser.parse(
        '<p>会议 <span class="discourse-local-date" '
        'data-date="2026-08-15" data-time="14:30" '
        'data-timezone="Asia/Shanghai" '
        'data-format="LLL">2026年8月15日 14:30</span></p>',
      );
      final p = result[0] as ParagraphNode;
      final d = p.inlines.whereType<LocalDateRun>().single;
      expect(d.date, '2026-08-15');
      expect(d.time, '14:30');
      expect(d.timezone, 'Asia/Shanghai');
      expect(d.format, 'LLL');
      expect(d.countdown, isFalse);
      expect(d.fallbackText, '2026年8月15日 14:30');
    });

    test('data-timezones 拆分(|)', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-01-01" '
        'data-timezones="Europe/Paris|America/Los_Angeles|Asia/Tokyo">x</span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.timezones, [
        'Europe/Paris',
        'America/Los_Angeles',
        'Asia/Tokyo',
      ]);
    });

    test('仅 date 无 time → time=null', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-12-25">x</span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.time, isNull);
    });

    test('data-countdown 属性存在 → countdown=true', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-10-01" '
        'data-countdown>3 小时</span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.countdown, isTrue);
    });

    test('data-range from/to 保留', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-01-01" '
        'data-range="from">x</span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.range, 'from');
    });

    test('data-displayed-timezone 提取', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-01-01" '
        'data-displayed-timezone="Asia/Tokyo">x</span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.displayedTimezone, 'Asia/Tokyo');
    });

    test('data-date 缺失 → 降级展平,不产 LocalDateRun', () {
      final result = parser.parse(
        '<p>x<span class="discourse-local-date">无效</span></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<LocalDateRun>(), isEmpty);
      // 文本"无效"应该被展平进段落
      final hasText = p.inlines.any((n) => n is TextRun && n.text == '无效');
      expect(hasText, isTrue);
    });

    test('普通 span(非 local-date)展平', () {
      final result = parser.parse('<p>x<span>普通</span>y</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<LocalDateRun>(), isEmpty);
    });

    test('fallbackText 取 span textContent(trim)', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-01-01">  '
        '预渲染文本  </span></p>',
      );
      final d = (result[0] as ParagraphNode).inlines
          .whereType<LocalDateRun>()
          .single;
      expect(d.fallbackText, '预渲染文本');
    });

    test('多个 local-date 各自独立', () {
      final result = parser.parse(
        '<p><span class="discourse-local-date" data-date="2026-01-01">A</span>'
        ' / '
        '<span class="discourse-local-date" data-date="2026-02-01">B</span></p>',
      );
      final p = result[0] as ParagraphNode;
      final dates = p.inlines.whereType<LocalDateRun>().toList();
      expect(dates, hasLength(2));
      expect(dates[0].date, '2026-01-01');
      expect(dates[1].date, '2026-02-01');
    });

    test('countImageRuns 不计 LocalDateRun', () {
      final result = parser.parse(
        '<p><img src="a.png"><span class="discourse-local-date" '
        'data-date="2026-01-01">x</span></p>',
      );
      expect(countImageRuns(result), 1);
    });
  });
}
