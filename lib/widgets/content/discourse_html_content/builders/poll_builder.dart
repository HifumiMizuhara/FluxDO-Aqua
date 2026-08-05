import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../../models/topic.dart';
import 'package:dio/dio.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../utils/time_utils.dart';
import '../../../../l10n/s.dart';

/// 构建投票块
Widget buildPoll({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Post post,
}) {
  final pollTitle = _extractPollTitle(element);
  final pollName = element.attributes['data-poll-name'] ?? 'poll';
  final poll = post.polls?.firstWhere((p) => p.name == pollName, orElse: () => Poll(id: 0, name: pollName, type: 'regular', status: 'open', results: 'always', options: [], voters: 0));

  if (poll == null || poll.options.isEmpty) {
    return const SizedBox.shrink();
  }

  final userVotes = post.pollsVotes?[pollName] ?? [];

  return _PollWidget(
    poll: poll,
    title: pollTitle,
    post: post,
    userVotes: userVotes,
    // 图表类型来自 cooked 属性(API poll 数据不带 chart_type);
    // number 型没有该属性 → null → bar 现状
    chartType: element.attributes['data-poll-charttype'] as String?,
    onPollUpdated: (updatedPoll, updatedVotes) {
      final pollIndex = post.polls?.indexWhere((p) => p.name == pollName) ?? -1;
      if (pollIndex >= 0 && post.polls != null) {
        post.polls![pollIndex] = updatedPoll;
      }
      if (post.pollsVotes != null) {
        post.pollsVotes![pollName] = updatedVotes;
      }
    },
  );
}

