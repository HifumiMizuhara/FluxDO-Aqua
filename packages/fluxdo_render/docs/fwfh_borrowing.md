# fwfh 借鉴清单

> 状态:阶段 0.3 输出
> 调研对象:`flutter_widget_from_html_core` 0.17.2
> 调研日期:2026-06-22
> 用途:为 fluxdo_render 自研引擎提供"借鉴 vs 不借鉴"的设计参考

---

## 0. 方法论

读完 fwfh 5 个核心文件(`build_op.dart` / `core_build_tree.dart` /
`flattener.dart` / `margin_vertical.dart` / `core_widget_factory.dart`)
后,把每个抽象/算法/API 按下表分类:

| 标记 | 含义 |
|------|------|
| `[抄设计]` | 借鉴整套设计模式,但用我们自己的类型实现 |
| `[抄代码]` | 纯算法逻辑可整段照搬(改 import 即可) |
| `[抄数据]` | 静态数据资产(如 UA stylesheet)可直接复制 |
| `[不抄]` | 跟我们架构不符或负担大于收益,不借鉴 |
| `[待定]` | 需要更深调研或验证才能决定 |

---

## 1. `BuildOp` — 扩展点契约

### fwfh 现状

`BuildOp` 是个 `@immutable` 数据类,包含一组 callback typedef
(`onParsed` / `onRenderBlock` / `onRenderInline` / `onRenderedBlock` /
`onRenderedChildren` / `onVisitChild` / `defaultStyles`)。一个 element
可挂多个 op,按 `priority` 升序触发。挂载在 `BuildTree.register(op)`,
内部用 `SplayTreeSet` 排序。

### 借鉴判定

**`[抄设计]`** —— 这是 fwfh 最值得借鉴的架构哲学,Discourse 渲染场景
完全适用(同一个 element 上常有多个 class 组合,如 `<aside class="quote spoiler">`)。

### 我们的对应设计

```dart
// packages/fluxdo_render/lib/src/op/node_op.dart
@immutable
class NodeOp {
  const NodeOp({
    this.priority = NodeOpPriority.normal,
    this.debugLabel,
    this.onParsed,
    this.onRenderBlock,
    this.onRenderInline,
    this.onRenderedChildren,
    this.onVisitChild,
  });

  final int priority;
  final String? debugLabel;
  final OnParsed? onParsed;
  final OnRenderBlock? onRenderBlock;
  final OnRenderInline? onRenderInline;
  final OnRenderedChildren? onRenderedChildren;
  final OnVisitChild? onVisitChild;
}

// 钩子签名 —— 类型替换为我们自己的 Node / NodeBuilder
typedef OnParsed = NodeBuildTree Function(NodeBuildTree tree);
typedef OnRenderBlock = Widget Function(NodeBuildTree tree, Widget child);
typedef OnRenderInline = void Function(NodeBuildTree tree);
typedef OnRenderedChildren = Widget? Function(NodeBuildTree tree, List<Widget> children);
typedef OnVisitChild = void Function(NodeBuildTree parent, NodeBuildTree sub);
```

### 差异/简化

- **不区分 `onRenderedBlock`(只读 hook)**:fwfh 的"只读 hook"只在
  Anchor 系统用,我们用不上 anchor。如果将来需要,再加。
- **不区分 `alwaysRenderBlock`**:我们的节点已经类型化(`Node` 派生层
  自带块/内联区分),不需要从 op 反推。
- **`onRenderBlock` 返回 `Widget` 而非 `WidgetPlaceholder`**:我们不
  采用 fwfh 的 `WidgetPlaceholder.lazy` 延迟构造(见 §3 的判定)。

### 借鉴的算法

**`[抄代码]`** 同 priority + hashCode 稳定排序:

```dart
// 直接复制 fwfh 的 _CoreBuildOp._compare
int _compareOps(NodeOp a, NodeOp b) {
  final byPriority = a.priority.compareTo(b.priority);
  if (byPriority != 0) return byPriority;
  return a.hashCode.compareTo(b.hashCode);
}
```

