# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""外流增强算子回归台架:锐化/缩放/直方图拉伸后的可见性 + 可解性。

背景(2026-08 外流放大案):真实用户截图(平坦浅蓝底 B 通道顶格)
上印记点阵肉眼可见——实测点位偏移集中在 R 通道、幅度 ±3~7/255、
双极性,而画笔契约是仅 B 通道 ±1/255。理论归因:非线性增强(锐化
过冲、局部对比/直方图拉伸)对「平坦区里的周期性微结构」响应最强,
放大幅度并把能量泄漏到其他通道。

本台架把常见增强算子作用在带印记的平坦帧上,量测:
- 可见性:与「无印记背景走同一增强」的差分(扣逐通道全局均值——
  消饱和笔的均匀缩放无空间对比,不算可见),P99 幅度 + RMS;
- 可解性:extract() 能否 verified 还原 uid(含 0.83 缩放场景)。

已定案结论(2026-08,勿走回头路):
- 点缘半密度打散方案已实测否决:δ=1 下半密度环是 1px 棋盘 = 全图
  最高频结构,USM r2 p300 过冲 max 0.8→3.2,反向放大 4 倍;
- 幅度层面,直方图拉伸类(CLAHE)把任何 δ=1 图案拉到满对比
  (P99 100+)——这是幅度语义的固有边界;对策分两路:可解性由
  extract 的饱和自适应限幅(SAT_RATIO)覆盖(信号被一起放大,
  verified 反而更稳);观感由 v2 形态去周期化覆盖(残迹自相关峰
  0.91→0.40,放大后呈碎粒噪声而非等距点阵墙);
- 线性算子(纯缩放/模糊/普通 USM)不放大 δ=1 信号(P99 ≤1),与
  理论一致;能复现截图形态(跨通道+数倍放大)的是拉伸类算子。

用法:
    uv run enhance_bench.py            # 全量对比表
    uv run enhance_bench.py --fast     # 跳过可解性(只看可见性)