/// 无 post 场景(富 composer 岛预览等)的静态投票预览卡。
///
/// 数据不走 API,全部从 cooked `div.poll` DOM 解出:标题(.poll-title)、
/// 选项(li[data-poll-option-id])、属性(data-poll-*)。无投票交互,
/// 展示「标题 + 类型徽标 + 选项列表 + 属性摘要」——编辑器里插入 [poll]
/// BBCode 后 cook 出来的就是这个形态,所见即所发。
///
/// number 型选项 li 是 min/max/step 派生的数字全集,逐项列出冗长,
/// 压缩为范围摘要行。
Widget buildPollStaticPreview({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
}) {
  final attrs = element.attributes;
  String? attr(String key) {
    final v = (attrs[key] as String?)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  final type = attr('data-poll-type') ?? 'regular';
  // 标题:.poll-title 富文本取纯文本(emoji 用 alt 补位),
  // 属性形态(data-poll-question)走 legacy 提取
  String? title = _extractPollTitle(element);
  final titleEls = element.getElementsByClassName('poll-title');
  if (titleEls.isNotEmpty) {
    final t = _textWithEmojiAlt(titleEls.first);
    if (t.isNotEmpty) title = t;
  }
  final isNumber = type == 'number';

  final options = <String>[
    if (!isNumber)
      for (final li in element.querySelectorAll('li[data-poll-option-id]'))
        _textWithEmojiAlt(li),
  ];

  // 类型徽标文案
  final typeLabel = switch (type) {
    'multiple' => '多选',
    'number' => '评分',
    'ranked_choice' => '排序',
    _ => '单选',
  };

  // 属性摘要:多选范围 / 评分范围 / 结果可见性 / 公开 / 自动关闭
  final summary = <String>[];
  final min = attr('data-poll-min');
  final max = attr('data-poll-max');
  if (type == 'multiple' && (min != null || max != null)) {
    summary.add('选 ${min ?? '1'}-${max ?? options.length} 项');
  }
  if (isNumber) {
    final step = attr('data-poll-step');
    summary.add(
      '范围 ${min ?? '1'}-${max ?? '10'}'
      '${step != null && step != '1' ? ' 步长 $step' : ''}',
    );
  }
  switch (attr('data-poll-results')) {
    case 'on_vote':
      summary.add('结果投票后可见');
    case 'on_close':
      summary.add('结果关闭后可见');
    case 'staff_only':
      summary.add('结果仅管理人员可见');
  }
  if (attr('data-poll-public') == 'true') summary.add('公开投票人');
  if (attr('data-poll-charttype') == 'pie') summary.add('饼图');
  final close = attr('data-poll-close');
  if (close != null) {
    final closeTime = TimeUtils.parseUtcTime(close);
    if (closeTime != null) {
      summary.add('${TimeUtils.formatShortDate(closeTime)} 自动关闭');
    }
  }
  if (attr('data-poll-status') == 'closed') summary.add('已关闭');

  final scheme = theme.colorScheme;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 12),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
      border: Border.all(
        color: scheme.outline.withValues(alpha: 0.3),
        width: 1,
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头部:类型徽标 + 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  typeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (title != null && title.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ),
        // 选项列表(静态,无点击态);number 型无选项行,靠摘要
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Column(
              children: [
                for (var i = 0; i < options.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border: Border.all(
                          color: scheme.outline.withValues(alpha: 0.2),
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            type == 'multiple'
                                ? Symbols.check_box_outline_blank_rounded
                                : Symbols.radio_button_unchecked_rounded,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              options[i],
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        // 底部:属性摘要
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outline.withValues(alpha: 0.2)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Symbols.poll_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  summary.isEmpty ? '投票' : summary.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 元素纯文本,但 emoji `<img class="emoji" alt=":x:">` 用 alt 补位 ——
/// 直接 .text 会把选项里的 emoji 静默吞掉,长得像丢字。
String _textWithEmojiAlt(dynamic el) {
  final buf = StringBuffer();
  void walk(dynamic node) {
    // html 包:Element 有 localName;Text 节点走 nodeType==3
    if (node.nodeType == 3) {
      buf.write(node.text ?? '');
      return;
    }
    final attrs = node.attributes;
    if (attrs is Map && (attrs['class'] as String? ?? '').contains('emoji')) {
      buf.write(attrs['alt'] as String? ?? '');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(el);
  return buf.toString().trim();
}

String? _extractPollTitle(dynamic element) {
  final attributeTitle = element.attributes['data-poll-question'] ?? element.attributes['data-poll-title'];
  if (attributeTitle is String && attributeTitle.trim().isNotEmpty) {
    return attributeTitle.trim();
  }

  final pollTitleElements = element.getElementsByClassName('poll-title');
  if (pollTitleElements.isNotEmpty) {
    final text = pollTitleElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  final pollQuestionElements = element.getElementsByClassName('poll-question');
  if (pollQuestionElements.isNotEmpty) {
    final text = pollQuestionElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  return null;
}

class _PollWidget extends StatefulWidget {
  final Poll poll;
  final String? title;
  final Post post;
  final List<String> userVotes;
  final String? chartType; // cooked data-poll-charttype:'bar' | 'pie' | null
  final Function(Poll, List<String>) onPollUpdated;

  const _PollWidget({
    required this.poll,
    this.title,
    required this.post,
    required this.userVotes,
    this.chartType,
    required this.onPollUpdated,
  });

  @override
  State<_PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<_PollWidget> {
  late Poll _poll;
  late List<String> _userVotes;
  late bool _showResults;
  bool _isVoting = false;
  bool _showPercentage = true; // true: 百分比, false: 计数

  @override
  void initState() {
    super.initState();
    _poll = widget.poll;
    _userVotes = List.from(widget.userVotes);
    _showResults = _shouldShowResults();
  }

  bool _shouldShowResults() {
    final hasVoted = _userVotes.isNotEmpty;
    final isClosed = _poll.status == 'closed';

    // 如果是 on_close 且未关闭，不显示结果
    if (_poll.results == 'on_close' && !isClosed) {
      return false;
    }

    // 如果是 staff_only，不显示结果（需要管理员权限）
    if (_poll.results == 'staff_only') {
      return false;
    }

    // 满足以下任一条件就显示结果
    return hasVoted || isClosed;
  }

  bool get _isMultiple => _poll.type == 'multiple';

  Future<void> _vote(String optionId) async {
    if (_poll.status == 'closed' || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      // 多选：切换选项
      List<String> votesToSubmit;
      if (_isMultiple) {
        if (_userVotes.contains(optionId)) {
          _userVotes.remove(optionId);
        } else {
          _userVotes.add(optionId);
        }
        votesToSubmit = List.from(_userVotes);
        setState(() {});
        return; // 多选不立即提交
      } else {
        // 单选：直接提交
        votesToSubmit = [optionId];
      }

      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: votesToSubmit,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = votesToSubmit;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, votesToSubmit);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _submitMultipleVote() async {
    if (_userVotes.isEmpty || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: _userVotes,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, _userVotes);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _removeVote() async {
    if (_isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().removeVote(
        postId: widget.post.id,
        pollName: _poll.name,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = [];
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, []);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClosed = _poll.status == 'closed';
    final hasVoted = _userVotes.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                widget.title!,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (_showResults)
            _buildResults(theme)
          else
            _buildOptions(theme),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isClosed ? Symbols.lock_rounded : Symbols.poll_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  S.current.poll_voters(_poll.voters),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isClosed) ...[
                  const SizedBox(width: 8),
                  Text(
                    '• ${S.current.poll_closed}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                // 多选投票按钮
                if (_isMultiple && !_showResults && _userVotes.isNotEmpty)
                  TextButton(
                    onPressed: _submitMultipleVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                    child: Text(
                      S.current.poll_vote,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                // 撤销投票按钮
                if (!isClosed && hasVoted && !_showResults && !_isMultiple)
                  TextButton(
                    onPressed: _removeVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      S.current.poll_undo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                // 切换显示模式按钮
                if (_showResults && _poll.voters > 0)
                  TextButton(
                    onPressed: () => setState(() => _showPercentage = !_showPercentage),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showPercentage ? S.current.poll_count : S.current.poll_percentage,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                // 投票/查看结果切换按钮 - 当 results 为 always 或者用户已投票时显示
                if (!isClosed && (hasVoted || _poll.results == 'always'))
                  TextButton(
                    onPressed: () => setState(() => _showResults = !_showResults),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showResults ? S.current.poll_vote : S.current.poll_viewResults,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptions(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final isUserVoted = _userVotes.contains(option.id);

        return InkWell(
          onTap: _isVoting ? null : () => _vote(option.id),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUserVoted
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : theme.colorScheme.surface,
              border: Border.all(
                color: isUserVoted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // 单选/多选图标
                Icon(
                  _isMultiple
                      ? (isUserVoted ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded)
                      : (isUserVoted ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded),
                  size: 20,
                  color: isUserVoted ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isUserVoted ? FontWeight.w500 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResults(ThemeData theme) {
    // chartType=pie(官方 poll 插件的饼图形态):结果区换饼图 + 图例。
    // 无人投票时饼图无意义,回落条形列表(显示 0 票选项)。
    if (widget.chartType == 'pie' && _poll.voters > 0) {
      return _buildPieResults(theme);
    }
    return _buildBarResults(theme);
  }

  /// 饼图结果:CustomPaint 饼 + 图例列表(色块 + 选项 + 票数/百分比)。
  ///
  /// 颜色:主题 primary 起点的 HSL 色相均匀旋转(选项数固定,颜色跟随
  /// 选项序而非票数排名),饱和/明度收敛到主题模式友好区间;扇区间
  /// 2px surface 缝隙提高相邻可辨性。
  Widget _buildPieResults(ThemeData theme) {
    final colors = _pieColors(theme, _poll.options.length);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: SizedBox(
              width: 160,
              height: 160,
              child: CustomPaint(
                painter: _PiePainter(
                  votes: [for (final o in _poll.options) o.votes],
                  colors: colors,
                  gapColor: theme.colorScheme.surface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _poll.options.length; i++)
            _buildPieLegendRow(theme, i, colors[i]),
        ],
      ),
    );
  }

  Widget _buildPieLegendRow(ThemeData theme, int index, Color color) {
    final option = _poll.options[index];
    final percentage =
        _poll.voters > 0 ? (option.votes / _poll.voters * 100) : 0.0;
    final isUserVoted = _userVotes.contains(option.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          if (isUserVoted) ...[
            Icon(
              Symbols.check_circle_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: isUserVoted ? FontWeight.w500 : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _showPercentage
                ? '${percentage.toStringAsFixed(0)}%'
                : '${option.votes}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 主题色系派生的分类色:primary 色相为锚,按选项序均匀旋转色相;
  /// 饱和/明度按明暗模式收敛(暗色降明度差、亮色压饱和),文本不着
  /// 系列色(图例文字用正文色,色块承载身份)。
  static List<Color> _pieColors(ThemeData theme, int count) {
    if (count <= 0) return const [];
    final base = HSLColor.fromColor(theme.colorScheme.primary);
    final isDark = theme.brightness == Brightness.dark;
    final saturation = (base.saturation.clamp(0.45, 0.75)).toDouble();
    final lightness = isDark ? 0.65 : 0.52;
    return [
      for (var i = 0; i < count; i++)
        HSLColor.fromAHSL(
          1,
          (base.hue + 360 * i / count) % 360,
          saturation,
          lightness,
        ).toColor(),
    ];
  }

  Widget _buildBarResults(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final percentage = _poll.voters > 0 ? (option.votes / _poll.voters * 100) : 0.0;
        final isUserVoted = _userVotes.contains(option.id);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isUserVoted
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isUserVoted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (isUserVoted) ...[
                          Icon(
                            Symbols.check_circle_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isUserVoted ? FontWeight.w500 : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _showPercentage
                        ? '${percentage.toStringAsFixed(0)}%'
                        : '${option.votes}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: percentage / 100,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    isUserVoted ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 投票结果饼图 painter:按票数占比画扇区,扇区间用 [gapColor](表面色)
/// 描 2px 缝隙线,相邻同类色也可辨。0 票选项不画扇区(图例仍在)。
class _PiePainter extends CustomPainter {
  const _PiePainter({
    required this.votes,
    required this.colors,
    required this.gapColor,
  });

  final List<int> votes;
  final List<Color> colors;
  final Color gapColor;

  @override
  void paint(Canvas canvas, Size size) {
    final total = votes.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 12 点方向起,顺时针(官方图表习惯)
    var start = -math.pi / 2;
    final fill = Paint()..style = PaintingStyle.fill;
    final segments = <(double, double, Color)>[];
    for (var i = 0; i < votes.length; i++) {
      if (votes[i] <= 0) continue;
      final sweep = 2 * math.pi * votes[i] / total;
      segments.add((start, sweep, colors[i % colors.length]));
      start += sweep;
    }
    for (final (s, sweep, color) in segments) {
      fill.color = color;
      canvas.drawArc(rect, s, sweep, true, fill);
    }
    // 扇区分隔缝:单扇区(100%)不画,画了会出现一道突兀的半径线
    if (segments.length > 1) {
      final gap = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = gapColor;
      for (final (s, _, _) in segments) {
        canvas.drawLine(
          center,
          center + Offset(math.cos(s), math.sin(s)) * radius,
          gap,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PiePainter oldDelegate) =>
      !listEquals(oldDelegate.votes, votes) ||
      !listEquals(oldDelegate.colors, colors) ||
      oldDelegate.gapColor != gapColor;
}
