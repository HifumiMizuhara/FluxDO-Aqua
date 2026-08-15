# 节点优先级清单 + 排期

> 状态:阶段 0.9 输出
> 用途:从 25 种节点中,按"用户撞到频率 × 实现复杂度"排出阶段 1-4 的具体顺序
> 来源:`fluxdo_reader` audit (上次实验)+ 主项目现有 builder 代码 + dogfood 直觉

---

## 0. 排序逻辑

每个节点打两个分:

**频率(F)** 1-5,代表用户在普通帖子里撞到的概率
- 5:几乎每帖都有(段落、文本)
- 4:常见(标题、列表、链接、代码、emoji)
- 3:中等(引用、图片、mention)
- 2:偶见(投票、表格、math、details)
- 1:罕见(callout、policy、chat_transcript)

**复杂度(C)** 1-5,实现一个节点的工作量
- 1:纯文本/纯样式(段落、标题、br)
- 2:简单容器(列表、blockquote、hr)
- 3:含交互或子节点递归(spoiler、details、quote_card、链接)
- 4:重型 widget(code 高亮、table 虚拟化、iframe、image_grid)
- 5:有外部依赖或动画(poll、math、callout 粒子、lazy_video、lightbox)

**优先级 = F × (6 - C)** — 高频低成本最优先

---

## 1. 节点优先级表

| 节点 | F | C | 优先 | 阶段 | 备注 |
|---|---|---|---|---|---|
| paragraph | 5 | 1 | 25 | 1 | 段落、行内含 em/strong/code/br |
| heading | 4 | 1 | 20 | 1 | h1-h6 |
| inline_code | 4 | 1 | 20 | 1 | `<code>` 行内,纯样式 |
| horizontal_rule | 2 | 1 | 10 | 1 | `<hr>` |
| emoji | 4 | 2 | 16 | 1 | `<img class="emoji">` |
| list | 4 | 2 | 16 | 1 | ul/ol/li 含嵌套 |
| mention | 4 | 3 | 12 | 1 | `<a class="mention">` 含点击 → 用户卡 |
| link | 5 | 3 | 15 | 1 | `<a>` 含 link_click_count 注入 |
| blockquote | 3 | 2 | 12 | 1 | 普通 `<blockquote>`(不含 Callout 语法) |
| image | 3 | 3 | 9 | 1 | inline `<img>`,upload:// 解析、SVG 检测 |
| quote_card | 3 | 3 | 9 | 2 | aside.quote,含嵌套渲染 + 回跳 |
| code_block | 4 | 4 | 8 | 2 | 含语法高亮、复制按钮、Mermaid 检测 |
| spoiler | 3 | 3 | 9 | 2 | 块级 + 行内,含揭示 + 粒子动画 |
| details | 2 | 3 | 6 | 2 | `<details>` 折叠 + 嵌套子节点 |
| onebox | 3 | 4 | 6 | 2 | aside.onebox 6 子类型路由 |
| callout | 1 | 4 | 2 | 2 | Obsidian Callout 语法识别(从 blockquote 路由) |
| table | 2 | 4 | 4 | 2 | 含虚拟化 + 嵌套渲染 + screenshotMode |
| iframe | 2 | 4 | 4 | 2 | InAppWebView 嵌入 + 全屏 |
| math | 2 | 3 | 6 | 3 | flutter_math_fork,块级 + 行内 |
| poll | 2 | 5 | 2 | 3 | 投票 UI + API + 状态同步 |
| lazy_video | 2 | 4 | 4 | 3 | YouTube/Vimeo/TikTok 缩略图 + 展开 |
| footnote | 1 | 3 | 3 | 3 | sup.footnote-ref + popover + 列表 |
| local_date | 1 | 3 | 3 | 3 | discourse-local-date 多时区 |
| chat_transcript | 1 | 4 | 2 | 3 | Discourse Chat 插件聊天卡 |
| policy | 1 | 5 | 1 | 3 | 投票 + accept/revoke |
| image_grid | 3 | 4 | 6 | 4 | d-image-grid 网格 |
| lightbox | 3 | 3 | 9 | 4 | gallery 跨节点联动 |

