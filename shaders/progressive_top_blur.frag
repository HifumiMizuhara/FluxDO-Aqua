#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// ImageFilter.shader 约定:第一个 vec2 uniform 由引擎填入绑定纹理
// 尺寸(物理像素);第一个 sampler 由引擎绑定 backdrop 输入。

uniform vec2 u_size;
// 滤镜区域高度(物理像素)。⚠️ 不能用 u_size 做纵向归一:u_size 是
// backdrop 纹理尺寸,Impeller 下可能是**全屏**而非裁剪区 —— 那样
// uv.y 只走到 0~0.15,t 恒近 1,整块满糊满罩、ClipRect 底边硬切一条
// 分层线,渐变根本没展开。
uniform float u_region_h;
// 顶部最大模糊 sigma(物理像素,Dart 侧 = 逻辑值 × devicePixelRatio)
uniform float u_max_sigma;
// 消散曲线指数:sigma = max_sigma * pow(1 - y/h, curve),越大越集中在顶部
uniform float u_curve;
// 色罩:rgb = surface 色,a = 顶部最大 alpha。
// 色罩在 shader 内与模糊一起做 —— Dart 侧折线 LinearGradient 的
// stop 转折点是可见"折痕"(马赫带),smoothstep 全程 C1 连续无折。
uniform vec4 u_tint;

uniform sampler2D u_texture;

out vec4 frag_color;

// vogel 盘采样:黄金角螺旋均匀铺盘,伪影远小于环状/网格 tap
const float TAPS = 36.0;
const float GOLDEN_ANGLE = 2.39996323;
// 色罩平台区:顶部 (1-TINT_KNEE) 比例保持满 alpha,其下 smoothstep 滑到 0
const float TINT_KNEE = 0.75;

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / u_size;
  // 视觉纵向位置 t:1=区域顶部,0=区域底部(按滤镜区域高度归一,
  // 与 backdrop 纹理尺寸无关)—— 模糊与色罩都随之连续变化
  float t = clamp(1.0 - frag.y / u_region_h, 0.0, 1.0);
  float sigma = u_max_sigma * pow(t, u_curve);

  vec2 suv = uv;
  // GLES 后端纹理 y 轴反转(仅影响采样坐标,不影响视觉位置 t)
#ifdef IMPELLER_TARGET_OPENGLES
  suv.y = 1.0 - suv.y;
#endif

  vec4 color;
  if (sigma < 0.3) {
    color = texture(u_texture, suv);
  } else {
    float radius = sigma * 2.5;
    vec2 texel = vec2(radius) / u_size;
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (float i = 0.0; i < TAPS; i++) {
      float r = sqrt((i + 0.5) / TAPS);
      float a = i * GOLDEN_ANGLE;
      vec2 p = vec2(cos(a), sin(a)) * r;
      float d = r * radius;
      float w = exp(-(d * d) / (2.0 * sigma * sigma));
      acc += texture(u_texture, suv + p * texel) * w;
      wsum += w;
    }
    color = acc / wsum;
  }

  // 色罩:两端导数为零的 S 曲线,顶部平台托状态栏/标题文字对比
  float tintA = u_tint.a * smoothstep(0.0, TINT_KNEE, t);
  frag_color = mix(color, vec4(u_tint.rgb, 1.0), tintA);
}
