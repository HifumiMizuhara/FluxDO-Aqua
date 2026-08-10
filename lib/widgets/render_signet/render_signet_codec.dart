/// 渲染帧亚阈值标识印记 · 编解码内核(纯 Dart,可单测)。
///
/// 把一个 32 位标识值编码为一层肉眼不可见的低对比点阵,平铺进渲染
/// 输出,可从无损帧还原。用于渲染输出的会话标识与合成一致性核验。
///
/// ## 编码结构
///
/// 一个印记块为 [kSignetGridRows] x [kSignetGridCols] 个单元格
/// (行优先):
/// - 第 0 行(7 格):固定同步图案 [kSignetSyncRow],供解码端对齐块原点;
/// - 其余 42 格:32 位标识值(大端) + 8 位 CRC-8 + 2 位备用定值。
///
/// ## 单元格 = 蓝通道位置编码
///
/// 每格只在左/右两个候选位之一画点:bit=1 在左位,bit=0 在右位。
///
/// ## 逐像素自适应极性:modulate + plus 双笔混合
///
/// 早期实现按全局主题明暗二选一画蓝点/黄点,但同屏混排明暗区域是
/// 常态(暗色主题里的白底图片、浅色主题里的代码块),错配区域要么
/// 可见要么信号清零。现方案让 GPU 混合方程逐像素完成极性自适应:
/// 同一点位按顺序叠两笔,全程只动 B 通道:
///
/// 1. modulate 笔:不透明白底图块,点色 (255,255,255-[kSignetModulateDrop])
///    → B' = B·(255-drop)/255,白底满效、黑底无效;
/// 2. plus 笔:透明底图块,点色 (0,0,255)@α=[kSignetPlusDelta]
///    → B' = B + delta,黑底满效、白底饱和自动熄火。
///
/// 取 drop = 2·delta,合成 ΔB = delta·(1 - 2B/255):黑底 +delta、
/// 白底 -delta,极性随局部底色连续翻转,无需(也不存在)全局主题
/// 判断。必须先 modulate 后 plus:结果值域 [delta, 255-delta] 无
/// clamp,两端严格对称;反序会在白底被 clamp 截断成 -2·delta。
/// 两种混合模式在 Skia/Impeller 均为系数混合(非 advanced blend),
/// 不触发离屏 pass。
///
/// 不可见性:R/G/A 全程不动,ΔB=±delta 的亮度权重仅 7%,
/// delta=1/255 的扰动与显示面板自身的量化/FRC 抖动同量级,任意
/// 底色上都低于亮度 JND——物理上的"完全不可见",不是"淡到难察觉"。
/// 代价是单点信噪比低,且 B≈128 的中灰是天然死区(信号过零),靠
/// 加大点面积 + 全屏多块投票在解码端统计还原;无损帧任何 delta>0
/// 都完整保留。
///
/// 解码端在蓝-黄对立通道 O = B-(R+G)/2 上做左右位差分(只动 B,
/// 故 ΔO = ΔB),并以局部 B 均值估计期望极性权重 w = 1-2B/255 对
/// 差分加权投票。
///
/// 块以 [kSignetBlockPeriod] 逻辑像素为周期平铺:帧被裁剪也能命中
/// 完整块,且多块符号投票可摊平内容纹理与 JPEG 色度量化噪声。
///
/// 几何常量(逻辑像素,离线核验脚本 tools/render-signet/extract.py
/// 必须与此保持一致):
/// - 单元格 [kSignetCellSize] x [kSignetCellSize];
/// - 左位 x∈[1,6)、右位 x∈[6,11),点 5x6,左右相邻(相邻背景相关性
///   最强,差分抵消内容纹理效果最好)。
library;

/// 印记块列数(单元格)
const int kSignetGridCols = 7;

/// 印记块行数(单元格)
const int kSignetGridRows = 7;

/// 单元格边长(逻辑像素)
const double kSignetCellSize = 12.0;

/// 单元格内左位 x 偏移
const double kSignetDotLeftX = 1.0;

/// 单元格内右位 x 偏移
const double kSignetDotRightX = 6.0;

/// 点宽
const double kSignetDotW = 5.0;

/// 点高
const double kSignetDotH = 6.0;

/// v1 点 y 偏移(0~6,固定打散):画笔已切 v2([signetV2YOff]),仅
/// 供离线解码端参考保留——extract.py 仍须解已发 v1 版本的外流帧。
/// 消条纹动机:所有格同 y 会形成 12px 周期"点带",人眼沿线积分
/// 使阈值降 2~4 倍。
int signetDotYOffset(int row, int col) => (3 * row + 5 * col) % 7;

