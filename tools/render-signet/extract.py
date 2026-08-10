# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""FluxDO 屏幕标识印记提取工具。

从外流的捕获帧(PNG/JPEG)中提取嵌入的用户 id。编码结构与几何常量
必须与 lib/widgets/render_signet/render_signet_codec.dart 保持一致:

- 块 7x7 单元格,单元格 12 逻辑 px,块周期 84 逻辑 px;
- 每格一个 5x6 点,bit=1 在左位 x∈[1,6)、bit=0 在右位 x∈[6,11),
  y 偏移逐格打散 dot_y(row,col)=(3r+5c)%7(消条纹感,见 dot_y);
- 渲染端 modulate+plus 双笔混合,只动 B 通道:
  B' = B·(255-DROP)/255 + DELTA,即 ΔB = DELTA·(1 - 2B/255)——
  黑底 +DELTA、白底 -DELTA,极性逐像素随底色翻转,同屏明暗混排
  仍全域不可见且信号完整;B≈128 中灰是天然死区(信号过零);
- 第 0 行为同步图案 1011001,余下 32 位 uid(大端) + 8 位 CRC-8
  (poly 0x07) + 2 位备用。

提取原理:
1. 匹配滤波通道:印记只动 B,在蓝-黄对立通道 O = B-(R+G)/2 上
   ΔO = ΔB = DELTA·w,其中 w = 1-2B/255 由局部底色决定。以轻度
   盒模糊的 B 通道估计每像素 w,取加权通道 O·w:印记信号恒为
   +DELTA·w²(极性归一),中灰死区权重自动趋零(匹配滤波最优
   加权)——取代旧的全局双极性扫描;
2. 快路径:按候选设备像素比表把捕获帧重采样回逻辑像素,取加权通道;
3. 切成 84x84 块,**每块独立**计算所有相位下每格"左位均值-右位
   均值"的符号,跨块投票——内容纹理只污染部分块且极性随机,投票
   摊平;印记在所有块极性恒定,票数逼近全票。(注意不能先折叠再
   差分:纹理边缘残差可超过信号幅度,会翻位);
4. 在票数场上找同步行精确匹配的相位,**软判决解码**:先按票数
   符号硬判,CRC 不过则按票数绝对值从弱到强穷举翻转至多
   SOFT_FLIP_MAX 位重试(只翻 payload/CRC/备用位)——重压缩下
   只有零星弱位翻转,软判决可救回。解码端额外校验 2 个备用定值位,
   与 CRC 合计 10 位判别;
5. **匹配滤波复核**:以解码位(±1 模板,含同步行)对全部 7056 个
   相位的票数打分。真印记只在唯一正确相位有能量,主峰对(屏蔽主峰
   邻域后的)次峰的超出比 ratio=(peak-med)/(second-med) 显著 >1;
   噪声候选的"峰"本来就是从相位分布尾部挑出来的,且软判决把模板
   拟合到了该相位(选择偏置),ratio 可虚高到 ~1.9 但 margin 恒为
   ~0。判定取双条件:ratio ≥ VERIFY_RATIO_STRONG(压缩后信号弱但
   相位集中)或 ratio ≥ VERIFY_RATIO_WEAK 且 margin ≥
   VERIFY_MIN_MARGIN(信号强则两者都硬)。实测真信号 q60 重压缩
   ratio 2.2、无损 margin ≥0.3,噪声无法同时伪造两者。
   (旧判据"奇偶半区一致数"已废弃:半区与总和强相关,噪声通过率
   ~14%,实测在真实捕获帧上产生过已复核的假阳性。)
6. **盲缩放搜索**(快路径无 verified 命中时):现实中捕获帧常被连续
   比例缩放(聊天软件压图、窗口缩放保存),档位表覆盖不住。印记
   几何自带同步信标——点 y 虽逐格打散,但每行的 7 个 dy 恰好遍历
   0~6(5 与 7 互素),行投影仍是周期 12·sy 的梳状信号(梯形轮廓,
   基频约为未打散的一半),加权通道上信号恒正,Goertzel 周期扫描
   即可盲测 sy;以 sx=sy 为种子做各向异性爬山细化(度量=同步行
   匹配相位的最弱格净票,无需已知 uid),最后在最优 (sx,sy) 处完整
   解码。若梳状检测无种子,退化为等比粗扫兜底。

用法:
    uv run extract.py screenshot.png
    uv run extract.py screenshot.jpg --dpr 3
    uv run extract.py --self-test          # 合成捕获帧端到端自检
