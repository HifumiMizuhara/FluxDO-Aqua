/// 给整棵 BlockNode 树按**文档序**(深度优先)编号。
///
/// 选区要稳定的「视觉/文档序」,**不能靠 build 时的几何或注册顺序**(虚拟化/
/// 延迟 build / 表格行虚拟化下都不可靠)。改在 parse 后一次性按文档序编号,
/// 存进 identity map:每个会产出可选 RenderParagraph 的单元
/// (ParagraphNode / HeadingNode / CodeBlockNode / ListItem / 容器内子块 /
/// 表格 cell 子块)都能据此查到稳定序号(见 SelectableBlockId.docOrder)。
///
/// 非可选节点也编号(序号上留无害空洞),只保证序号在文档序上单调即可。
/// 这套对表格、行虚拟化、details/spoiler 折叠等延迟 build 完全免疫
/// (序号来自 parse 树,与 build 时机无关)。
library;

import '../node/node.dart';

/// 返回 `节点/ListItem → docOrder` 的 **identity map**(按对象身份,非 ==)。
/// BlockNode/ListItem 均重写了值相等 == —— 用普通 Map 时,重复内容节点
/// (如书单帖里两条一模一样的 li)会碰撞成同一条目、共享 docOrder,选区
/// 范围判定随之跳项。必须 Map.identity()。
Map<Object, int> assignDocumentOrder(List<BlockNode> nodes) {
  final map = Map<Object, int>.identity();
  var n = 0;

  void visit(BlockNode node) {
    map[node] = n++;
    switch (node) {
      case ListNode():
        for (final item in node.items) {
          map[item] = n++;
          final children = item.children;
          if (children != null) {
            for (final sub in children) {
              visit(sub);
            }
          }
          final blocks = item.blocks;
          if (blocks != null) {
            for (final b in blocks) {
              visit(b);
            }
          }
        }
      case BlockquoteNode():
        for (final c in node.children) {
          visit(c);
        }
      case QuoteCardNode():
        for (final c in node.children) {
          visit(c);
        }
      case SpoilerBlockNode():
        for (final c in node.children) {
          visit(c);
        }
      case CalloutNode():
        for (final c in node.children) {
          visit(c);
        }
      case DetailsNode():
        for (final c in node.children) {
          visit(c);
        }
      case PolicyNode():
        for (final c in node.children) {
          visit(c);
        }
      case TableNode():
        for (final row in node.rows) {
          for (final cell in row) {
            for (final c in cell.children) {
              visit(c);
            }
          }
        }
      case DefinitionListNode():
        for (final item in node.items) {
          map[item] = n++;
          for (final dd in item.definitions) {
            for (final c in dd) {
              visit(c);
            }
          }
        }
      default:
        break;
    }
  }

  for (final node in nodes) {
    visit(node);
  }
  return map;
}
