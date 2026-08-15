# fluxdo_render_gallery

节点画廊 demo app — 浏览所有 fixture + 实时查看 parser/render 输出 +
调试 cooked HTML / Node tree。

## 跑

```sh
cd packages/fluxdo_render/example
flutter pub get
flutter run -d macos
```

(其他 desktop / mobile 平台需要 `flutter create -t app --platforms <name>`
补 platform 目录,目前 example 默认只生成了 macOS。)

## 功能

- 左侧 nav 按节点类型(paragraph / heading / ...)分组,列所有 fixture
- 右侧:
  - **Rendered** — 用 FluxdoRender 实时渲染(默认展开)
  - **Cooked HTML source** — fixture 原始 cooked HTML(可选展开)
  - **Node tree** — parser 解析后的 BlockNode + InlineNode 树状结构(可选展开)
  - **Source** — fixture 元数据中的 source URL(可选展开)
- Chips:节点类型 + parse 耗时(µs) + block node 数 + 是否 edge case
- 顶栏切换深色 / 浅色主题

## 新增 fixture 后

1. 在 `test/fixtures/<node_type>/` 加 `.html` + `.yaml`
2. 在子包根目录跑:
   ```sh
   dart run test/fixtures/scripts/gen_fixtures_index.dart
   ```
3. 这会重新生成 `lib/src/dev/fixtures_index.g.dart`(进仓)
4. 重启 example app 即可看到新 fixture

## Legacy 对照

本 app **不包含 legacy(fwfh)对照渲染** — 子包不依赖主项目的
DiscourseHtmlContent / fwfh 体系。
要做新旧对照,在主项目内开发者模式打开"渲染引擎(调试)",把节点切到
`both` 模式,在详情页看叠加效果。
