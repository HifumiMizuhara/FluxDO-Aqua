/// 表格结构化编辑对话框:网格 TextField 直改 cell + 增删行列。
///
/// 表格岛的"直接修改"通道(岛内 WYSIWYG 光标前的务实解):双击表格 →
/// 本对话框(初值 = 各 cell 的 markdown 文本)→ 确认后重建 markdown
/// 表格文本,调用方经 cook 链路 replaceIsland。
/// 全 cell 纯文本口径(cell 内富格式如 **粗体** 以 markdown 源码形式
/// 呈现/编辑,cook 后仍还原富效果 —— 不丢格式)。
library;

import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart' show tableGridToMarkdown;

import '../../../utils/dialog_utils.dart';

/// 弹表格网格编辑器。返回重建的 markdown 表格文本;取消返回 null。
Future<String?> showTableGridEditor(
  BuildContext context, {
  required List<List<String>> initialCells,
  required bool hasHeader,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (ctx) => _TableGridEditorDialog(
      initialCells: initialCells,
      hasHeader: hasHeader,
    ),
  );
}

class _TableGridEditorDialog extends StatefulWidget {
  const _TableGridEditorDialog({
    required this.initialCells,
    required this.hasHeader,
  });

  final List<List<String>> initialCells;
  final bool hasHeader;

  @override
  State<_TableGridEditorDialog> createState() => _TableGridEditorDialogState();
}

class _TableGridEditorDialogState extends State<_TableGridEditorDialog> {
  late List<List<TextEditingController>> _grid;
  late bool _hasHeader;

  int get _rows => _grid.length;
  int get _cols => _grid.isEmpty ? 0 : _grid.first.length;

  @override
  void initState() {
    super.initState();
    _hasHeader = widget.hasHeader;
    final cells = widget.initialCells.isEmpty
        ? [
            ['', ''],
          ]
        : widget.initialCells;
    final cols =
        cells.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    _grid = [
      for (final row in cells)
        [
          for (var c = 0; c < cols; c++)
            TextEditingController(text: c < row.length ? row[c] : ''),
        ],
    ];
  }

  @override
  void dispose() {
    for (final row in _grid) {
      for (final c in row) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _addRow() => setState(() {
        _grid.add([for (var c = 0; c < _cols; c++) TextEditingController()]);
      });

  void _addCol() => setState(() {
        for (final row in _grid) {
          row.add(TextEditingController());
        }
      });

  void _removeRow(int r) {
    if (_rows <= 1) return;
    setState(() {
      for (final c in _grid[r]) {
        c.dispose();
      }
      _grid.removeAt(r);
    });
  }

  void _removeCol(int c) {
    if (_cols <= 1) return;
    setState(() {
      for (final row in _grid) {
        row[c].dispose();
        row.removeAt(c);
      }
    });
  }

  String _buildMarkdown() => tableGridToMarkdown(
        [
          for (final row in _grid) [for (final c in row) c.text],
        ],
        hasHeader: _hasHeader,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const cellWidth = 140.0;

    return AlertDialog(
      title: const Text('编辑表格'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 列删除按钮行
                      if (_cols > 1)
                        Row(children: [
                          for (var c = 0; c < _cols; c++)
                            SizedBox(
                              width: cellWidth + 8,
                              child: Center(
                                child: IconButton(
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 14,
                                  tooltip: '删除此列',
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: () => _removeCol(c),
                                ),
                              ),
                            ),
                          const SizedBox(width: 40),
                        ]),
                      for (var r = 0; r < _rows; r++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(children: [
                            for (var c = 0; c < _cols; c++)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: SizedBox(
                                  width: cellWidth,
                                  child: TextField(
                                    controller: _grid[r][c],
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _hasHeader && r == 0
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 8),
                                      border: const OutlineInputBorder(),
                                      filled: _hasHeader && r == 0,
                                      fillColor: scheme
                                          .surfaceContainerHighest
                                          .withValues(alpha: 0.4),
                                    ),
                                  ),
                                ),
                              ),
                            SizedBox(
                              width: 32,
                              child: _rows > 1
                                  ? IconButton(
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 14,
                                      tooltip: '删除此行',
                                      icon: const Icon(
                                          Icons.remove_circle_outline),
                                      onPressed: () => _removeRow(r),
                                    )
                                  : null,
                            ),
                          ]),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('加行'),
              ),
              TextButton.icon(
                onPressed: _addCol,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('加列'),
              ),
              const Spacer(),
              Checkbox(
                value: _hasHeader,
                onChanged: (v) => setState(() => _hasHeader = v ?? true),
              ),
              const Text('首行是表头', style: TextStyle(fontSize: 13)),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _buildMarkdown()),
          child: const Text('应用'),
        ),
      ],
    );
  }
}
