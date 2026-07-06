// 全局环境垫片：必须是 entry 的第一个 import（esbuild 按 ESM DFS 序执行）。
//
// 1. window 别名 —— discourse 源码里有 guard 式引用（setup.js 的
//    window.console、guid.js 的 window.performance、footnotes.js 的
//    window.markdownitFootnote），QuickJS/JSC 裸环境没有 window。
// 2. moment 全局 —— discourse-local-dates 的 markdown feature 在模块顶层
//    就调 `moment.tz.link(...)`（裸全局引用），必须在它 eval 前挂好。
//    用 10-year-range 数据版而不是主入口的全量 tz 数据，省 ~180KB。
import moment from "moment-timezone/builds/moment-timezone-with-data-10-year-range.js";

if (typeof globalThis.window === "undefined") {
  globalThis.window = globalThis;
}

globalThis.moment = moment;
