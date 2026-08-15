/// 共享选区作用域注册表 —— 让同一逻辑单元(如一个长帖切成的多个 chunk,
/// 各自一个 FluxdoRender)**共享一个 [SelectionController]**,从而支持跨
/// FluxdoRender(跨 chunk)的连续选区。
///
/// 自研选区命中走「全局坐标 + registry」(与 widget 树解耦),所以只要多个
/// FluxdoRender 共享同一 registry/controller,起选那个的手势识别器跟踪手指
/// 跨 chunk 时,positionAt 就能命中其他 chunk 的块 → 选区自然跨 chunk。
///
/// 生命周期:按 scopeId 引用计数。FluxdoRender initState 时 [retain],dispose
/// 时 [release];计数归 0 才 dispose controller。这样主项目只需给同 post 的各
/// chunk 传同一个 scopeId(如 post.id),无需自己持有/销毁 controller。
library;

import 'selection_registry.dart';

class _ScopeEntry {
  _ScopeEntry(this.controller);
  final SelectionController controller;
  int refCount = 0;
}

class SelectionScopeRegistry {
  SelectionScopeRegistry._();

  static final Map<Object, _ScopeEntry> _scopes = {};

  /// 取(或建)scopeId 对应的共享 controller,引用计数 +1。
  static SelectionController retain(Object scopeId) {
    final entry = _scopes.putIfAbsent(
      scopeId,
      () => _ScopeEntry(SelectionController(SelectionRegistry())),
    );
    entry.refCount++;
    return entry.controller;
  }

  /// 释放 scopeId 的一次引用;计数归 0 时 dispose controller 并移除。
  static void release(Object scopeId) {
    final entry = _scopes[scopeId];
    if (entry == null) return;
    if (--entry.refCount <= 0) {
      entry.controller.dispose();
      _scopes.remove(scopeId);
    }
  }
}
