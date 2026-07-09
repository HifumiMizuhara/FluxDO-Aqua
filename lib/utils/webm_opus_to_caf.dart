import 'dart:typed_data';

/// WebM(Opus)→ CAF 无损重封装。
///
/// 背景:Discourse 录音/语音消息是 MediaRecorder 产出的 WebM/Opus,
/// linux.do 上还常被改名 .xz 绕上传白名单。浏览器/ExoPlayer 自带
/// Matroska demuxer 能播;AVFoundation(iOS/macOS)不认 WebM 容器,
/// 改扩展名也无用。但 CoreAudio(iOS 11+ / macOS 10.13+)支持 **CAF
/// 容器内的 Opus** —— 把 Opus 包从 WebM 原样搬进 CAF(纯容器层搬运,
/// 不转码)即可播放。本方案已用真实 linux.do 语音贴 + `afplay`
/// (AudioToolbox,与 AVFoundation 同解码栈)端到端实证。
///
/// 仅接管确定性可靠的形态(MediaRecorder 产物均满足):
/// 单 Opus 音轨、无视频轨、无 lacing、全部包帧数恒定。
/// 其余(webm 视频 / vorbis / 变长包)返回 null,调用方走原有兜底。
Uint8List? webmOpusToCaf(Uint8List webm) {
  try {
    final demux = _WebmOpusDemuxer(webm)..run();
    final head = demux.opusHead;
    if (head == null ||
        demux.hasVideo ||
        demux.packets.isEmpty ||
        head.length < 12) {
      return null;
    }
    if (String.fromCharCodes(head.sublist(0, 8)) != 'OpusHead') return null;
    final channels = head[9];
    final preSkip = head[10] | (head[11] << 8);

    // 每包帧数(48kHz 采样数,由 Opus TOC 派生);仅接管恒定帧数
    // (CAF desc.mFramesPerPacket 走常量,是 afplay 实证过的形态)
    final frameCounts = demux.packets.map(_opusPacketFrames).toSet();
    if (frameCounts.length != 1 || frameCounts.first <= 0) return null;
    final framesPerPacket = frameCounts.first;

    return _writeCaf(
      channels: channels,
      preSkip: preSkip,
      framesPerPacket: framesPerPacket,
      packets: demux.packets,
    );
  } catch (_) {
    return null; // 任何解析意外都视为不可接管
  }
}

/// EBML master 元素(需要递归下钻的容器):
/// Segment / Tracks / TrackEntry / Cluster / BlockGroup
const _masterIds = {0x18538067, 0x1654AE6B, 0xAE, 0x1F43B675, 0xA0};

class _WebmOpusDemuxer {
  _WebmOpusDemuxer(this.b);

  final Uint8List b;
  Uint8List? opusHead;
  int? opusTrack;
  bool hasVideo = false;
  final packets = <Uint8List>[];

  void run() {
    _walk(0, b.length);
  }

  void _walk(int start, int end) {
    var p = start;
    while (p < end) {
      final (id, p1) = _readId(p);
      final (size, unknown, p2) = _readSize(p1);
      // unknown-size(vint 全 1,MediaRecorder 流式输出的 Segment/Cluster
      // 常见)按"延伸到父容器边界"处理;即使把后继 sibling 嵌套进来,
      // 递归遍历也不漏 SimpleBlock
      final payloadEnd = unknown ? end : p2 + size;
      if (payloadEnd > end) throw const FormatException('ebml overflow');
      if (id == 0xAE) {
        _parseTrackEntry(p2, payloadEnd);
      } else if (_masterIds.contains(id)) {
        _walk(p2, payloadEnd);
      } else if (id == 0xA3 || id == 0xA1) {
        // SimpleBlock / Block(BlockGroup 内)同构
        _addBlock(p2, payloadEnd);
      }
      p = payloadEnd;
    }
  }

  void _parseTrackEntry(int start, int end) {
    int? number;
    String? codecId;
    Uint8List? codecPrivate;
    var p = start;
    while (p < end) {
      final (id, p1) = _readId(p);
      final (size, unknown, p2) = _readSize(p1);
      final payloadEnd = unknown ? end : p2 + size;
      switch (id) {
        case 0xD7: // TrackNumber
          var v = 0;
          for (var i = p2; i < payloadEnd; i++) {
            v = (v << 8) | b[i];
          }
          number = v;
        case 0x86: // CodecID
          codecId = String.fromCharCodes(b.sublist(p2, payloadEnd));
        case 0x63A2: // CodecPrivate
          codecPrivate = Uint8List.sublistView(b, p2, payloadEnd);
      }
      p = payloadEnd;
    }
    if (codecId != null && codecId.startsWith('V_')) hasVideo = true;
    if (codecId == 'A_OPUS') {
      opusTrack = number;
      opusHead = codecPrivate;
    }
  }