### priority 数轴

**`[抄数据]`** 借鉴 fwfh 的分层数轴常量(Early/Normal/BoxModel/Late + 1e9 step):

```dart
abstract final class NodeOpPriority {
  static const int early = -3000000000000000;
  static const int normal = 1000000000000000;
  static const int boxModel = 5000000000000000;
  static const int inlineBlock = 9000003000000000;
  static const int late_ = 9000005000000000;
  static const int step = 1000000000;
}
```

理由:Discourse class 组合也有顺序依赖(如 `padding` 必须在 `border`
之前在 `margin` 之前),这套数轴已经被 fwfh 5 年实践验证。

---

## 2. `BuildTree` / `CoreBuildTree` — 解析+构建状态机

### fwfh 现状

`CoreBuildTree` 一个对象承载 4 件事:
- bits 列表(text/whitespace/widget/sub-tree)
- 样式声明集合(`_LockableDeclarations`,parse 完后 lock)
- buildOps 集合(`SplayTreeSet`)
- inheritance resolvers(惰性 CSS 继承链)

每个 DOM element 对应一个 `CoreBuildTree`。

### 借鉴判定

**`[不抄]` 整体设计**。理由:

1. **fwfh 的 BuildTree 是为"动态注册扩展"设计的中间态**。我们的架构
   不同 —— HTML→Node 转换在 Dart `ParagraphParser` 完成,产物已经是
   **强类型 Node**,不需要"bits + ops"的可变中间态。
2. **csslib 作为样式 IR 太重**。fwfh 加一条样式都得 `css.parse('*{...}')`
   再 `collectDeclarations()`,这是 hot path 上的明确浪费。Discourse
   cooked html 只有固定一组 class,我们用直接的 enum/struct 表达 style
   覆盖即可。
3. **`InheritanceResolvers` 用 BuildContext.resolve 延迟求值**是为支持
   fwfh 的"一次解析 N 次 rebuild"。我们的 Node 是 immutable,style 已
   全部解析完,运行时无需再 resolve。

### 我们的对应设计

```dart
// 输入:Rust 给的 immutable Node tree(无 op、无 bits)
sealed class Node { String get id; }

// 中间态:在 Dart 端为某个 Node 附加 op 链 + 计算后的 layout style
class NodeBuildTree {
  final Node node;
  final List<NodeOp> ops;          // 按 priority 排序后的 op 链
  final ResolvedStyle style;       // parse 时一次性算好,不延迟
  final List<NodeBuildTree> children;  // 仅块节点有

  Widget build(BuildContext context) { ... }
}
```

NodeBuildTree 仅在 op pipeline 之内存活,build 完即被丢弃 —— 不会有
"build 完后 op 还要持续监听 context"的负担。

### 可零成本照搬的算法

**`[抄代码]` `_addText` 的 ASCII whitespace 切分**(基于 infra spec)。这段
逻辑是 W3C 标准,在 `_addText` 里被严格实现:

```dart
// 来源:fwfh core_build_tree.dart 第 ~300 行的 _addText
// leading whitespace 单独 add,trailing 单独 add,中间内容把连续
// whitespace 拆出,单 ASCII 空格(32)做 micro optimization 跳过。
// 完整 regex 三件套:
final _regExpSpaceLeading = RegExp(r'^[^\S ]+', multiLine: true);
final _regExpSpaceTrailing = RegExp(r'[^\S ]+$', multiLine: true);
final _regExpSpaces = RegExp(r'\s+');
```

放在 `lib/src/parse/whitespace.dart`,作为纯工具函数。

---

## 3. `Flattener` — 把混合 bits 压成 RichText / Widget 列表

### fwfh 现状

`Flattener` 遍历 `BuildTree` 所有 bits,按"连续 text+inline widget →
合成 RichText"+"独立块 widget → 独立 placeholder"两路输出。状态机式
设计,`_strings` 累积当前段,`_childrenBuilder` 延迟到 builder 内才构造
InlineSpan(为了能在 build context 内 resolve 继承样式)。