"""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass

import numpy as np
from PIL import Image

# ---- 与 Dart 端严格一致的常量 ----
GRID = 7                       # 块行/列数(单元格)
CELL = 12                      # 单元格边长(逻辑 px)
PERIOD = GRID * CELL           # 块周期 84
SYNC_ROW = [1, 0, 1, 1, 0, 0, 1]
DELTA = 1                      # plus 笔 B 通道抬升量,自检模式使用
DROP = 2 * DELTA               # modulate 笔 B 通道乘性压降,自检模式使用
DESAT_ALPHA = 2 * DELTA        # 单极性方案消饱和笔 α(饱和避让加固,
                               # 与 Dart kSignetDesatAlpha 一致)
# 点位采样区域(逻辑 px,整数几何,采样区=完整点)
LEFT_COLS = (1, 6)             # bit=1 点位 x∈[1,6)
RIGHT_COLS = (6, 11)           # bit=0 点位 x∈[6,11)
DOT_H = 6                      # 点高


def dot_y(row: int, col: int) -> int:
    """v1 单元格内点 y 偏移,逐格打散(0~6)。若所有格同 y,整屏每 12
    逻辑 px 形成一条同符号"点带",人眼沿线积分使阈值降 2~4 倍,
    整屏"发脏"。与 Dart signetDotYOffset 严格一致。"""
    return (3 * row + 5 * col) % 7


# ---- v2 形态层(2026-08 外流放大案组合拳,与 Dart codec 严格一致) ----
#
# 编码结构(49 位/块、位置差分、δ 幅度)与 v1 完全相同,只把「像素
# 长相」去周期:相邻 SUPER x SUPER 个块为一组变体,点 y 偏移/位对
# x 滑移/payload 位翻转由密钥哈希决定——位值仍按 84 周期平铺,像素
# 图案周期变 168 且块间互不相同(残迹自相关峰 0.91 → 0.40)。
# 密钥是公开常量,目的是去周期,不是保密。

SUPER = 2                      # 超周期(块)
V2_PERIOD = PERIOD * SUPER     # v2 像素图案周期 168


def v2_hash(variant: int, row: int, col: int, salt: int) -> int:
    """与 Dart signetV2Hash 严格同式(xorshift 洗匀低位)。"""
    x = (
        variant * 2654435761 + row * 40503 + col * 10859 + salt * 97 + 0x5EED
    ) & 0xFFFFFFFF
    x ^= x >> 13
    x = (x * 2246822519) & 0xFFFFFFFF
    x ^= x >> 11
    return x


def _build_cells(v2: bool) -> list[tuple[int, bool, int, int]]:
    """格表 [(bit_idx, flip, y0, xl)]:一个折叠周期内的全部采样格。
    bit_idx∈[0,49) 指向编码位;flip=该格位值被扰码 XOR;y0/xl 为点
    竖直起点与左位 x 起点(左位 [xl,xl+5)、右位 [xl+5,xl+10))。
    v1:49 格,折叠 84;v2:196 格(4 变体),折叠 168。"""
    cells = []
    if not v2:
        for row in range(GRID):
            for col in range(GRID):
                cells.append((
                    row * GRID + col,
                    False,
                    row * CELL + dot_y(row, col),
                    col * CELL + LEFT_COLS[0],
                ))
        return cells
    for qy in range(SUPER):
        for qx in range(SUPER):
            variant = qy * SUPER + qx
            for row in range(GRID):
                for col in range(GRID):
                    flip = row > 0 and v2_hash(variant, row, col, 3) % 2 == 1
                    cells.append((
                        row * GRID + col,
                        flip,
                        qy * PERIOD + row * CELL + v2_hash(variant, row, col, 1) % 7,
                        qx * PERIOD + col * CELL + LEFT_COLS[0]
                        + v2_hash(variant, row, col, 2) % 2,
                    ))
    return cells


CELLS_V1 = _build_cells(False)
CELLS_V2 = _build_cells(True)


def _mode_geometry(v2: bool) -> tuple[list[tuple[int, bool, int, int]], int]:
    return (CELLS_V2, V2_PERIOD) if v2 else (CELLS_V1, PERIOD)


# 极性权重估计:B 通道盒模糊半径(逻辑 px)。核 13x13 覆盖整个单元
# 格,点自身 ΔB=±2 被稀释 ~30 倍,估出的 w 不受印记自污染;又足够
# 局部,能跟上明暗卡片边界
WEIGHT_BLUR = 6

# 候选设备像素比(含 Android 常见非整数档)。渲染端 ImageShader 把
# 图块精确缩放回 84 逻辑 px 平铺,物理周期恒为 84*dpr,故直接用名义值。
DPR_CANDIDATES = [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.625, 2.75, 3.0, 3.5, 4.0]

MAX_CANDIDATES = 4000      # 每个 dpr 最多复核的候选相位数
CLIP = 2.0                 # 单块差分限幅:压制 JPEG 块效应等重尾离群值
SAT_RATIO = 0.25           # 票场饱和率上限:|v|≥clip 的相位占比超过它
                           # 即判定为增强放大图,按实测幅度重设限幅。
                           # 正常帧真相位 |v|≈δ=1、其余≈0,该比率近 0;
                           # 直方图拉伸类增强把 δ 放大百倍后可达 0.8+
SOFT_FLIP_POOL = 8         # 软判决:参与穷举翻转的最弱位数量
SOFT_FLIP_MAX = 3          # 软判决:最多同时翻转的位数
VERIFY_RATIO_STRONG = 2.0  # 复核:凭相位集中度即可信的 ratio 下限
VERIFY_STRONG_MIN_MARGIN = 0.02  # 复核:STRONG 分支的 margin 地板。软判决
                           # 选择偏置可把纹理噪声的 ratio 推过 2(实测照片
                           # 纹理 2.07),但噪声 margin 恒 ~0.01,真信号即使
                           # q70 重压缩也 ≥0.15,一个很低的地板即可判别
VERIFY_RATIO_WEAK = 1.45   # 复核:与 margin 联合判定的 ratio 下限
VERIFY_MIN_MARGIN = 0.05   # 复核:联合判定的最弱格净票强度下限
PEAK_MASK_RADIUS = 3       # 求次峰时屏蔽主峰邻域的半径(环绕距离)

# 小截图共识复核:块数少时 ratio/margin 统计力不足(6 块的裁剪图
# 文字占比高,margin 常年 ~0),但真印记有个负对照拿不出的特征:
# 解码模板对**每一个块**的加权得分全部同号且显著为正(实测真信号
# 6/6 块 min≥0.12;无印记 UI/照片纹理最高 86% 同号、min 恒 <0)。
# 全块共识 + 最小得分下限 = 小样本下的独立判别维度。
CONSENSUS_MAX_BLOCKS = 16   # 仅小图保留逐块票(内存换判别力)
CONSENSUS_MIN_BLOCKS = 3    # 2 块共识判别力不足,3 块起步
CONSENSUS_MIN_SCORE = 0.1   # 每块模板得分下限(真信号实测 ≥0.12)

BLIND_SEED_MIN_Z = 4.0     # 盲搜:梳状周期峰的最低显著性
BLIND_METRIC_BLOCKS = 12   # 盲搜:爬山度量参与投票的块数上限
BLIND_HILL_STEPS = (0.02, 0.01, 0.005)  # 盲搜:爬山相对步长序列
BLIND_HILL_MAX_ITER = 8    # 盲搜:每档步长最多爬山轮数


def crc8(uid: int) -> int:
    """CRC-8 poly 0x07 init 0x00,对 uid 4 个大端字节。与 Dart wmCrc8 一致。"""
    crc = 0
    for i in (3, 2, 1, 0):
        crc ^= (uid >> (8 * i)) & 0xFF
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def decode_bits(bits: list[int]) -> int | None:
    """49 位 → uid;同步行、CRC 或备用位不符返回 None。比 Dart 端
    多校验 2 个备用定值位:App 只解自己画的图案无需,而解码端在
    海量相位 x 软翻转穷举下,每多 1 位判别假阳性减半。"""
    if bits[:GRID] != SYNC_ROW:
        return None
    if bits[GRID + 40] != 1 or bits[GRID + 41] != 0:  # 备用定值位 [1,0]
        return None
    uid = 0
    for b in bits[GRID : GRID + 32]:
        uid = (uid << 1) | b
    crc = 0
    for b in bits[GRID + 32 : GRID + 40]:
        crc = (crc << 1) | b
    return uid if crc == crc8(uid) else None


@dataclass
class Hit:
    uid: int
    dpr: float
    phase: tuple[int, int]
    margin: float   # 最弱格的归一化净票强度(0~1)
    n_blocks: int
    verified: bool  # 匹配滤波复核通过(ratio ≥ VERIFY_MIN_RATIO)
    ratio: float    # 匹配滤波主峰/次峰超出比,越大越可信
    dpr_y: float | None = None  # 盲搜命中时的垂直缩放(与 dpr 不同则为各向异性)
    v2: bool = False  # v2 形态(超周期去周期化)命中

    @property
    def scale_desc(self) -> str:
        if self.dpr_y is None or abs(self.dpr_y - self.dpr) < 1e-9:
            return f"{self.dpr}"
        return f"{self.dpr}x{self.dpr_y}"


def split_blocks(gray: np.ndarray, period: int = PERIOD) -> np.ndarray | None:
    """裁到 period 整数倍并切块 → (n, period, period)。"""
    h, w = gray.shape
    by, bx = h // period, w // period
    if by < 1 or bx < 1:
        return None
    g = gray[: by * period, : bx * period]
    return (
        g.reshape(by, period, bx, period)
        .transpose(0, 2, 1, 3)
        .reshape(by * bx, period, period)
    )


def diff_fields(
    tile: np.ndarray,
    cells: list[tuple[int, bool, int, int]] = CELLS_V1,
    with_var: bool = False,
):
    """折叠瓦片 → diff[cell, py, px]:每个采样格"左点均值-右点均值"
    在全部相位下的取值(2x2 平铺 + 积分图向量化),扰码格(flip)已
    翻回原位极性。折叠周期取 tile 边长(v1=84 / v2=168)。

    with_var=True 时同时返回 var[cell, py, px]:左右两采样区的像素
    方差之和,用作内容活跃度——文字/图片边缘穿过采样区时方差飙升,
    聚合端以 1/(var+ε) 加权,把票权集中到平坦干净的块。"""
    p = tile.shape[0]
    t = np.tile(tile, (2, 2))
    s = np.zeros((t.shape[0] + 1, t.shape[1] + 1))
    s[1:, 1:] = t.cumsum(0).cumsum(1)
    if with_var:
        t2 = t * t
        s2 = np.zeros((t2.shape[0] + 1, t2.shape[1] + 1))
        s2[1:, 1:] = t2.cumsum(0).cumsum(1)

    def rect(src, y0, y1, x0, x1):
        return (
            src[y1 : y1 + p, x1 : x1 + p]
            - src[y0 : y0 + p, x1 : x1 + p]
            - src[y1 : y1 + p, x0 : x0 + p]
            + src[y0 : y0 + p, x0 : x0 + p]
        )

    def region_stats(y0, y1, x0, x1):
        area = (y1 - y0) * (x1 - x0)
        mean = rect(s, y0, y1, x0, x1) / area
        if not with_var:
            return mean, None
        var = rect(s2, y0, y1, x0, x1) / area - mean * mean
        return mean, var

    dot_w = LEFT_COLS[1] - LEFT_COLS[0]
    diff = np.empty((len(cells), p, p))
    var_sum = np.empty((len(cells), p, p)) if with_var else None
    for i, (_, flip, dy, xl) in enumerate(cells):
        ml, vl = region_stats(dy, dy + DOT_H, xl, xl + dot_w)
        mr, vr = region_stats(dy, dy + DOT_H, xl + dot_w, xl + 2 * dot_w)
        d = ml - mr
        diff[i] = -d if flip else d
        if with_var:
            var_sum[i] = vl + vr
    return (diff, var_sum) if with_var else diff


def soft_decode(v: np.ndarray) -> tuple[int, np.ndarray] | None:
    """软判决:v 为 49 维票数向量。硬判不过 CRC 时,按 |票数| 从弱到
    强穷举翻转至多 SOFT_FLIP_MAX 位重试(候选相位同步行已精确匹配,
    只翻 payload/CRC/备用区)。返回 (uid, 最终位向量)。"""
    from itertools import combinations

    hard = v > 0
    uid = decode_bits([int(b) for b in hard])
    if uid is not None:
        return uid, hard
    payload = np.arange(GRID, GRID * GRID)
    weakest = payload[np.argsort(np.abs(v[payload]))][:SOFT_FLIP_POOL]
    for k in range(1, SOFT_FLIP_MAX + 1):
        for combo in combinations(weakest, k):
            bits = hard.copy()
            bits[list(combo)] ^= True
            uid = decode_bits([int(b) for b in bits])
            if uid is not None:
                return uid, bits
    return None


def _box_blur(a: np.ndarray, r: int) -> np.ndarray:
    """(2r+1)x(2r+1) 盒模糊,边界收缩(积分图实现)。"""
    h, w = a.shape
    s = np.zeros((h + 1, w + 1))
    s[1:, 1:] = a.cumsum(0).cumsum(1)
    y0 = np.clip(np.arange(h) - r, 0, h)
    y1 = np.clip(np.arange(h) + r + 1, 0, h)
    x0 = np.clip(np.arange(w) - r, 0, w)
    x1 = np.clip(np.arange(w) + r + 1, 0, w)
    area = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return (s[y1][:, x1] - s[y0][:, x1] - s[y1][:, x0] + s[y0][:, x0]) / area


def weighted_channel(rgb: np.ndarray, unipolar: bool = False) -> np.ndarray:
    """RGB(h,w,3) → 印记提取通道。

    O = B-(R+G)/2 承载印记(渲染端只动 B——单极性方案的消饱和笔
    全通道等比缩放,在 O 上近似抵消,不破坏该前提),亮度纹理
    (白字黑底等)在 O 上近似抵消。

    两代嵌入模型对应两种通道:
    - unipolar=True(消饱和+plus 内联方案,2026-07 起):ΔO 恒 +δ,
      直接返回 O,无需极性加权;
    - unipolar=False(modulate+plus 双极性,原生后端与历史版本):
      ΔO = ±δ 随底色翻转,以 w = 1-2·blur(B)/255 估计逐像素期望极性,
      返回 O·w:信号恒为 +δ·w²,中灰死区权重自动趋零。"""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    o = b - (r + g) / 2
    if unipolar:
        return o
    w = 1.0 - 2.0 * _box_blur(b, WEIGHT_BLUR) / 255.0
    return o * w


def try_extract(chan_logical: np.ndarray, dpr: float, v2: bool = False) -> Hit | None:
    cells, fold = _mode_geometry(v2)
    blocks = split_blocks(chan_logical, fold)
    if blocks is None:
        return None
    n = len(blocks)
    area_scale = (fold // PERIOD) ** 2
    # 共识复核仅 v1:它的 ratio/score 门槛按 7056 相位空间定标,v2
    # 相位空间 x4,噪声 ratio 尾部自然突破 WEAK 档(实测阴性对照
    # 1.52~1.63 误报);且 v2 单块即 4 个变体块的票量,3 块小裁剪
    # 主复核 STRONG 直接通过(实测 margin 0.21 / ratio 2.99),共识
    # 分支无存在必要
    consensus_max = CONSENSUS_MAX_BLOCKS if area_scale == 1 else 0
    # 格 → 编码位映射:v1 恒等(49 格 49 位);v2 每位 4 个变体格,
    # 票在位级聚合(加权和相加)后再判决
    bit_of = np.array([c[0] for c in cells])
    n_cells = len(cells)

    # 内容自适应加权投票:每格每块的票以 w=1/(var+ε) 加权(var=左右
    # 采样区像素方差和,文字/图片边缘穿过时飙升)。等权方案下小截图
    # (几块)只要某格恰好每块都压在文字上,margin 即归零、复核必挂;
    # 加权后干净块的票主导,margin 反映的是"最干净证据"而非"最差
    # 块拖后腿"。v 归一到 [-1,1] 量纲(权重和为分母),margin 直接
    # 可比;CLIP 限幅逻辑由权重取代——大方差票权重自然趋零。
    VAR_EPS = 1.0

    def accumulate(clip: float):
        """跨块加权投票 + 饱和统计 + 原始幅度采样(自适应重限幅用)。"""
        v_num = np.zeros((n_cells, fold, fold))
        v_den = np.zeros((n_cells, fold, fold))
        per_block = [] if n <= consensus_max else None
        sat = 0
        raw_abs = []
        for block in blocks:
            diff, var = diff_fields(block, cells, with_var=True)
            w = 1.0 / (var + VAR_EPS)
            clipped = np.clip(diff, -clip, clip)
            sat += int((np.abs(diff) >= clip).sum())
            raw_abs.append(np.abs(diff).ravel()[::197])  # 稀疏采样,估幅度足够
            v_num += clipped * w
            v_den += w
            if per_block is not None:
                per_block.append((clipped, w))
        sat_ratio = sat / (n * n_cells * fold * fold)
        # 位级聚合:同位的变体格加权票合并(v1 恒等映射,零开销)
        b_num = np.zeros((GRID * GRID, fold, fold))
        b_den = np.zeros((GRID * GRID, fold, fold))
        np.add.at(b_num, bit_of, v_num)
        np.add.at(b_den, bit_of, v_den)
        return b_num / b_den, per_block, sat_ratio, np.concatenate(raw_abs)

    v_all, per_block, sat_ratio, raw_abs = accumulate(CLIP)
    clip_eff = CLIP
    if sat_ratio > SAT_RATIO:
        # 增强放大图(2026-08 外流案):直方图拉伸把 δ=1 放大百倍,
        # 固定限幅让错误相位的部分重叠差分与真相位一样饱和到边界,
        # 相位判别力(matched-filter ratio)崩塌,饱和错误候选反以
        # margin=1 通过复核=假阳性。按实测幅度重设限幅恢复线性:
        # P99.5 覆盖被放大的信号本体,真相位满幅、部分重叠减半,
        # 判别力回归。正常帧 sat_ratio≈0 不走此路径,行为不变。
        clip_eff = max(CLIP, float(np.percentile(raw_abs, 99.5)))
        v_all, per_block, _, _ = accumulate(clip_eff)

    # 候选相位:同步行精确匹配,按最弱格净票强度排序。(不容错:
    # 软翻转已大幅放宽 CRC,同步行是剩余的强判别项,放宽会引入
    # 系统性色度纹理的假阳性)
    sync_sign = np.where(np.array(SYNC_ROW) == 1, 1, -1)
    cand = (np.sign(v_all[:GRID]) == sync_sign[:, None, None]).all(axis=0)
    margin_all = np.abs(v_all).min(axis=0) / clip_eff
    ys, xs = np.nonzero(cand)
    if len(ys) == 0:
        return None
    order = np.argsort(-margin_all[ys, xs])[:MAX_CANDIDATES]

    best: Hit | None = None
    for i in order:
        py, px = int(ys[i]), int(xs[i])
        result = soft_decode(v_all[:, py, px])
        if result is None:
            continue
        uid, decoded = result
        # 匹配滤波复核:解码位模板(±1,含同步行)对所有相位的票数
        # 打分。真印记只在唯一正确相位有能量,主峰远超次峰;噪声候选
        # 的"峰"本就来自相位分布尾部,主峰次峰同量级。
        template = np.where(decoded, 1.0, -1.0)
        score = np.tensordot(template, v_all, axes=1)  # (fold, fold)
        med = float(np.median(score))
        peak = float(score[py, px])
        # 屏蔽主峰邻域(环绕距离)后取次峰
        yy, xx = np.mgrid[0:fold, 0:fold]
        dy = np.minimum(np.abs(yy - py), fold - np.abs(yy - py))
        dx = np.minimum(np.abs(xx - px), fold - np.abs(xx - px))
        masked = np.where(
            (dy <= PEAK_MASK_RADIUS) & (dx <= PEAK_MASK_RADIUS), med, score
        )
        second = float(masked.max())
        ratio = (peak - med) / (second - med + 1e-12)
        margin = float(margin_all[py, px])
        # 块数下限 2:单块无跨块投票,任何纹理都可能自洽,不可复核;
        # ≥2 块起匹配滤波 ratio + margin 双条件已有判别力(加权投票
        # 后 margin 反映最干净证据,小截图不再被文字块拖垮)
        verified = n >= 2 and (
            (ratio >= VERIFY_RATIO_STRONG and margin >= VERIFY_STRONG_MIN_MARGIN)
            or (ratio >= VERIFY_RATIO_WEAK and margin >= VERIFY_MIN_MARGIN)
        )
        # 小截图共识复核:ratio/margin 不足时的独立判别维度(见常量注释)。
        # 须叠加 ratio 下限:真印记在错误缩放档下的混叠残留同样源自
        # 印记、块间一致,能骗过"逐块全同号"(实测 scale=4 档两例
        # verified 错 uid);但混叠候选的相位能量分散,ratio 恒低
        # (0.9~1.2 vs 真信号 1.75+),WEAK 档下限即可判别
        if not verified and per_block is not None and n >= CONSENSUS_MIN_BLOCKS:
            if ratio >= VERIFY_RATIO_WEAK:
                cell_template = template[bit_of]
                block_scores = [
                    float((cell_template * d[:, py, px] * w[:, py, px]).sum()
                          / w[:, py, px].sum())
                    for d, w in per_block
                ]
                verified = min(block_scores) >= CONSENSUS_MIN_SCORE
        hit = Hit(uid, dpr, (py, px), margin, n, verified, ratio, v2=v2)
        if best is None or (hit.verified, hit.ratio) > (best.verified, best.ratio):
            best = hit
    return best


def _resample(rgb: np.ndarray, sx: float, sy: float) -> np.ndarray:
    """按各向异性缩放把物理像素图重采样回逻辑像素(BOX=面积平均)。"""
    if sx == 1.0 and sy == 1.0:
        return rgb
    h, w = rgb.shape[:2]
    tw = max(1, round(w / sx))
    th = max(1, round(h / sy))
    return np.asarray(
        Image.fromarray(rgb.astype(np.uint8)).resize((tw, th), Image.BOX),
        dtype=np.float64,
    )


def _comb_period_seeds(chan: np.ndarray) -> list[float]:
    """盲测垂直缩放种子:每格点固定占 y∈[3,9),加权通道上印记信号
    恒正,整图行投影是周期 12·sy 的梳状信号。Goertzel 扫描 T∈[11,52],
    返回显著峰(z ≥ BLIND_SEED_MIN_Z)对应的 sy=T/12,按显著性降序。"""
    proj = chan.mean(axis=1)
    proj = proj - proj.mean()
    n = len(proj)
    if n < 60:
        return []
    ts = np.arange(11.0, 52.0, 0.02)
    t_idx = np.arange(n)
    amps = np.empty(len(ts))
    for i, period in enumerate(ts):
        w = 2 * np.pi / period
        c = float((proj * np.cos(w * t_idx)).sum())
        s = float((proj * np.sin(w * t_idx)).sum())
        amps[i] = math.hypot(c, s)
    med = np.median(amps)
    mad = np.median(np.abs(amps - med)) * 1.4826 + 1e-12
    z = (amps - med) / mad
    peaks = [
        (float(z[i]), float(ts[i]))
        for i in range(1, len(ts) - 1)
        if z[i] >= BLIND_SEED_MIN_Z and z[i] >= z[i - 1] and z[i] >= z[i + 1]
    ]
    peaks.sort(reverse=True)
    return [t / CELL for _, t in peaks[:3]]


def _blind_metric(rgb: np.ndarray, sx: float, sy: float, unipolar: bool, v2: bool) -> float:
    """爬山度量:重采样后,同步行匹配相位上的最弱格净票强度峰值。
    无需已知 uid;缩放正确时块间相位对齐,度量出现陡峰(实测正确
    点 ~0.18,偏 3% 即跌回 ~0.02 本底)。为控制成本只取前
    BLIND_METRIC_BLOCKS 块投票。"""
    cells, fold = _mode_geometry(v2)
    chan = weighted_channel(_resample(rgb, sx, sy), unipolar)
    blocks = split_blocks(chan, fold)
    if blocks is None or len(blocks) < 4:
        return -1.0
    blocks = blocks[:BLIND_METRIC_BLOCKS]
    v = np.zeros((len(cells), fold, fold))
    for block in blocks:
        v += np.clip(diff_fields(block, cells), -CLIP, CLIP)
    sync_sign = np.where(np.array(SYNC_ROW) == 1, 1, -1)
    # 位级聚合后再判同步行(v2 每位 4 变体格票合并)
    bit_of = np.array([c[0] for c in cells])
    b = np.zeros((GRID * GRID, fold, fold))
    np.add.at(b, bit_of, v)
    scale = len(blocks) * CLIP * (len(cells) // (GRID * GRID))
    margin = np.abs(b).min(axis=0) / scale
    cand = (np.sign(b[:GRID]) == sync_sign[:, None, None]).all(axis=0)
    return float((margin * cand).max()) if cand.any() else 0.0


def _hill_climb(
    rgb: np.ndarray, sx0: float, sy0: float, unipolar: bool, v2: bool
) -> tuple[float, float, float]:
    """从 (sx0, sy0) 出发按坐标轮换爬山,返回 (sx, sy, metric)。"""
    sx, sy = sx0, sy0
    best = _blind_metric(rgb, sx, sy, unipolar, v2)
    for step in BLIND_HILL_STEPS:
        for _ in range(BLIND_HILL_MAX_ITER):
            improved = False
            for dsx, dsy in ((step, 0), (-step, 0), (0, step), (0, -step)):
                nx, ny = sx * (1 + dsx), sy * (1 + dsy)
                m = _blind_metric(rgb, nx, ny, unipolar, v2)
                if m > best:
                    sx, sy, best = nx, ny, m
                    improved = True
            if not improved:
                break
    return sx, sy, best


def blind_extract(img: Image.Image, unipolar: bool, v2: bool = False) -> Hit | None:
    """盲缩放搜索:梳状周期盲测 sy 种子(等比粗扫兜底),各向异性
    爬山细化,在最优 (sx,sy) 处完整解码。(v2 点 y 密钥抖动同样遍历
    0~6,行投影梳状信号的周期结构不变,种子检测两形态通用)"""
    rgb = np.asarray(img.convert("RGB"), dtype=np.float64)

    seeds: list[tuple[float, float]] = []
    for sy in _comb_period_seeds(weighted_channel(rgb, unipolar)):
        seeds.append((sy, sy))
    if not seeds:
        # 兜底:等比粗扫 0.8~4.2(步长 3%,与爬山首档衔接)
        coarse = [
            (s, _blind_metric(rgb, s, s, unipolar, v2))
            for s in np.arange(0.8, 4.2, 0.03)
        ]
        coarse.sort(key=lambda kv: -kv[1])
        seeds = [(s, s) for s, m in coarse[:3] if m > 0]
    if not seeds:
        return None

    best_hit: Hit | None = None
    for sx0, sy0 in seeds:
        sx, sy, metric = _hill_climb(rgb, sx0, sy0, unipolar, v2)
        if metric <= 0:
            continue
        hit = try_extract(
            weighted_channel(_resample(rgb, sx, sy), unipolar), round(sx, 4), v2=v2
        )
        if hit:
            hit.dpr_y = round(sy, 4)
            if best_hit is None or (hit.verified, hit.ratio) > (
                best_hit.verified,
                best_hit.ratio,
            ):
                best_hit = hit
        if best_hit and best_hit.verified:
            break
    return best_hit


def extract(img: Image.Image, dprs: list[float]) -> list[Hit]:
    rgb = np.asarray(img.convert("RGB"), dtype=np.float64)
    hits: list[Hit] = []
    # 四种嵌入形态组合都试:形态 v2(2026-08 起,超周期去周期化)x
    # 混合模型(unipolar=内联消饱和方案 / bipolar=原生后端),外加
    # v1 两组合(历史版本)。verified 复核天然去伪,多模型互不误报。
    for dpr in dprs:
        # BOX = 面积平均,降采样时最忠实保留低幅度信号
        logical = _resample(rgb, dpr, dpr)
        for unipolar, v2 in ((True, True), (False, True), (True, False), (False, False)):
            hit = try_extract(weighted_channel(logical, unipolar), dpr, v2=v2)
            if hit:
                hits.append(hit)
    if not any(h.verified for h in hits):
        # 快路径失败:捕获帧可能被连续比例/非等比缩放,转盲搜
        for unipolar, v2 in ((True, True), (False, True), (True, False), (False, False)):
            blind = blind_extract(img, unipolar, v2=v2)
            if blind:
                hits.append(blind)
                if blind.verified:
                    break
    return sorted(hits, key=lambda h: (-h.verified, -h.ratio))


# ---- 自检:合成带印记捕获帧 → 提取,验证全链路 ----

def encode_bits(uid: int) -> list[int]:
    bits = list(SYNC_ROW)
    bits += [(uid >> i) & 1 for i in range(31, -1, -1)]
    c = crc8(uid)
    bits += [(c >> i) & 1 for i in range(7, -1, -1)]
    bits += [1, 0]  # 备用位
    return bits


def stamp(
    bg: np.ndarray, uid: int, dpr: float, unipolar: bool = False, v2: bool = True
) -> np.ndarray:
    """在物理分辨率 RGB 背景上按位置编码叠加印记。像素中心落入矩形
    才着色,与 Flutter 关闭抗锯齿的 drawRect 栅格规则一致。

    unipolar=False:复现 modulate+plus 双笔(原生后端),
      点位 B' = B·(255-DROP)/255 + DELTA,R/G 不动;
    unipolar=True:复现消饱和+plus 内联方案(2026-07 起,2026-08 起
      消饱和 α=DESAT_ALPHA 饱和避让):全屏三通道先乘
      (255-DESAT_ALPHA)/255,点位 B 再 +DELTA。
    v2=True(默认,与 Dart 现行一致):超周期去周期化点几何;
    v2=False 复现 v1 形态(历史版本回归用)。"""
    out = bg.astype(np.float64).copy()
    if unipolar:
        out *= (255 - DESAT_ALPHA) / 255
    bits = encode_bits(uid)
    h, w = out.shape[:2]
    cells, fold = _mode_geometry(v2)
    dot_w = LEFT_COLS[1] - LEFT_COLS[0]

    def blend(y0f, y1f, x0f, x1f):
        # 像素 k 中心 k+0.5 ∈ [lo, hi) ⇔ k ∈ [ceil(lo-0.5), ceil(hi-0.5))
        y0 = max(math.ceil(y0f * dpr - 0.5), 0)
        y1 = min(math.ceil(y1f * dpr - 0.5), h)
        x0 = max(math.ceil(x0f * dpr - 0.5), 0)
        x1 = min(math.ceil(x1f * dpr - 0.5), w)
        if y0 >= y1 or x0 >= x1:
            return
        b = out[y0:y1, x0:x1, 2]
        if unipolar:
            out[y0:y1, x0:x1, 2] = b + DELTA
        else:
            out[y0:y1, x0:x1, 2] = b * (255 - DROP) / 255 + DELTA

    for by in range(int(h / dpr / fold) + 1):
        for bx in range(int(w / dpr / fold) + 1):
            oy, ox = by * fold, bx * fold
            for bit_idx, flip, dy, xl in cells:
                bit = bits[bit_idx] ^ flip
                # cells 的 xl 是左位起点;bit=0 时点在右位(+dot_w)
                x = xl if bit else xl + dot_w
                blend(oy + dy, oy + dy + DOT_H, ox + x, ox + x + dot_w)
    return out


def _make_ui_bg(rng, w_px: int, h_px: int, dark: bool) -> np.ndarray:
    """模拟论坛类 App 捕获帧(RGB):平坦底色 + 卡片 + 文字行 + 彩色
    strip(头像/徽章等带色元素,验证彩色内容不干扰对立通道)。"""
    if dark:
        base, card, text = (18, 20, 26), (28, 31, 38), (185, 190, 200)
    else:
        base, card, text = (250, 250, 252), (240, 241, 245), (55, 60, 70)
    bg = np.empty((h_px, w_px, 3))
    bg[:] = base
    for _ in range(10):  # 卡片
        y = rng.integers(0, h_px - 200)
        x = rng.integers(0, max(w_px - 400, 1))
        bg[y : y + rng.integers(120, 400), x : x + rng.integers(300, w_px - x)] = card
    for _ in range(30):  # 彩色元素:头像/徽章/链接色块
        y = rng.integers(0, h_px - 90)
        x = rng.integers(0, w_px - 90)
        bg[y : y + rng.integers(30, 90), x : x + rng.integers(30, 90)] = rng.integers(
            0, 256, 3
        )
    line_h, y = 34, 60  # 文字行:随机短划线段模拟字形
    while y < h_px - line_h:
        if rng.random() < 0.65:
            x = 40
            while x < w_px - 60:
                seg = int(rng.integers(20, 90))
                if rng.random() < 0.55:
                    bg[y : y + line_h - 12, x : min(x + seg, w_px - 40)] = text
                x += seg + int(rng.integers(8, 30))
        y += line_h + int(rng.integers(6, 40))
    return bg + rng.normal(0, 1.0, bg.shape)


def _jpeg_roundtrip(arr: np.ndarray, quality: int) -> Image.Image:
    import io

    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="JPEG", quality=quality)
    buf.seek(0)
    return Image.open(buf)


def _make_mixed_bg(rng, w_px: int, h_px: int) -> np.ndarray:
    """混合明暗背景:暗色主题上半 + 大块白底卡片下半(暗色主题里
    刷到白底图片/浅色代码块的典型场景)——旧全局单极性方案的翻车
    用例,新混合笔在两半区极性相反但加权提取统一归一。"""
    dark = _make_ui_bg(rng, w_px, h_px, dark=True)
    light = _make_ui_bg(rng, w_px, h_px, dark=False)
    mixed = dark.copy()
    mixed[h_px // 2 :] = light[h_px // 2 :]
    return mixed


def self_test() -> int:
    rng = np.random.default_rng(42)
    uid, dpr = 998244353, 3.0
    w_px, h_px = 1170, 2532  # 典型手机捕获帧尺寸

    light = _make_ui_bg(rng, w_px, h_px, dark=False)
    dark = _make_ui_bg(rng, w_px, h_px, dark=True)
    mixed = _make_mixed_bg(rng, w_px, h_px)
    # v2 形态(现行):双极性(原生后端)与单极性(内联)两种混合模型
    st_light = np.clip(stamp(light, uid, dpr), 0, 255).astype(np.uint8)
    st_dark = np.clip(stamp(dark, uid, dpr), 0, 255).astype(np.uint8)
    st_mixed = np.clip(stamp(mixed, uid, dpr), 0, 255).astype(np.uint8)
    su_light = np.clip(stamp(light, uid, dpr, unipolar=True), 0, 255).astype(np.uint8)
    su_dark = np.clip(stamp(dark, uid, dpr, unipolar=True), 0, 255).astype(np.uint8)
    su_mixed = np.clip(stamp(mixed, uid, dpr, unipolar=True), 0, 255).astype(np.uint8)
    # v1 形态(历史版本,双极性/单极性各留一浅色回归)
    v1_bi = np.clip(stamp(light, uid, dpr, v2=False), 0, 255).astype(np.uint8)
    v1_uni = np.clip(
        stamp(light, uid, dpr, unipolar=True, v2=False), 0, 255
    ).astype(np.uint8)

    cases = [
        # δ=1 契约:无损 PNG(系统捕获帧本体)必须稳过;JPEG 重压缩为
        # 观察项——ΔB=1 经 4:2:0 色度半采样 + Cb 量化后贴噪声底,
        # q85 能否救回取决于内容,不作硬承诺(要覆盖转发场景需上调
        # δ 或改非对称档,是产品决策不是解码端标定问题)
        ("浅色 PNG 无损", Image.fromarray(st_light), True),
        ("浅色 JPEG q85", _jpeg_roundtrip(st_light, 85), False),
        ("浅色 JPEG q70", _jpeg_roundtrip(st_light, 70), False),
        ("浅色 裁剪 60% PNG", Image.fromarray(st_light[300:2000, 200:1000]), True),
        ("深色 PNG 无损", Image.fromarray(st_dark), True),
        ("深色 JPEG q85", _jpeg_roundtrip(st_dark, 85), False),
        ("明暗混排 PNG 无损", Image.fromarray(st_mixed), True),
        ("明暗混排 JPEG q85", _jpeg_roundtrip(st_mixed, 85), False),
        ("单极性 浅色 PNG 无损", Image.fromarray(su_light), True),
        ("单极性 深色 PNG 无损", Image.fromarray(su_dark), True),
        ("单极性 明暗混排 PNG 无损", Image.fromarray(su_mixed), True),
        ("单极性 裁剪 60% PNG", Image.fromarray(su_light[300:2000, 200:1000]), True),
        ("单极性 浅色 JPEG q85", _jpeg_roundtrip(su_light, 85), False),
        # v1 历史形态回归(已发版本的外流帧仍须可解)
        ("v1 双极性 浅色 PNG 无损", Image.fromarray(v1_bi), True),
        ("v1 单极性 浅色 PNG 无损", Image.fromarray(v1_uni), True),
    ]
    # 边界情报:全屏彩色照片背景,色度纹理淹没印记属预期,不计入结果
    yy, xx = np.mgrid[0:h_px, 0:w_px]
    photo = np.empty((h_px, w_px, 3))
    photo[..., 0] = 120 + 60 * np.sin(yy / 400)
    photo[..., 1] = 110 + 50 * np.cos(xx / 250)
    photo[..., 2] = 100 + 60 * np.sin((yy + xx) / 300)
    photo += np.asarray(
        Image.fromarray(
            np.clip(rng.normal(0, 25, (h_px // 8, w_px // 8, 3)) + 128, 0, 255).astype(
                np.uint8
            )
        ).resize((w_px, h_px), Image.BILINEAR),
        dtype=np.float64,
    ) - 128
    st_photo = np.clip(stamp(np.clip(photo, 0, 255), uid, dpr), 0, 255).astype(np.uint8)
    cases.append(("全屏照片纹理(边界,允许失败)", Image.fromarray(st_photo), False))

    ok = True
    for label, img, required in cases:
        hits = extract(img, DPR_CANDIDATES)
        got = hits[0] if hits else None
        passed = got is not None and got.uid == uid and got.verified
        if required:
            ok &= passed
        elif got is not None and got.verified and got.uid != uid:
            # 非必过用例提不出可以接受,但 verified 的错 uid 是假阳性
            ok = False
        tag = "PASS" if passed else ("FAIL" if required else "INFO")
        detail = (
            f"uid={got.uid} scale={got.scale_desc} ratio={got.ratio:.2f} margin={got.margin:.2f} "
            f"blocks={got.n_blocks} verified={got.verified} v2={got.v2}"
            if got
            else "未提取到"
        )
        print(f"[{tag}] {label}: {detail}")

    # 阴性对照:无印记原始背景,不得出现 verified 命中
    neg = extract(Image.fromarray(light.astype(np.uint8)), DPR_CANDIDATES)
    neg_hit = next((h for h in neg if h.verified), None)
    print(f"[{'FAIL' if neg_hit else 'PASS'}] 阴性对照(无印记): "
          + (f"误报 uid={neg_hit.uid}" if neg_hit else "无 verified 命中"))
    ok &= neg_hit is None
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="FluxDO 屏幕标识印记提取")
    ap.add_argument("image", nargs="?", help="捕获帧路径(PNG/JPEG)")
    ap.add_argument("--dpr", type=float, help="已知设备像素比时直接指定,跳过扫描")
    ap.add_argument("--self-test", action="store_true", help="合成捕获帧端到端自检")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.image:
        ap.error("缺少捕获帧路径(或使用 --self-test)")

    img = Image.open(args.image)
    hits = extract(img, [args.dpr] if args.dpr else DPR_CANDIDATES)
    if not hits:
        print(
            "未提取到印记:可能捕获帧过小(不足一个完整块)、经历强压缩,"
            "或来源并非本应用捕获帧。可尝试 --dpr 指定原设备像素比。"
        )
        return 1
    top = hits[0]
    cred = "已复核" if top.verified else "未复核(仅单区解码,可信度低)"
    print(f"提取结果: uid = {top.uid} [{cred}]")
    for h in hits:
        print(
            f"  scale={h.scale_desc:<9} phase={h.phase} ratio={h.ratio:.2f} margin={h.margin:.2f} "
            f"blocks={h.n_blocks} verified={h.verified} uid={h.uid}"
        )
    return 0 if top.verified else 2


if __name__ == "__main__":
    sys.exit(main())