  void _addBlock(int start, int end) {
    var q = start;
    // track number(vint,去 marker)
    final first = b[q];
    var len = 1;
    var mask = 0x80;
    while (len <= 8 && (first & mask) == 0) {
      mask >>= 1;
      len++;
    }
    var track = first & (mask - 1);
    for (var i = 1; i < len; i++) {
      track = (track << 8) | b[q + i];
    }
    q += len;
    q += 2; // 相对时间戳(int16),CAF 侧不需要
    final flags = b[q];
    q += 1;
    if ((flags & 0x06) != 0) {
      throw const FormatException('lacing not supported');
    }
    if (opusTrack != null && track != opusTrack) return;
    packets.add(Uint8List.sublistView(b, q, end));
  }

  /// EBML ID:保留 marker 位整体作为 ID 值
  (int, int) _readId(int p) {
    final first = b[p];
    var len = 1;
    var mask = 0x80;
    while (len <= 4 && (first & mask) == 0) {
      mask >>= 1;
      len++;
    }
    if (len > 4) throw const FormatException('bad ebml id');
    var v = 0;
    for (var i = 0; i < len; i++) {
      v = (v << 8) | b[p + i];
    }
    return (v, p + len);
  }

  /// EBML size:去 marker 位;全 1 表示 unknown-size
  (int, bool, int) _readSize(int p) {
    final first = b[p];
    var len = 1;
    var mask = 0x80;
    while (len <= 8 && (first & mask) == 0) {
      mask >>= 1;
      len++;
    }
    if (len > 8) throw const FormatException('bad ebml size');
    var v = first & (mask - 1);
    for (var i = 1; i < len; i++) {
      v = (v << 8) | b[p + i];
    }
    final unknown = v == (1 << (7 * len)) - 1;
    return (v, unknown, p + len);
  }
}

/// Opus TOC → 该包采样帧数(48kHz)。RFC 6716 §3.1:
/// config 0-11 = SILK(10/20/40/60ms),12-15 = Hybrid(10/20ms),
/// 16-31 = CELT(2.5/5/10/20ms);code 0/1/2/3 = 1/2/2/N 帧。
int _opusPacketFrames(Uint8List pkt) {
  if (pkt.isEmpty) return 0;
  final toc = pkt[0];
  final config = toc >> 3;
  final code = toc & 0x3;
  final int perFrame;
  if (config < 12) {
    perFrame = const [480, 960, 1920, 2880][config % 4];
  } else if (config < 16) {
    perFrame = const [480, 960][config % 2];
  } else {
    perFrame = const [120, 240, 480, 960][config % 4];
  }
  final int frames;
  if (code == 0) {
    frames = 1;
  } else if (code < 3) {
    frames = 2;
  } else {
    if (pkt.length < 2) return 0;
    frames = pkt[1] & 0x3F;
  }
  return perFrame * frames;
}

Uint8List _writeCaf({
  required int channels,
  required int preSkip,
  required int framesPerPacket,
  required List<Uint8List> packets,
}) {
  final out = BytesBuilder(copy: false);
  // 文件头:'caff' + version 1 + flags 0
  out.add(const [0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0]);

  // 'desc':AudioStreamBasicDescription(BE)
  final desc = ByteData(32)
    ..setFloat64(0, 48000.0) // Opus 解码输出固定 48kHz
    ..setUint32(8, 0x6F707573) // 'opus'
    ..setUint32(12, 0) // formatFlags
    ..setUint32(16, 0) // bytesPerPacket:变长,由 pakt 表描述
    ..setUint32(20, framesPerPacket)
    ..setUint32(24, channels)
    ..setUint32(28, 0); // bitsPerChannel:压缩格式为 0
  _chunk(out, 'desc', desc.buffer.asUint8List());

  // 'pakt':包表头 + 每包字节数(VLQ)
  final sizes = BytesBuilder(copy: false);
  var bodyLen = 0;
  for (final pk in packets) {
    _vlq(sizes, pk.length);
    bodyLen += pk.length;
  }
  final paktHead = ByteData(24)
    ..setInt64(0, packets.length)
    ..setInt64(8, framesPerPacket * packets.length - preSkip)
    ..setInt32(16, preSkip) // priming frames(Opus pre-skip)
    ..setInt32(20, 0);
  final pakt = BytesBuilder(copy: false)
    ..add(paktHead.buffer.asUint8List())
    ..add(sizes.takeBytes());
  _chunk(out, 'pakt', pakt.takeBytes());

  // 'data':editCount + Opus 包原样拼接
  final dataHead = ByteData(12)
    ..setUint32(0, 0x64617461) // 'data'
    ..setInt64(4, 4 + bodyLen);
  out.add(dataHead.buffer.asUint8List());
  out.add(const [0, 0, 0, 0]); // editCount
  for (final pk in packets) {
    out.add(pk);
  }
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List payload) {
  final head = ByteData(12)
    ..setUint32(0, type.codeUnits.fold(0, (a, c) => (a << 8) | c))
    ..setInt64(4, payload.length);
  out.add(head.buffer.asUint8List());
  out.add(payload);
}

/// CAF 包表的变长整数:base-128,高位组在前,除末字节外置 0x80 续位
void _vlq(BytesBuilder out, int n) {
  final groups = <int>[n & 0x7F];
  var v = n >> 7;
  while (v > 0) {
    groups.add(0x80 | (v & 0x7F));
    v >>= 7;
  }
  out.add(groups.reversed.toList());
}