### 借鉴判定

**`[抄设计]` 主流程**(扁平化为 `List<Widget>` + 一段连续 inline 内容产
出一个 RichText),**`[不抄]` 延迟到 BuildContext 内构造**这部分。

**理由**:
- 主流程是任何"HTML inline+block 混合 → Flutter widget"必经的算法,
  无论是不是 fwfh,这个状态机都得有。
- 延迟构造是为支持 fwfh 的 "InheritedProperties 跨 resolver" 模型,
  我们不用 InheritedProperties,Node 都已经带好 ResolvedStyle,直接构造
  TextSpan 即可。

### 我们的对应设计

```dart
// packages/fluxdo_render/lib/src/flatten/inline_flattener.dart
class InlineFlattener {
  InlineFlattener(this._textBuilder);
  final InlineSpan Function(TextRun run, ResolvedStyle style) _textBuilder;

  /// 输入:一个块节点的子 InlineNode 列表
  /// 输出:压平后的 List<Widget>(可能含 RichText、块级 widget、InlineCustomWidget)
  List<Widget> flatten(List<InlineNode> children, ResolvedStyle parentStyle) { ... }
}
```

### 可零成本照搬的算法

**`[抄代码]` whitespace 折叠三模式**(`pre` / `nowrap` / `normal`):

来源 `flattener.dart` 中 `_String.toText`(extension on `List<_String>`):
- `pre`: 原样保留
- `nowrap`: 空格换 ` `
- `normal`: leading/trailing whitespace 在 isFirst/isLast 时 trim;中间
  连续 whitespace 折叠为单空格(除非 shouldBeSwallowed)
- isLast 时去掉末尾 `\n`

这是 CSS 标准行为,直接抄。

**`[待定]` trailing whitespace 借用下一段 resolver 的微妙规则**
(`effectiveInheritanceResolvers`)。

理由:这个规则只在"同一 paragraph 内跨样式边界 trailing space 归属
哪个样式"才生效。我们的 Node 模型还没决定怎么表达"两段相邻 InlineNode
共享 whitespace 归属",等阶段 1 设计 InlineNode 后再回来评估。

---

## 4. `HeightPlaceholder` + `ColumnPlaceholder._buildWidgets` — margin 折叠

### fwfh 现状

`HeightPlaceholder` = 不可被 wrap 的 `WidgetPlaceholder` 子类,代表
margin-top/bottom 占位。`mergeWith` 取 max(CSS margin collapsing
语义)。

`ColumnPlaceholder._buildWidgets` 在 column 折叠时:
- 首段连续 HeightPlaceholder → 全部 mergeWith 提为 marginTop
- 中段相邻两个 HeightPlaceholder → 后者 mergeWith 进 prev
- 尾段最后一个 HeightPlaceholder → 提为 marginBottom
- 嵌套 ColumnPlaceholder 自动扁平化,实现父子两层 margin 跨边界折叠

用 `Expando<int>` + 引用计数式的 `skipBuildHeightPlaceholder` flag
告诉 placeholder "当前在折叠遍历中,先别展开成 SizedBox"。

### 借鉴判定

**`[抄代码]` 整套折叠规则**,**`[抄设计]` Expando 引用计数 flag 模式**,
但**`[不抄]` 跟 WidgetPlaceholder 系统的耦合**。

理由:margin collapsing 是 CSS 标准行为,Discourse 帖子里大量 `<p>`、
`<h1-6>`、`<ul>` 之间需要正确折叠,否则视觉跟 web 端差异巨大。这套
状态机已经验证可工作。

### 我们的对应设计

```dart
// packages/fluxdo_render/lib/src/flow/margin_collapse.dart

/// 节点间垂直 margin 占位,可与相邻同类 mergeWith。
class _MarginGap extends StatelessWidget {
  const _MarginGap(this.height);
  final double height;
  // 不用 InheritedProperties,直接 logical px(fontSize 在 ResolvedStyle 内
  // 已经解析完)。
}

/// 容器在 layout pass 内对子 widget 列表做 margin 折叠。
/// 算法照抄 fwfh ColumnPlaceholder._buildWidgets 的两态扫描。
List<Widget> collapseVerticalMargins(List<Widget> children) {
  // state == 0 还在累积 marginTop,state == 1 已进入正文
  ...
}
```

