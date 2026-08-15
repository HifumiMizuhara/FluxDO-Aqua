#include <flutter/runtime_effect.glsl>

// Spoiler 粒子尘埃场 —— 参考 Telegram 新版做法:粒子完全在 shader 里按
// hash(cell, time) 程序化生成,CPU 每帧只更新 time uniform。
//
// 性能约束:Impeller 没有 raster cache,可见区域每帧都会重新执行本
// shader,大块 spoiler 在 retina 上是百万级像素 —— 每像素成本必须压到
// 几十 ALU ops。因此:
// - 每层只采样**自身 cell**(粒子位置约束在 cell 内含漂移余量,不会越
//   界影响邻 cell 像素),每像素每层仅 1 次 hash;
// - 两层半格错位叠加,掩盖单层网格排布感;
// - 背景色并进 shader 输出不透明色,外层无需先画背景再混合半透明层。
//
// 视觉对齐旧 CPU 粒子系统:细小圆点(直径 ~1.4 逻辑px)、3 档透明度、
// 缓慢漂移 + 生灭闪烁。

uniform float u_time;  // 动画时间(秒)
uniform float u_seed;  // 每实例随机相位,避免多个 spoiler 同步闪烁
uniform vec4 u_color;  // 粒子基色
uniform vec4 u_bg;     // 不透明遮罩背景色

out vec4 fragColor;

// 单层粒子网格尺寸(逻辑 px);两层叠加后密度 ≈ 2/(CELL²)
const float CELL = 5.0;
// 粒子半径(逻辑 px)
const float R = 0.7;

// hash(Dave Hoskins 风格,无 sin,移动 GPU 上精度稳定)
vec2 hash22(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.xx + p3.yz) * p3.zy);
}

// 单层尘埃:每 cell 一个粒子,只采样自身 cell(1 次 hash)。
float dustLayer(vec2 p, float seed) {
  vec2 cell = floor(p / CELL);
  vec2 local = p - (cell + 0.5) * CELL; // 相对 cell 中心
  vec2 rnd = hash22(cell + seed);
  // 派生第二组随机数(免二次 hash)
  vec2 rnd2 = fract(rnd * 41.17 + rnd.yx * 7.73);

  // 生灭闪烁:三角包络,周期 0.8~1.7s,相位随机 → 各粒子错开
  float ft = u_time / (0.8 + 0.9 * rnd.x) + rnd.y * 23.7;
  float cycle = floor(ft);
  float t = ft - cycle;
  float env = min(t, 1.0 - t) * 2.0;
  env *= env;

  // 每个周期用黄金分割低差异序列换出生点/漂移方向/透明度档位 ——
  // 免二次 hash,且序列不循环,粒子不会在同一位置重复同一动作
  // (否则每 ~1s 肉眼可见"重播")。
  vec2 rnd3 = fract(rnd2 + cycle * vec2(0.61803398875, 0.38196601125));
  vec2 dir = fract(rnd + cycle * vec2(0.75487766625, 0.56984029100)) - 0.5;

  // 出生点约束在 cell 内(预留 半径 + AA + 漂移 余量)+ 生命内慢漂移
  vec2 off = (rnd3 - 0.5) * (CELL - 2.0 * (R + 0.3 + 0.6));
  off += dir * 2.0 * (t - 0.5);

  float d = length(local - off);
  // 3 档透明度 0.3 / 0.65 / 1.0(对齐旧 CPU 粒子的 alphaType 分档)
  float tier = 0.3 + 0.35 * floor(fract(rnd2.y + cycle * 0.61803) * 2.999);
  return (1.0 - smoothstep(R - 0.3, R + 0.3, d)) * env * tier;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  // 两层半格错位、独立种子 → 掩盖网格排布感
  float a = dustLayer(p, u_seed);
  a = max(a, dustLayer(p + CELL * 0.5, u_seed + 77.7));
  fragColor = vec4(mix(u_bg.rgb, u_color.rgb, min(a, 1.0) * u_color.a), 1.0);
}
