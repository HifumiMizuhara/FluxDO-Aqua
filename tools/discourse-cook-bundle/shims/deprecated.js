// discourse/lib/deprecated 的裸引擎 stub。
//
// 真文件依赖 @ember/debug + deprecation-workflow，cook 管线只在
// setup.js / pretty-text.js 里用 default 导出提示旧 API 用法。
// 预览 cook 全走新 API，静默即可。
export default function deprecated() {}

export function withSilencedDeprecations(_ids, callback) {
  return callback?.();
}
