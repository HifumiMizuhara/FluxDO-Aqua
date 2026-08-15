/// 长串软换行 —— 给超长无空格西文/数字串插零宽空格(U+200B)作换行点,
/// 模拟 CSS `overflow-wrap: break-word`(Discourse `.cooked` 的换行行为)。
///
/// **为什么需要**:Flutter 的 Text 对连续无空格 ASCII(字母/数字/符号)不提供
/// 换行点(等价 `word-break: normal`),一个超长 token(如 `asdfasdf…` / 长 URL /
/// 行内代码里的长串)会**溢出容器**。U+200B 是**次级**换行点:排版优先在空格
/// 处断,只有一个 token 长到一行放不下时才在 U+200B 断 —— 因此正常英文单词
/// 不受影响,只有真正的超长串才被拆开。
///
/// **一致性铁律**:[InlineFlattener](渲染 TextSpan)与 [buildInlineProjection]
/// (选区/plainText 的渲染偏移映射)对 **TextRun / InlineCodeRun 的文本必须调用
/// 同一个本函数**,否则两者的渲染偏移模型错位、选区会跳。
///
/// 插入的 U+200B 会进入 render text 与 projection 的 logicalText,选区导出侧
/// (SelectionExporter)负责 `strip` 掉,保证复制/引用文本干净。
library;

/// 零宽空格(zero-width space),作为软换行点。
const String kSoftBreakChar = '​';

/// 行内代码两侧的不换行空格(NBSP,U+00A0)—— "粘性内边距"。
///
/// 对齐 legacy 预处理:` <code>…</code> `。作用:
/// - painter 的水平 padding(3.5px)出血落在 NBSP 的空白里(NBSP 宽 ≈ 半个
///   空格字符),**不会画到相邻文字底下**(code 紧贴文字时的溢出就是没它);
/// - NBSP 不可换行 → 间隙和 code 粘在一起,不会孤行。
///
/// 一致性:flattener 渲染层加,projection_builder 以空投影条目(logicalText
/// `''`)同步偏移,复制/引用文本不含它。
const String kInlineCodePadChar = ' ';

/// 触发软换行的最小连续可断字符数。低于此长度的 run 原样返回(正常英文词、
/// 短 token 零变化 → golden/选区不受影响)。30 ≈ 窄屏一行等宽字符数,超过必溢出。
const int _kRunThreshold = 30;

/// ASCII 可见字符(0x21..0x7E:字母/数字/标点,不含空格)视为"可断"。空格本身
/// 是天然换行点、CJK(> 0x7E 的中日韩)有逐字换行点,均不处理。
bool _isBreakable(int rune) => rune >= 0x21 && rune <= 0x7E;

/// 给 [text] 里连续 ≥ [_kRunThreshold] 的可断字符 run 逐字符后插 U+200B。
/// 其余(短 run、空格、CJK)原样保留。
String insertSoftBreaks(String text) {
  // 快路径:整体短于阈值不可能有超长 run。
  if (text.length < _kRunThreshold) return text;

  final out = StringBuffer();
  final run = StringBuffer();

  void flush() {
    if (run.isEmpty) return;
    final s = run.toString();
    run.clear();
    if (s.length >= _kRunThreshold) {
      for (var i = 0; i < s.length; i++) {
        out.write(s[i]);
        if (i != s.length - 1) out.write(kSoftBreakChar);
      }
    } else {
      out.write(s);
    }
  }

  for (final rune in text.runes) {
    if (_isBreakable(rune)) {
      run.writeCharCode(rune);
    } else {
      flush();
      out.writeCharCode(rune);
    }
  }
  flush();
  return out.toString();
}
