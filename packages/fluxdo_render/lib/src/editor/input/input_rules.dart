/// Markdown 快捷语法(input rules)—— 类 Notion 输入体验的核心。
///
/// 对齐官方 ProseMirror composer 的 buildInputRules(core/inputrules.js):
/// - **块级**(行首标记 + 空格触发):`# `→标题、`- `/`* `→无序列表、
///   `1. `→有序列表、`> `→引用层;
/// - **行内**(收尾定界符触发):`**x**`→粗体、`*x*`→斜体、`` `x` ``→
///   行内代码、`~~x~~`→删除线;
/// - **hr**(`---` + 空格):由 [InputRuleOutcome.hrRequest] 上抛,视图层
///   经 cook 链路插分隔线岛(状态层不造岛)。
///
/// 触发时机:IME 文本落地后、无 composing 时(EditorImeClient 调用)。
/// 中文 composing 期间绝不触发 —— 预编辑文本是临时的。
///
/// 撤销语义(官方 undoable 同款):规则应用前 seal —— undo 一步回到
/// 字面文本(`**粗**` 原样),再 undo 才删字符。
///
/// 排除:光标处于 inlineCode mark 内时行内规则不触发(代码里写 `*` 是
/// 字面量);块级规则对 heading/listItem 块不触发(已是结构块)。
library;

import '../model/editable_text_content.dart';
import '../model/editor_state.dart';
import '../model/markdown_serializer.dart' show parseImageMarkdown;
import 'inline_pair_defs.dart';

/// 规则应用结果。
enum InputRuleOutcome {
  /// 无规则命中。
  none,

  /// 已应用(文档已变,调用方需 reconcile IME)。
  applied,

  /// `---` 命中:请求视图层插入分隔线(状态层不产岛节点)。
  /// 触发行文本已清空。
  hrRequest,

  /// `[!type] ` 命中(callout 手打):请求视图层经 cook 链路把当前块
  /// 换成 callout 岛。触发行文本已清空,匹配到的类型存在
  /// [EditorState.pendingCalloutType]。
  calloutRequest,
}