`image_grid` 和 `lightbox` 名义上属阶段 4(图片体系),阶段 1-3 里可以
放占位实现(图片单独渲染但不联动 gallery)。

---

## 2. 阶段映射

### 阶段 1(基础节点,2-3 周,10 个节点)

按列表顺序实施,每个节点单独 PR:

1. `paragraph` + `text` + `em` + `strong` + `br`(打包成"段落 + 行内基础")
2. `heading` (h1-h6)
3. `link` (含 link_click_count 注入)
4. `inline_code`
5. `mention` (含点击 → 用户卡)
6. `emoji` (img.emoji)
7. `list` (ul/ol/li 含嵌套)
8. `blockquote`(普通,不含 Callout 路由)
9. `image` (inline img + upload:// + SVG 检测)
10. `horizontal_rule`

**阶段 1 退出标准**:
- 一份"纯文本帖子"(无引用 / 无代码块 / 无投票)能完整渲染
- 灰度开关切到 new 时,首页列表 + 详情页基础内容显示无差异
- golden + 单测全过
- 性能 benchmark 不退化

### 阶段 2(富节点,4-6 周,8 个节点)

11. `quote_card`
12. `code_block`
13. `spoiler`(块级 + 行内)
14. `details`
15. `onebox`(6 子类型)
16. `callout`(从 blockquote 语法路由)
17. `table`
18. `iframe`

**阶段 2 退出标准**:
- 绝大多数普通 post 完整渲染
- 长帖滚动 vsync p99 < 16ms
- dogfood ≥ 2 周

### 阶段 3(复杂节点,3-4 周,7 个节点)

19. `math`(块级 + 行内)
20. `poll`
21. `lazy_video`
22. `footnote`
23. `local_date`
24. `chat_transcript`
25. `policy`

**阶段 3 退出标准**:
- 25 种节点全部完成
- 灰度默认切到 new
- 长帖卡顿问题闭环

### 阶段 4(图片体系,2-3 周)

26. `image_grid`(d-image-grid 网格)
27. `image_carousel`(d-image-grid mode=carousel)
28. `lightbox`(画廊跨节点联动)
29. SpoilerImage 揭示状态

`image_grid` 和 `image_carousel` 没单独 NodeKind 因为算 image 复合形态,
fixture 目录复用 `image_grid/`。

---

## 3. 节点验收清单模板

> 每个节点的 PR 必须填这个清单,代码审查时按项打勾。
> 模板放 `packages/fluxdo_render/docs/node_pr_template.md`,新建 PR 时
> 复制到 PR 描述。

```markdown
# 节点 PR 验收清单

## 基本信息

- 节点类型:`<NodeKind 值,如 paragraph>`
- 阶段:`<1/2/3/4>`
- 优先级:`<F × (6 - C) 数字,从 node_priority.md 取>`
- 对应 legacy 代码:`<旧路径 + 行号,如 lib/widgets/.../builders/paragraph_builder.dart:42>`

## 5.1 实现完整性

- [ ] Node 定义在 `lib/src/node/<node>.dart`,sealed class 派生
- [ ] NodeFactory 中注册 `build(node, context) → Widget`
- [ ] 如果是行内节点,InlineFlattener 中实现 `flatten(node, style) → InlineSpan`
- [ ] 列出 legacy 实现的所有功能点,逐项对应到本次实现:
  - 功能点 1 → 代码位置
  - 功能点 2 → 代码位置
  - ...

## 5.2 测试覆盖

- [ ] 至少 5 个 fixture(简单 / 嵌套 / 边界 / 异常 HTML / 极长)放
      `test/fixtures/<node>/`
- [ ] 配对 .yaml 元数据(source/fetched_at/primary_node/sha256)
- [ ] Golden 测试通过(`fixture × (legacy | new)` 像素差 < 阈值)
- [ ] 单元测试覆盖 parser 边界(空字符串、缺属性、嵌套循环、超深递归)

## 5.3 交互对齐(与 legacy 一致)

- [ ] 点击行为(链接跳转 / 图片打开 / mention 打开用户卡等)
- [ ] 长按行为(图片引用 / 链接复制等)
- [ ] 选区行为(可选 / 不可选,与 legacy 一致)
- [ ] 键盘行为(如适用)

## 5.4 性能基线

- [ ] 同 fixture 上,新实现 build 时间不超过 legacy 1.1x
- [ ] 长帖虚拟化场景下,chunk 滚入时 vsync overhead 不退化
- [ ] 节点首次 mount 时无 100ms+ 同步阻塞
- [ ] benchmark 数据贴 PR 描述

## 5.5 灰度接入

- [ ] `NodeKind` 枚举已有对应项(阶段 0.7 一次定完,通常不需要新增)
- [ ] 设置页"开发者选项 → 渲染引擎"可见
- [ ] 默认 `legacy`,开关切 `new` 可工作
- [ ] 三态对照模式(legacy/new/both)可工作

## 5.6 文档

- [ ] 节点 .dart 文件头部 dartdoc 注释,说明对应 HTML 模式
- [ ] 复杂节点(C ≥ 4)配 `docs/nodes/<node>.md`,说明设计取舍
- [ ] 验收等级标注:1:1 / 近似 / 重做 / 缺失(在 docs/render_refactor_plan.md
      对应阶段的表里更新)

## 风险与回滚

- 已知风险:`<列出已知 corner case 或未覆盖的子能力>`
- 回滚方式:`<通常是把 NodeKind 默认值改回 legacy>`
```

---

## 4. 节点之间依赖

| 节点 | 依赖 | 说明 |
|---|---|---|
| `link` | 无 | |
| `mention` | `link` (mention 本质是带特殊 class 的 a) | |
| `emoji` | 无 | |
| `paragraph` | `text/em/strong/link/inline_code/emoji/mention/image/br` | 行内子节点合集 |
| `list` | `paragraph`(li 内部也有段落) | |
| `quote_card` | 整个 Node tree 递归 | |
| `details` | 同上 | |
| `spoiler` | 同上 | |
| `callout` | `blockquote` 路由 | |
| `image_grid` | `image` + gallery | |
| `lightbox` | `image_grid` + gallery | |

**所以阶段 1 不能跳过 `image`**(否则 paragraph 内的图无法渲染),
**阶段 4 之前 lightbox/grid 必须先有 image 占位**。

---

## 5. 时间预估对齐主计划

| 阶段 | 节点数 | 工时 | 累计 |
|---|---|---|---|
| 阶段 1 | 10 | 2-3 周(每个节点 1-2 天) | 4-6 周(含 0.1-0.9) |
| 阶段 2 | 8 | 4-6 周(部分节点 1 周) | 8-12 周 |
| 阶段 3 | 7 | 3-4 周 | 11-16 周 |
| 阶段 4 | 4 | 2-3 周 | 13-19 周 |

与主计划 `docs/render_refactor_plan.md` 一致。

---

## 6. 关键决策点

- **rich_text 行内合并策略**(阶段 1):InlineFlattener 默认拍平所有
  text + em + strong 为单个 RichText / TextSpan,但 mention / image
  作为 InlineCustomWidget。这个边界要明确,放进 §5 验收清单的 5.3。

- **link 与 mention 的关系**(阶段 1):mention 是带 `class="mention"`
  的 a 标签。是 link 实现 + class 路由,还是 mention 独立 Node?决策:
  **独立 MentionRun InlineNode**(因为要带 statusEmojiUrl),link 路由
  时识别 mention class 转 MentionRun。

- **callout 路由触发点**(阶段 2):blockquote 内容首行是 `[!type]`
  → 转 CalloutNode。决策:在 parser → Node 阶段做(不在 widget 阶段),
  避免 blockquote 和 callout 视觉跨节点 fallback 问题。