/// 块平铺周期(逻辑像素) = 列数 x 单元格边长
const double kSignetBlockPeriod = kSignetGridCols * kSignetCellSize;

/// plus 笔点位 B 通道抬升量(0~255)。黑底上 ΔB=+kSignetPlusDelta。
/// 取 1(可行的物理最小值):亮度基频对比 ~0.03%(CSF 阈值的
/// 1/10)、蓝黄色度 ~0.3%(阈值的 1/7),低于显示面板自身量化
/// 抖动,任何底色上物理不可见;无损帧解码不受影响,代价是 JPEG
/// 重压缩后的统计信噪比减半(解码端符号投票对幅度不敏感,算法
/// 无需改动)。
const int kSignetPlusDelta = 1;

/// modulate 笔点位 B 通道乘性压降(0~255):B' = B·(255-drop)/255。
/// 取 2·kSignetPlusDelta,使黑/白底合成信号 ±kSignetPlusDelta 严格对称。
const int kSignetModulateDrop = 2 * kSignetPlusDelta;

/// 内联方案消饱和笔 α(0~255)。功能需求只要 1δ(消除 B=255 饱和让
/// plus 满效),取 2δ 是外流增强放大案(2026-08)的加固:α=δ 时浅色
/// 底 B 降到 254、点位 +δ 恰回 255,点位成为「全屏唯一饱和像素」,
/// 对饱和/平坦区有特判的下游增强、量化算法会单独放大它们;α=2δ 后
/// 底色 253、点位 254,该身份消失。全屏均匀变化 0.8% 仍低于面板校准
/// 差异,解码端对立通道对全通道等比缩放不敏感,识别率不受影响。
///
/// 同案结论(tools/render-signet/enhance_bench.py 台架实测,勿走
/// 回头路):
/// - 点缘半密度打散已试验并撤销——δ=1 是 8-bit 最小量化步,半密度
///   环实为 1px 棋盘=全图最高频结构,小半径 USM 下过冲 0.8→3.2
///   反向放大 4 倍;
/// - 直方图拉伸类增强(CLAHE 等)会把任何 δ=1 图案拉到满对比,
///   画笔形态层不存在对抗手段,属幅度语义的固有边界。
const int kSignetDesatAlpha = 2 * kSignetPlusDelta;

/// 同步行图案(块首行,解码端用于块原点对齐与方向校验)
const List<bool> kSignetSyncRow = [true, false, true, true, false, false, true];

/// 备用定值位(暂不参与校验,留作版本扩展)
const List<bool> kSignetSpareBits = [true, false];

// ---- v2 形态层:超周期去周期化(2026-08 外流放大案组合拳) ----
//
// v1 形态 = 每块位图完全相同 + 点位仅 y 有固定打散,残迹被下游增强
// 放大后是一眼可辨的等距点阵墙(自相关峰 0.91)。v2 不动编码结构
// (49 位/块、位置差分、δ 幅度全部原样),只把「像素长相」去周期:
// 相邻 2x2 个块为 4 个变体,点的 y 偏移/位对 x 滑移/payload 位翻转
// 均由变体+格坐标的密钥哈希决定——位值仍按 84 周期平铺,像素图案
// 周期变 168 且块间互不相同,近域自相关峰降到 0.40(台架
// signet_v2_proto.py 实测,解码往返/裁切/JPEG q85 全通过)。
// 密钥是公开常量:目的是去周期,不是保密。

/// 超周期(块数):形态变体阵列为 kSignetSuperBlocks² 个块。
/// 台架实测 2 与 3 形态收益相同,取 2(最小裁切门槛更低)。
const int kSignetSuperBlocks = 2;

/// 图块平铺周期(逻辑像素)= 超周期 x 块周期。tile 构建与原生
/// 后端平铺契约用它;编码块周期仍是 [kSignetBlockPeriod]。
const double kSignetTilePeriod = kSignetBlockPeriod * kSignetSuperBlocks;

/// 32 位乘法(web 安全):JS 数值是 double,直接乘会超 2^53 失精度,
/// 16 位分段保证全平台(native/web)与解码端 Python 逐位一致。
int _mul32(int a, int b) =>
    (((a & 0xFFFF) * b) + ((((a >> 16) & 0xFFFF) * b & 0xFFFF) << 16)) &
    0xFFFFFFFF;