/// 对 [blockId] 块在光标处尝试应用 input rules。
///
/// [typedChar]:本次输入落地的最后一个字符(触发器判定用;IME 批量
/// 上屏时为末字符)。只有 ' '(块级触发)与定界符尾字符(行内触发)
/// 才可能命中,其余字符 O(1) 直接返回。
InputRuleOutcome tryApplyInputRules(
  EditorState state,
  String blockId, {
  required String typedChar,
}) {
  if (state.hasComposing) return InputRuleOutcome.none;
  final sel = state.selection;
  if (sel == null || !sel.isCollapsed || sel.extent.blockId != blockId) {
    return InputRuleOutcome.none;
  }
  final block = state.textBlockById(blockId);
  if (block == null) return InputRuleOutcome.none;

  if (typedChar == ' ') {
    return _tryBlockRules(state, block, sel.extent.offset);
  }

  // ir(即时渲染):**行内**规则整体关闭 —— 折叠时机统一为「光标移出
  // 字面区」(spin 收口负责),打字过程保持字面显示(带语法着色),
  // 打完闭定界符不立即收符号。块级规则(`# `/`- `/callout,上方)与
  // 图片/链接(`)` 触发,产物是原子/带 href 的结构,字面态没有对应
  // 渲染)保留立即转换。wysiwyg 维持全部规则即打即渲染。
  if (state.mode == EditorMode.ir) {
    if (typedChar == ')') {
      return _tryImageOrLinkRule(state, block, sel.extent.offset);
    }
    return InputRuleOutcome.none;
  }

  if (typedChar == ')') {
    return _tryImageOrLinkRule(state, block, sel.extent.offset);
  }
  if (typedChar == '*' ||
      typedChar == '`' ||
      typedChar == '~' ||
      typedChar == '_') {
    final tail = _tryInlineRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    // 收尾定界符先打、开定界符后补的场景(`诚邀你测试~~` 打完再回行首
    // 补 `~~`)：此时光标停在**开**定界符之后,上面的 `$` 锚定规则看的是
    // 光标左边,永远命中不了。
    return _tryOpenDelimRules(state, block, sel.extent.offset);
  }
  if (typedChar == ']') {
    var tail = _tryBbcodeAttrRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    // 先打闭标记、光标挪回来补开标记(`x[size=150]` 场景),同
    // _tryOpenDelimRules 的顺序无关设计。
    tail = _tryBbcodeOpenRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    // 无 attr 的 BBCode 标记([u]/[spoiler]):同上,先试收尾再试补开标记。
    tail = _tryBbcodeMarkRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    return _tryBbcodeMarkOpenRules(state, block, sel.extent.offset);
  }
  if (typedChar == '>') {
    // HTML 样式标签(`<small>`/`<big>`/`<mark>`/`<sup>`/`<sub>`/`<kbd>`),
    // 同 BBCode 无 attr 版三种顺序全支持。
    var tail = _tryHtmlMarkRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    return _tryHtmlMarkOpenRules(state, block, sel.extent.offset);
  }
  // 光标后紧跟闭定界符:先打好 `****` 再回中间填内容的场景(收尾定
  // 界符不是最后敲的,上面的 $ 锚定规则永远不会命中)—— 把光标后的
  // 闭定界符拼上再匹配,补齐"实时渲染"预期。
  final pairTail = _tryInsidePairRules(state, block, sel.extent.offset);
  if (pairTail != InputRuleOutcome.none) return pairTail;
  // 同理,BBCode 版:先打好 `[size=150][/size]`(内容留空)再回中间敲
  // 内容 —— 每敲一个字都要重判,因为敲的字符本身不是触发字符(不是
  // `]`),前面几条规则的字符白名单派发不到这里。
  final bbTail = _tryBbcodeInsidePairRules(state, block, sel.extent.offset);
  if (bbTail != InputRuleOutcome.none) return bbTail;
  // 同理,HTML 标签版。
  return _tryHtmlInsidePairRules(state, block, sel.extent.offset);
}

// ---------------------------------------------------------------------
// 块级规则(行首标记 + 空格)
// ---------------------------------------------------------------------

final _headingRe = RegExp(r'^(#{1,6}) $');
final _bulletRe = RegExp(r'^[-*] $');
final _orderedRe = RegExp(r'^(\d{1,9})[.)] $');
final _quoteRe = RegExp(r'^> $');
final _hrRe = RegExp(r'^(---|\*\*\*|___) $');
// Obsidian callout 语法起手式:`[!note] `。先敲 `> ` 进引用层再敲这个
// 也一样命中——`> ` 那条规则已经把标记文本清空,`before` 到这里已经不
// 带字面 `> ` 了。类型只收字母,不含 `+`/`-` 折叠后缀——那个后缀打字
// 场景太少见,手打先只覆盖最常用的"裸类型名"。
final _calloutRe = RegExp(r'^\[!([a-zA-Z]+)\] $');