### 不照搬的部分

- 嵌套 ColumnPlaceholder 扁平化 → 我们用一层直接的 SliverList(详情页
  长帖)/Column(其他场景),不需要嵌套折叠。如果将来引入 quote/details
  内部嵌套段落,再加。
- BuildContext Expando 引用计数 → 改用普通的"在 layout 容器内显式调
  `collapseVerticalMargins(children)` 一次性算完",更直接。

---

## 5. `WidgetFactory` — Build API 中枢

### fwfh 现状

`WidgetFactory` 同时承担 4 件事:
- 持有 HtmlWidget 状态(`_widget`,reset 时刷新)
- tag/attribute level dispatch(`parse(tree)` 巨型 switch)
- style declaration dispatch(`parseStyle(tree, decl)`)
- 一组 `buildXxx` widget 工厂方法(可被子类 override)

每个 build*** 方法都接 `BuildTree tree`,与 fwfh 抽象强耦合。

### 借鉴判定

**`[抄设计]` 工厂可继承覆盖的思路**,**`[不抄]` `BuildTree` 耦合**。

理由:
- 我们的"用户卡 bio / AI 分享卡 / 通知预览"等嵌套场景需要简化版渲染
  (无某些节点),用工厂继承覆盖比 if-else 优雅。
- 但 fwfh 的 `WidgetFactory` 跟 `BuildTree` 死锁(每个 buildXxx 都接 tree
  参数),我们的工厂不需要这个 — 因为 Node 已经携带所有渲染信息。

### 我们的对应设计

```dart
// packages/fluxdo_render/lib/src/render/node_factory.dart
class NodeFactory {
  // 每种 Node 一个 build,子类可 override
  Widget? buildParagraph(BuildContext context, ParagraphNode node, RenderContext ctx);
  Widget? buildHeading(BuildContext context, HeadingNode node, RenderContext ctx);
  Widget? buildCodeBlock(BuildContext context, CodeBlockNode node, RenderContext ctx);
  // ...

  // dispatch 入口
  Widget build(BuildContext context, Node node, RenderContext ctx) {
    return switch (node) {
      ParagraphNode() => buildParagraph(context, node, ctx) ?? const SizedBox.shrink(),
      HeadingNode() => buildHeading(context, node, ctx) ?? const SizedBox.shrink(),
      // ...
    };
  }
}

class SimplifiedNodeFactory extends NodeFactory {
  // 用户卡 bio:重写 buildPoll/buildIframe/buildLazyVideo 等返回 placeholder
  @override
  Widget? buildPoll(...) => const _UnsupportedPlaceholder('poll');
  @override
  Widget? buildIframe(...) => const _UnsupportedPlaceholder('iframe');
}
```

dispatch 用 Dart 3 `sealed class` + `switch` exhaustive check,编译期保证
所有 Node 都被处理。

### 借鉴的数据资产

**`[抄数据]` 末段 30+ 个 `_tagH1` / `_tagP` / `_tagFigure` 等 static StylesMap**
是 UA stylesheet。这是 5 年实践积累的默认样式表,直接复制到我们的
`default_styles.dart`,改 map 类型即可:

```dart
// packages/fluxdo_render/lib/src/style/default_styles.dart
const Map<String, Map<String, String>> defaultTagStyles = {
  'h1': {
    'display': 'block',
    'font-size': '2em',
    'font-weight': 'bold',
    'margin': '0.67em 0',
  },
  'h2': { ... },
  // ...
};
```

不需要 csslib 的 `Declaration`,用纯 string map 即可。运行时把 string 转
我们的 `ResolvedStyle` 字段(fontSize / margin / 等)。

---