/// v2 密钥哈希(xorshift 洗匀低位)。与 tools/render-signet/extract.py
/// 的 v2_hash 严格同式,改动必须两端同步。
int signetV2Hash(int variant, int row, int col, int salt) {
  var x = (variant * 2654435761 +
          row * 40503 +
          col * 10859 +
          salt * 97 +
          0x5EED) &
      0xFFFFFFFF;
  x ^= x >> 13;
  x = _mul32(x, 2246822519);
  x ^= x >> 11;
  return x;
}

/// v2 点 y 偏移(0~6):同一格在 4 个变体里落点不同,消灭 84px
/// 纵向周期与 12px 行带(v1 dot_y 的职责由它接管并叠加变体维度)。
int signetV2YOff(int variant, int row, int col) =>
    signetV2Hash(variant, row, col, 1) % 7;

/// v2 位对 x 滑移(0~1):左右位对整体平移,破坏 12px 列格。
/// 点仍在格内(1+1+10 = 12 恰好贴右缘),左右位相邻性(差分抵消
/// 背景纹理的前提)不变。
int signetV2XShift(int variant, int row, int col) =>
    signetV2Hash(variant, row, col, 2) % 2;

/// v2 payload 扰码位:该格位值按变体 XOR,块与块位图不再相同。
/// 同步行(row=0)不扰码——它是解码端的相位对齐锚。
bool signetV2MaskBit(int variant, int row, int col) =>
    signetV2Hash(variant, row, col, 3) % 2 == 1;

/// 枚举一个 v2 超周期图块([kSignetTilePeriod] 见方)内的全部点矩形
/// (逻辑坐标 LTWH)。tile 构建的单一真相:内联信号笔与原生双笔共用,
/// extract.py 的 stamp() 按同式生成。
List<(double, double)> signetV2DotOrigins(int id) {
  final bits = encodeSignetBits(id);
  final dots = <(double, double)>[];
  for (var qy = 0; qy < kSignetSuperBlocks; qy++) {
    for (var qx = 0; qx < kSignetSuperBlocks; qx++) {
      final variant = qy * kSignetSuperBlocks + qx;
      for (var row = 0; row < kSignetGridRows; row++) {
        for (var col = 0; col < kSignetGridCols; col++) {
          var bit = bits[row * kSignetGridCols + col];
          if (row > 0 && signetV2MaskBit(variant, row, col)) bit = !bit;
          final x = qx * kSignetBlockPeriod +
              col * kSignetCellSize +
              signetV2XShift(variant, row, col) +
              (bit ? kSignetDotLeftX : kSignetDotRightX);
          final y = qy * kSignetBlockPeriod +
              row * kSignetCellSize +
              signetV2YOff(variant, row, col);
          dots.add((x, y));
        }
      }
    }
  }
  return dots;
}

/// CRC-8 (poly 0x07, init 0x00),对标识值的 4 个大端字节计算。
int signetCrc8(int id) {
  var crc = 0;
  for (var i = 3; i >= 0; i--) {
    crc ^= (id >> (8 * i)) & 0xFF;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

/// 把标识值编码为一个印记块的位序列(长度 = 行数 x 列数,行优先)。
List<bool> encodeSignetBits(int id) {
  assert(id >= 0 && id <= 0xFFFFFFFF, '标识值超出 32 位范围');
  final bits = <bool>[...kSignetSyncRow];
  for (var i = 31; i >= 0; i--) {
    bits.add((id >> i) & 1 == 1);
  }
  final crc = signetCrc8(id);
  for (var i = 7; i >= 0; i--) {
    bits.add((crc >> i) & 1 == 1);
  }
  bits.addAll(kSignetSpareBits);
  assert(bits.length == kSignetGridRows * kSignetGridCols);
  return bits;
}

/// 从位序列解码标识值。同步行或 CRC 校验失败返回 null。
int? decodeSignetBits(List<bool> bits) {
  if (bits.length != kSignetGridRows * kSignetGridCols) return null;
  for (var i = 0; i < kSignetSyncRow.length; i++) {
    if (bits[i] != kSignetSyncRow[i]) return null;
  }
  var id = 0;
  for (var i = 0; i < 32; i++) {
    id = (id << 1) | (bits[kSignetGridCols + i] ? 1 : 0);
  }
  var crc = 0;
  for (var i = 0; i < 8; i++) {
    crc = (crc << 1) | (bits[kSignetGridCols + 32 + i] ? 1 : 0);
  }
  if (crc != signetCrc8(id)) return null;
  // 备用位不校验:留作前向兼容
  return id;
}