InputRuleOutcome _tryBlockRules(EditorState state, TextBlock block, int caret) {
  // 块级标记必须在**行首**起敲。基准是光标所在**软行**的行首(段内
  // '\n' 软换行后的第二行打 `- ` 同样要触发 —— 对齐官方 rich editor:
  // ProseMirror 里 Shift+Enter 后的行首同样吃 textblockTypeInputRule)。
  // 软行行首触发时块会在软换行处分裂,当前软行起的内容变成新块。
  final text = block.content.text;
  final lineStart = caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;
  final before = text.substring(lineStart, caret);
  if (before.contains('\n')) return InputRuleOutcome.none;
  // 标记区不能有原子(emoji 后打 "# " 不是标题意图)
  for (var i = lineStart; i < caret; i++) {
    if (block.content.isAtomAt(i)) return InputRuleOutcome.none;
  }
  final atBlockStart = lineStart == 0;
  final markerLength = caret - lineStart;

  // hr:任何块类型都可触发(空段打 --- )。**只认真正的块首**:hr 是
  // 「整块换岛」语义(视图层删块插岛),软行触发会把整段前文一起吞掉
  // —— 取舍:软行场景极少见(想插分隔线先回车分段即可),不值得为它
  // 把 hrRequest 改成「切块+局部替换」的复杂协议。callout 同理。
  final hr = _hrRe.firstMatch(before);
  if (hr != null && block.isParagraph && atBlockStart) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      transform: (b) => b, // 类型不变,仅清标记;岛由视图层插
    );
    return InputRuleOutcome.hrRequest;
  }

  // callout:任何段落块都可触发(空段打 "[!note] " 或引用层里打
  // "> [!note] ")。同 hr,只认块首(整块经 cook 换岛语义)。
  final callout = _calloutRe.firstMatch(before);
  if (callout != null && block.isParagraph && atBlockStart) {
    state.pendingCalloutType = callout.group(1)!.toLowerCase();
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      transform: (b) => b, // 类型不变,仅清标记;岛由视图层经 cook 插
    );
    return InputRuleOutcome.calloutRequest;
  }

  // 已是结构块(heading/listItem)不再转换;引用层可继续叠标记
  final heading = _headingRe.firstMatch(before);
  if (heading != null && !block.isHeading && !block.isListItem) {
    final level = heading.group(1)!.length;
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      lineStart: lineStart,
      transform: (b) => b.asHeading(level),
    );
    return InputRuleOutcome.applied;
  }

  if (_bulletRe.hasMatch(before) && !block.isListItem && !block.isHeading) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      lineStart: lineStart,
      transform: (b) => b.asListItem(ordered: false),
    );
    return InputRuleOutcome.applied;
  }

  final ordered = _orderedRe.firstMatch(before);
  if (ordered != null && !block.isListItem && !block.isHeading) {
    final start = int.tryParse(ordered.group(1)!) ?? 1;
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      lineStart: lineStart,
      transform: (b) => b.asListItem(ordered: true, listStart: start),
    );
    return InputRuleOutcome.applied;
  }

  if (_quoteRe.hasMatch(before) && block.isParagraph) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: markerLength,
      lineStart: lineStart,
      transform: (b) => b.copyWith(
        containers: [
          QuoteFrame(groupId: nextFrameGroupId()),
          ...b.containers,
        ],
      ),
    );
    return InputRuleOutcome.applied;
  }

  return InputRuleOutcome.none;
}

// ---------------------------------------------------------------------
// 行内规则(收尾定界符)
// ---------------------------------------------------------------------

/// 定界符表:见 inline_pair_defs.dart([kInlineRules],与 ir spin 共享
/// 单一真相)。