## 6. 跨文件的可复用算法清单

| 来源 | 算法 | 借鉴等级 | 我们的位置 |
|------|------|----------|-----------|
| `core_build_tree.dart` `_addText` | ASCII whitespace 切分(infra spec) | `[抄代码]` | `lib/src/parse/whitespace.dart` |
| `flattener.dart` `_String.toText` | `normal`/`nowrap`/`pre` 三种 whitespace 折叠 | `[抄代码]` | `lib/src/flatten/whitespace_collapse.dart` |
| `flattener.dart` `effectiveInheritanceResolvers` | trailing whitespace 跨样式归属 | `[待定]` | 阶段 1 设计 InlineNode 后评估 |
| `margin_vertical.dart` `mergeWith` | margin collapsing = max 语义 | `[抄代码]` | `lib/src/flow/margin_collapse.dart` |
| `column.dart` `_buildWidgets` 两态扫描 | margin top/bottom 提升 + 相邻合并 | `[抄代码]` | 同上 |
| `core_widget_factory.dart` 末段 `_tagH1` 等 | UA stylesheet 数据 | `[抄数据]` | `lib/src/style/default_styles.dart` |
| `priorities.dart` 数轴常量 | Early/Normal/BoxModel/Late + 1e9 step | `[抄数据]` | `lib/src/op/node_op_priority.dart` |
| `_CoreBuildOp._compare` | priority + hashCode 稳定排序 | `[抄代码]` | `lib/src/op/_compare.dart` |

---

## 7. fwfh 的 5 个强耦合点(我们必须绕开)

记录这些是为了**审查每个新代码 PR 时,看是不是不小心抄进了这些
负担**。

1. **`BuildTree` 三件套**(`dom.Element` + `InheritanceResolvers` +
   `LockableList<css.Declaration>`)→ 我们不用 BuildTree,Node 是直接
   产物
2. **csslib 作为样式 IR** → 我们用 enum/struct,style 解析在 Rust 端
   完成(或 Dart 端一次性)
3. **`WidgetPlaceholder` + `WidgetPlaceholder.lazy`** → 我们的 NodeFactory
   直接返回 Widget,不延迟构造
4. **`Flattener` 的多态 bit 系统**(TextBit / WhitespaceBit / WidgetBit
   都得实现 `flatten(Flattened f)`) → 我们的 InlineNode 也是 sealed
   class + switch dispatch
5. **op priority 数轴的"块/内联判定语义"**(`alwaysRenderBlock ??
   onRenderBlock != null` 反推块) → 我们的 Node 自带块/内联区分,
   priority 仅用于 op 顺序,不参与块判定

---

## 8. 阶段 1 的输入清单

基于本调研,阶段 1(基础节点)动手时需要先做的事:

- [ ] 把 `[抄代码]` 标记的算法翻译到 `lib/src/` 对应位置
- [ ] 把 `[抄数据]` 标记的常量表 copy 进来
- [ ] 设计 `NodeBuildTree` + `NodeOp` 数据结构(参考 fwfh `BuildOp`
  签名但不要 `WidgetPlaceholder` 耦合)
- [ ] 设计 `NodeFactory` 基类(参考 fwfh `WidgetFactory` 的 buildXxx
  分类,但不要 BuildTree 耦合)
- [ ] 评估 `effectiveInheritanceResolvers` 的 trailing whitespace 规则
  是否需要实现(`[待定]`)

---

## 附录:数据来源文件清单

| fwfh 文件路径(0.17.2) | 本文档引用章节 |
|------|------|
| `lib/src/data/build_op.dart` | §1 |
| `lib/src/internal/core_build_tree.dart` | §2, §6 |
| `lib/src/internal/flattener.dart` | §3, §6 |
| `lib/src/internal/margin_vertical.dart` | §4, §6 |
| `lib/src/internal/ops/column.dart` | §4(_buildWidgets) |
| `lib/src/core_widget_factory.dart` | §5, §6 |
| `lib/src/data/priorities.dart` | §1, §6 |