"""

from __future__ import annotations

import argparse
import sys

import numpy as np
from PIL import Image, ImageFilter

import extract as ex

UID = 998244353
DPR = 2.75           # 放大案机型档位(1080 宽 x dpr2.75 类)
W_LOG, H_LOG = 392, 872   # 逻辑尺寸 → 物理 1078x2398
BG = (232, 248, 255)      # 放大案实测底色:B 通道顶格的浅蓝


def flat_bg() -> np.ndarray:
    h, w = round(H_LOG * DPR), round(W_LOG * DPR)
    bg = np.empty((h, w, 3))
    bg[:] = BG
    return bg


# ---- 增强算子(输入/输出 uint8 RGB Image)----

def op_identity(img: Image.Image) -> Image.Image:
    return img


def op_usm(percent: int, radius: float = 2.0):
    def f(img: Image.Image) -> Image.Image:
        return img.filter(
            ImageFilter.UnsharpMask(radius=radius, percent=percent, threshold=0)
        )
    f.__name__ = f"USM r{radius} p{percent}"
    return f


def op_downscale_sharpen(img: Image.Image) -> Image.Image:
    """放大案实测链路形态:~0.83 等比缩放(1080→900 类)+ 锐化。"""
    w, h = img.size
    small = img.resize((round(w * 0.8333), round(h * 0.8333)), Image.BICUBIC)
    return small.filter(ImageFilter.UnsharpMask(radius=1.5, percent=200, threshold=0))


def op_local_contrast(img: Image.Image) -> Image.Image:
    """局部对比度增强(大半径低幅度 USM 的标准实现)。"""
    return img.filter(ImageFilter.UnsharpMask(radius=8, percent=80, threshold=0))


def op_clahe(img: Image.Image, tile: int = 64, clip_limit: float = 4.0) -> Image.Image:
    """分块限幅直方图均衡——「AI 画质/清晰度增强」的形态模型,
    对 δ=1 微结构的放大上不封顶(定案结论第 2 条的复现件)。"""
    a = np.asarray(img).astype(np.float64)
    out = a.copy()
    h, w, _ = a.shape
    for c in range(3):
        ch = a[..., c]
        for y in range(0, h, tile):
            for x in range(0, w, tile):
                blk = ch[y : y + tile, x : x + tile]
                hist, edges = np.histogram(blk, bins=256, range=(0, 256))
                hist = np.minimum(hist, clip_limit * blk.size / 256)
                cdf = hist.cumsum()
                if cdf[-1] == 0:
                    continue
                out[y : y + tile, x : x + tile, c] = np.interp(
                    blk, edges[:-1], cdf / cdf[-1] * 255
                )
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


OPS = [
    ("无处理", op_identity, DPR),
    ("USM r2 p150", op_usm(150), DPR),
    ("USM r2 p300", op_usm(300), DPR),
    ("局部对比 r8 p80", op_local_contrast, DPR),
    ("缩放0.83+USM p200", op_downscale_sharpen, DPR * 0.8333),
    ("CLAHE clip4(拉伸类)", op_clahe, DPR),
]


def visibility(stamped: np.ndarray, clean: np.ndarray, op) -> tuple[float, float]:
    a = np.asarray(
        op(Image.fromarray(np.clip(stamped, 0, 255).astype(np.uint8)))
    ).astype(np.float64)
    b = np.asarray(
        op(Image.fromarray(np.clip(clean, 0, 255).astype(np.uint8)))
    ).astype(np.float64)
    d = (a - b)[16:-16, 16:-16]
    d = d - d.mean(axis=(0, 1))
    return float(np.percentile(np.abs(d), 99)), float(np.sqrt((d * d).mean()))


def salience(stamped: np.ndarray, clean: np.ndarray, op) -> tuple[float, float]:
    """形态显著性:增强后印记残迹的归一化自相关最大值(0~1,排除
    原点邻域),返回 (近域≤250px, 全位移)。

    量化「点阵感」——人眼把散点识别为图案靠的是空间重复性,对应
    残迹自相关在非零位移处的峰值(周期图案→接近 1,白噪声→接近 0)。
    近域是感知主口径:人眼比对重复结构的有效距离有限,v2 把最近
    重复从 84 逻辑 px(231 物理 px)推到 168 逻辑 px(462 物理 px)
    且近域内块间互不相同;全位移作参考(v2 在 168 周期处仍有峰,
    属协议保留的平铺周期,离线解码靠它)。不预设周期位置,全位移
    搜索:任何形态的重复结构(平移/超周期/斜格)都会被抓到。
    与 visibility 正交:幅度相同的残迹,该值越高越像水印图案,
    越低越像传感器噪点。"""
    a = np.asarray(
        op(Image.fromarray(np.clip(stamped, 0, 255).astype(np.uint8)))
    ).astype(np.float64)
    b = np.asarray(
        op(Image.fromarray(np.clip(clean, 0, 255).astype(np.uint8)))
    ).astype(np.float64)
    d = (a - b)[16:-16, 16:-16].mean(axis=2)
    d -= d.mean()
    e = float((d * d).sum())
    if e < 1e-9:
        return 0.0, 0.0
    f = np.fft.rfft2(d)
    ac = np.fft.irfft2(f * np.conj(f), s=d.shape) / e
    h, w = d.shape
    yy = np.minimum(np.arange(h), h - np.arange(h))[:, None]
    xx = np.minimum(np.arange(w), w - np.arange(w))[None, :]
    r = np.hypot(yy, xx)
    return (
        float(ac[(r >= 8) & (r <= 250)].max()),
        float(ac[r >= 8].max()),
    )


def decodability(stamped: np.ndarray, op, dpr_out: float) -> str:
    img = op(Image.fromarray(np.clip(stamped, 0, 255).astype(np.uint8)))
    hits = ex.extract(img, [round(dpr_out, 4)])
    got = next((h for h in hits if h.verified and h.uid == UID), None)
    if got:
        return f"verified margin={got.margin:.2f}"
    got = next((h for h in hits if h.uid == UID), None)
    return f"未复核 margin={got.margin:.2f}" if got else "未提取到"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fast", action="store_true", help="跳过可解性检查")
    args = ap.parse_args()

    clean = flat_bg()
    pens = [
        ("v1 单极性(≤0.2.26)", ex.stamp(clean, UID, DPR, unipolar=True, v2=False)),
        ("v2 单极性(现行)", ex.stamp(clean, UID, DPR, unipolar=True)),
        ("v2 双极性(原生后端)", ex.stamp(clean, UID, DPR, unipolar=False)),
    ]

    print(f"底色 {BG} dpr={DPR} 帧 {clean.shape[1]}x{clean.shape[0]}\n")
    header = f"{'算子':<22}{'画笔':<24}{'P99幅度':>8}{'RMS':>8}{'形态近域':>8}{'全域':>6}"
    if not args.fast:
        header += "  可解性"
    print(header)
    for op_name, op, dpr_out in OPS:
        for pen_name, stamped in pens:
            p99, rms = visibility(stamped, clean, op)
            near, full = salience(stamped, clean, op)
            line = f"{op_name:<22}{pen_name:<24}{p99:>8.2f}{rms:>8.3f}{near:>8.2f}{full:>6.2f}"
            if not args.fast:
                line += f"  {decodability(stamped, op, dpr_out)}"
            print(line)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
