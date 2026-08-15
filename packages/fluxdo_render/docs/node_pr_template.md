<!-- 节点 PR 验收清单 — 新建节点 PR 时复制到 PR 描述 -->

# 节点 PR 验收清单

## 基本信息

- **节点类型**: `<NodeKind 值,如 paragraph>`
- **阶段**: `<1/2/3/4>`
- **优先级**: `<F × (6 - C) 数字,从 docs/node_priority.md 取>`
- **对应 legacy 代码**: `<旧路径 + 行号,如 lib/widgets/.../builders/paragraph_builder.dart:42>`
- **验收等级**: `<1:1 / 近似 / 重做 / 缺失>`

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
- [ ] 验收等级标注:1:1 / 近似 / 重做 / 缺失(在主仓
      `docs/render_refactor_plan.md` 对应阶段的表里更新)

## 风险与回滚

- 已知风险:`<列出已知 corner case 或未覆盖的子能力>`
- 回滚方式:`<通常是把 NodeKind 默认值改回 legacy>`