InputRuleOutcome _tryInlineRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  // 光标处于 inlineCode mark 内:字面量区,不触发
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (re, kind, delim) in kInlineRules) {
    final m = re.firstMatch(before);
    if (m == null) continue;
    final contentText = m.group(1)!;
    final matchStart =
        m.start +
        (m.group(0)!.length - (contentText.length + delim.length * 2));
    // 区间内含原子:FFFC 参与正则会当普通字符 —— 允许(emoji 可加粗),
    // 但含 '\n' 不允许(跨软换行不成对)。
    if (contentText.contains('\n')) continue;

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: matchStart,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// BBCode 属性标记(size/color/bgcolor)三种形态的表全部派生自
/// inline_pair_defs.dart 的 [kBbcodeAttrSpecs](完整对 [kBbcodeAttrRules]、
/// 补开标记锚定版 [kBbcodeOpenRules]、非锚定版 [kBbcodeOpenPatterns])。

/// `[size=N]x[/size]` / `[color=#xxx]x[/color]` / `[bgcolor=...]` 收尾
/// `]` 触发 —— 与 `**x**` 同级的即打即渲染,不必等回车送 cook。
InputRuleOutcome _tryBbcodeAttrRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (re, kind, closeTag) in kBbcodeAttrRules) {
    final m = re.firstMatch(before);
    if (m == null) continue;
    final attr = m.group(1)!;
    final contentText = m.group(2)!;
    if (contentText.contains('\n')) continue;
    final openTag = m
        .group(0)!
        .substring(
          0,
          m.group(0)!.length - contentText.length - closeTag.length,
        );
    final matchStart = m.start;

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: matchStart,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
      attr: attr,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 补打 BBCode **开**标记触发:右边已经有配对的闭标记
/// (`x[size=150]大[/size]` 这种"先打后半截、再回来补前半截"的写法)。
/// 同 [_tryOpenDelimRules],开/闭标记不等长需要分开处理。
InputRuleOutcome _tryBbcodeOpenRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }
  final before = text.substring(0, caret);

  for (final (openRe, kind, closeTag) in kBbcodeOpenRules) {
    final openM = openRe.firstMatch(before);
    if (openM == null) continue;
    final openStart = openM.start;
    final openTag = openM.group(0)!;

    final rest = text.substring(caret);
    final nl = rest.indexOf('\n');
    final line = nl < 0 ? rest : rest.substring(0, nl);
    final closeAt = line.indexOf(closeTag);
    if (closeAt <= 0) continue; // 没有闭标记 / 内容为空
    final contentText = line.substring(0, closeAt);
    if (contentText.contains('[') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openStart,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
      attr: openM.group(1),
      // 光标本来就在开标记之后(内容首),别甩到尾巴上
      caretAtEnd: false,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 无 attr BBCode 标记表:见 inline_pair_defs.dart([kBbcodeMarkTags])。

/// `[u]x[/u]` / `[spoiler]x[/spoiler]` 收尾 `]` 触发。
InputRuleOutcome _tryBbcodeMarkRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (openTag, kind, closeTag) in kBbcodeMarkTags) {
    if (!before.endsWith(closeTag)) continue;
    final beforeClose = before.substring(0, before.length - closeTag.length);
    final openAt = beforeClose.lastIndexOf(openTag);
    if (openAt < 0) continue;
    final contentText = beforeClose.substring(openAt + openTag.length);
    if (contentText.isEmpty ||
        contentText.contains('\n') ||
        contentText.contains('[') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openAt,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 补打 `[u]`/`[spoiler]` **开**标记触发:右边已经有配对的闭标记。
InputRuleOutcome _tryBbcodeMarkOpenRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (openTag, kind, closeTag) in kBbcodeMarkTags) {
    final openStart = caret - openTag.length;
    if (openStart < 0 || !text.startsWith(openTag, openStart)) continue;

    final rest = text.substring(caret);
    final nl = rest.indexOf('\n');
    final line = nl < 0 ? rest : rest.substring(0, nl);
    final closeAt = line.indexOf(closeTag);
    if (closeAt <= 0) continue;
    final contentText = line.substring(0, closeAt);
    if (contentText.contains('[') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openStart,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
      caretAtEnd: false,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 光标后紧跟 BBCode 闭标记的"填内容"匹配:`[size=150]|[/size]` 这种
/// 先打好整对空标记、再回中间敲内容的写法。同 [_tryInsidePairRules],
/// 但要覆盖 attr 版(size/color/bgcolor)和无 attr 版(u/spoiler)。
///
/// 每敲一个内容字符都要重判 —— 敲的字符本身不是 `]`,派发不到前面
/// 那几条收尾规则,只能靠这条兜底(挂在 [tryApplyInputRules] 末尾,
/// 对所有非特殊字符都会跑一次)。
InputRuleOutcome _tryBbcodeInsidePairRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }
  final before = text.substring(0, caret);

  // attr 版:size/color/bgcolor。[kBbcodeOpenRules] 是 `$` 锚定的(给
  // "刚打完开标记,光标就在后面"那条规则用),这里要在 `before` 中间
  // 找,不能锚在串尾 —— 用不锚定的版本,取离光标最近(最后)的一个。
  for (final (openRe, kind, closeTag) in kBbcodeOpenPatterns) {
    if (!text.startsWith(closeTag, caret)) continue;
    final matches = openRe.allMatches(before);
    if (matches.isEmpty) continue;
    final openM = matches.last;
    final contentText = before.substring(openM.end);
    if (contentText.isEmpty ||
        contentText.contains('\n') ||
        contentText.contains('[') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openM.start,
      delimLength: closeTag.length,
      openLength: openM.end - openM.start,
      contentLength: contentText.length,
      kind: kind,
      attr: openM.group(1),
    );
    return InputRuleOutcome.applied;
  }

  // 无 attr 版:u/spoiler
  for (final (openTag, kind, closeTag) in kBbcodeMarkTags) {
    if (!text.startsWith(closeTag, caret)) continue;
    final openAt = before.lastIndexOf(openTag);
    if (openAt < 0) continue;
    final contentText = before.substring(openAt + openTag.length);
    if (contentText.isEmpty ||
        contentText.contains('\n') ||
        contentText.contains('[') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openAt,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// HTML 样式标签表:见 inline_pair_defs.dart([kHtmlMarkTags])。

/// `<small>x</small>` 等收尾 `>` 触发。
InputRuleOutcome _tryHtmlMarkRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (openTag, kind, closeTag) in kHtmlMarkTags) {
    if (!before.endsWith(closeTag)) continue;
    final beforeClose = before.substring(0, before.length - closeTag.length);
    final openAt = beforeClose.lastIndexOf(openTag);
    if (openAt < 0) continue;
    final contentText = beforeClose.substring(openAt + openTag.length);
    if (contentText.isEmpty ||
        contentText.contains('\n') ||
        contentText.contains('<') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openAt,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 补打 HTML **开**标签触发:右边已经有配对的闭标签。
InputRuleOutcome _tryHtmlMarkOpenRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (openTag, kind, closeTag) in kHtmlMarkTags) {
    final openStart = caret - openTag.length;
    if (openStart < 0 || !text.startsWith(openTag, openStart)) continue;

    final rest = text.substring(caret);
    final nl = rest.indexOf('\n');
    final line = nl < 0 ? rest : rest.substring(0, nl);
    final closeAt = line.indexOf(closeTag);
    if (closeAt <= 0) continue;
    final contentText = line.substring(0, closeAt);
    if (contentText.contains('<') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openStart,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
      caretAtEnd: false,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 光标后紧跟 HTML 闭标签的"填内容"匹配:`<small>|</small>` 这种先打
/// 好整对空标签、再回中间敲内容的写法。同 [_tryBbcodeInsidePairRules]。
InputRuleOutcome _tryHtmlInsidePairRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }
  final before = text.substring(0, caret);

  for (final (openTag, kind, closeTag) in kHtmlMarkTags) {
    if (!text.startsWith(closeTag, caret)) continue;
    final openAt = before.lastIndexOf(openTag);
    if (openAt < 0) continue;
    final contentText = before.substring(openAt + openTag.length);
    if (contentText.isEmpty ||
        contentText.contains('\n') ||
        contentText.contains('<') ||
        contentText.startsWith(' ') ||
        contentText.endsWith(' ')) {
      continue;
    }

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: openAt,
      delimLength: closeTag.length,
      openLength: openTag.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 补打**开**定界符触发:右边已经有配对的闭定界符。
///
/// `~~诚邀你测试~~` 这种"先打后半截、再回来补前半截"的写法,光标停在开
/// 定界符之后,[_tryInlineRules] 的 `$` 锚定正则只看光标左边,一条都命中
/// 不了 —— 表现为怎么打都不渲染。这里把光标**右边**到闭定界符的那段拼
/// 回去,用同一批正则判定,规则集保持单一来源。
///
/// 闭定界符只在当前**行**内找(不跨软换行),跟其它规则同口径。
InputRuleOutcome _tryOpenDelimRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (re, kind, delim) in kInlineRules) {
    final open = caret - delim.length;
    if (open < 0) continue;
    // 光标左边恰好是一个完整的开定界符
    if (!text.startsWith(delim, open)) continue;
    // 再往左不能还是同类定界字符(`***x**` 归属不明,不触发)
    if (open > 0 && text[open - 1] == delim[0]) continue;

    final rest = text.substring(caret);
    final nl = rest.indexOf('\n');
    final line = nl < 0 ? rest : rest.substring(0, nl);
    final closeAt = line.indexOf(delim);
    if (closeAt <= 0) continue; // 没有闭定界符 / 内容为空
    // 闭定界符后面不能还是同类定界字符
    final afterClose = closeAt + delim.length;
    if (afterClose < line.length && line[afterClose] == delim[0]) continue;

    final candidate = delim + line.substring(0, afterClose);
    final m = re.firstMatch(candidate);
    // 必须整段命中,否则 `~~a~~b~~` 这种会切错边界
    if (m == null || m.start != 0 || m.group(0)!.length != candidate.length) {
      continue;
    }
    final contentText = m.group(1)!;
    if (contentText.contains('\n')) continue;

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: open,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
      // 光标本来就在内容首,别甩到尾巴上
      caretAtEnd: false,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 光标后紧跟闭定界符的"填内容"匹配:`**|**` 里打字 → 光标后是 `**`,
/// 把它拼到光标前文本上正则匹配。命中 = 完整 `**x**` 模式,内容恰好
/// 终于光标(闭定界符位于光标处)。
InputRuleOutcome _tryInsidePairRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret >= text.length) return InputRuleOutcome.none;
  final next = text[caret];
  if (next != '*' && next != '`' && next != '~' && next != '_') {
    return InputRuleOutcome.none;
  }
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  final before = text.substring(0, caret);
  for (final (re, kind, delim) in kInlineRules) {
    if (!text.startsWith(delim, caret)) continue;
    // 闭定界符后不能还是同类定界字符(`**q***` 归属不明,不触发)。
    final after = caret + delim.length;
    if (after < text.length && text[after] == delim[0]) continue;
    final m = re.firstMatch(before + delim);
    if (m == null) continue;
    final contentText = m.group(1)!;
    if (contentText.contains('\n')) continue;
    final matchStart =
        m.start +
        (m.group(0)!.length - (contentText.length + delim.length * 2));

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: matchStart,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// `![alt](src)` / `[文字](href)` 收尾 `)` 触发。图片变原子,链接变
/// link mark(href 进 attr)。
InputRuleOutcome _tryImageOrLinkRule(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  final imgM = _imageTailRe.firstMatch(before);
  if (imgM != null) {
    final img = parseImageMarkdown(imgM.group(0)!);
    if (img != null) {
      state.sealHistory();
      state.applyImageInputRule(
        block.id,
        start: imgM.start,
        end: caret,
        image: img,
      );
      return InputRuleOutcome.applied;
    }
  }

  final linkM = _linkTailRe.firstMatch(before);
  if (linkM != null) {
    final label = linkM.group(1)!;
    // 标签里含原子(哨兵)不拆:`[![图](…)](href)` 这种嵌套交给 cook。
    if (!label.contains(kAtomChar)) {
      state.sealHistory();
      state.applyLinkInputRule(
        block.id,
        start: linkM.start,
        end: caret,
        label: label,
        href: linkM.group(2)!,
      );
      return InputRuleOutcome.applied;
    }
  }
  return InputRuleOutcome.none;
}

final _imageTailRe = RegExp(r'!\[[^\]]*\]\([^)\s]*\)$');
final _linkTailRe = RegExp(r'(?<!!)\[([^\]]+)\]\(([^)\s]*)\)$');
