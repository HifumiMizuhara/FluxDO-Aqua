# 渲染引擎 fixture 库

这里收集真实 Discourse cooked HTML,用于:
- Golden 测试(新旧引擎渲染像素对比)
- 单元测试(parser/flattener 边界用例)
- benchmark(性能基线对比)
- 文档(说明每种节点的 HTML 形态)

## 目录组织

按主节点类型分目录,每个 fixture 由**一对** `.html` + `.yaml` 文件组成:

```
paragraph/
  simple_with_em.html       ← cooked HTML 片段(只是 post 内容,不含外壳)
  simple_with_em.yaml       ← 元数据(见下方 schema)
```

跨节点的奇葩 case(深嵌套、超长帖、伪装格式等)放 `_edge_cases/`。

## 元数据 schema

完整 schema 见 `_meta/fixture.schema.yaml`。关键字段:

```yaml
source: https://linux.do/t/topic/12345/3   # 必填,来源 post 永久链接
fetched_at: 2026-06-22                     # 必填,抓取日期
primary_node: paragraph                    # 必填,主节点类型(应与目录名一致)
also_contains: [em, link]                  # 可选,该 fixture 还含什么节点
edge_case: false                           # 可选,是否为边界 case
notes: |                                   # 可选,说明这个 fixture 测什么
  最简单的 <p> + <em> 组合,用于验证段落基础渲染。
sanitized: false                           # 可选,是否做了脱敏(替换用户名/链接等)
```

## 添加新 fixture

**方式 A:用采集脚本(推荐)**

从公开 Discourse 站点的 post 链接自动拉取 cooked:

```sh
dart run test/fixtures/scripts/fetch_fixture.dart \
  --url https://linux.do/t/topic/12345/3 \
  --out paragraph/my_case.html \
  --notes "测试包含 mention 的段落"
```

脚本会自动:
- 拉 `/posts/<post_id>.json` 拿到 cooked
- 推断 primary_node 类型并提示放进哪个目录
- 同时生成配对的 `.yaml`(填好 source / fetched_at / sha256)
- 检测是否有应当脱敏的 PII(邮箱/手机号/全大写用户名 等)

**方式 B:手动**

1. 把 cooked html(只是 post body 部分,**不要**外壳 `<html>/<body>`)
   存为 `.html`
2. 复制 `_meta/fixture.template.yaml` → 改名 + 填字段
3. 跑 `dart run test/fixtures/scripts/validate.dart` 确认通过 schema 校验

## 命名规范

文件名 snake_case,描述测试目标而不是描述内容:
- ✅ `simple_with_em.html`(说明:简单段落含 em)
- ✅ `nested_three_levels.html`(说明:嵌套三层)
- ✅ `empty_content.html`(说明:空内容边界)
- ❌ `discourse_post_123.html`(没意义,看不出测什么)
- ❌ `bug_repro.html`(没指明哪个 bug)

## 数量目标(阶段 0 完成时)

| 节点类型 | 最少 | 备注 |
|---|---|---|
| paragraph | 5 | 含 em/strong/code 等基础组合 |
| heading | 6 | h1-h6 各一 |
| list | 6 | ul/ol + 嵌套 + 长内容 |
| code_block | 5 | 各种语言 + 行号 + 极长内容 + mermaid |
| quote_card | 5 | 单层/双层嵌套/带图片/带 code |
| spoiler | 4 | 块级/行内/含图/嵌套 |
| onebox | 8 | user/github/video/social/tech/default 各种 |
| table | 5 | 小表/大表/含 inline 元素 |
| poll | 3 | 单选/多选/数字 |
| image_grid | 4 | grid/carousel/含 spoiler |
| 其他节点 | 各 2-3 | mention/emoji/math/iframe/lazy_video/footnote/local_date/callout/blockquote/chat_transcript/policy/inline_code/horizontal_rule/lightbox |
| `_edge_cases/` | 10+ | 深嵌套、超长、混合多节点、伪装格式、损坏 HTML 等 |
| **合计** | **~100** | 至少 100 个,目标 200+ |

## 注意事项

- **不要存包含 PII 的 fixture**(真实用户邮箱/手机号/身份证)
- **不要存 OP 没公开的内容**(私信、隐藏帖)
- cooked HTML 可能含图片 url,**图片本身不放进仓**(渲染时按 url 加载,
  离线测可以让 ImageProvider 返回占位图)
- fixture 的 `.html` 文件**不带 BOM、用 LF 换行**(.gitattributes 已配置)
