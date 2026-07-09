import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/webm_opus_to_caf.dart';

// ── 合成 EBML 构造器 ──────────────────────────────────────────────

List<int> _el(List<int> id, List<int> payload) =>
    [...id, 0x80 | payload.length, ...payload];

/// OpusHead:ver 1 / 1ch / pre-skip 312 / 48000Hz / gain 0 / mapping 0
final _opusHead = [
  ...'OpusHead'.codeUnits,
  1, 1, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0, 0, 0,
];

List<int> _trackEntry(String codecId, {int number = 1, List<int>? private}) =>
    _el([0xAE], [
      ..._el([0xD7], [number]),
      ..._el([0x86], codecId.codeUnits),
      if (private != null) ..._el([0x63, 0xA2], private),
    ]);

/// SimpleBlock:track vint + int16 时间戳 + flags + opus 包
List<int> _simpleBlock(List<int> pkt, {int flags = 0, int track = 1}) =>
    _el([0xA3], [0x80 | track, 0, 0, flags, ...pkt]);

Uint8List _webm({
  required List<List<int>> trackEntries,
  required List<List<int>> blocks,
  bool unknownSize = false,
}) {
  final tracks = _el([0x16, 0x54, 0xAE, 0x6B], trackEntries.expand((e) => e).toList());
  final cluster = _el([0x1F, 0x43, 0xB6, 0x75], [
    ..._el([0xE7], [0]), // Timestamp
    ...blocks.expand((e) => e),
  ]);
  final body = [...tracks, ...cluster];
  final segment = unknownSize
      // size vint 全 1(0xFF)= unknown-size,MediaRecorder 流式输出常见
      ? [0x18, 0x53, 0x80, 0x67, 0xFF, ...body]
      : _el([0x18, 0x53, 0x80, 0x67], body);
  return Uint8List.fromList(segment);
}

// toc 0x58:config 11(SILK WB 60ms)code 0 → 2880 帧/包
const _pkt60ms1 = [0x58, 0xAA, 0xBB, 0xCC];
const _pkt60ms2 = [0x58, 0x11, 0x22];
// toc 0x48:config 9(SILK WB 20ms)→ 960 帧/包
const _pkt20ms = [0x48, 0x33];

// ── CAF 解析小工具(验证输出结构) ────────────────────────────────

Map<String, Uint8List> _cafChunks(Uint8List caf) {
  expect(String.fromCharCodes(caf.sublist(0, 4)), 'caff');
  final chunks = <String, Uint8List>{};
  var p = 8;
  final bd = ByteData.sublistView(caf);
  while (p < caf.length) {
    final type = String.fromCharCodes(caf.sublist(p, p + 4));
    final size = bd.getInt64(p + 4);
    chunks[type] = Uint8List.sublistView(caf, p + 12, p + 12 + size);
    p += 12 + size;
  }
  return chunks;
}

void main() {
  group('webmOpusToCaf', () {
    test('单 Opus 轨 webm → 结构正确的 CAF', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_OPUS', private: _opusHead)],
        blocks: [_simpleBlock(_pkt60ms1), _simpleBlock(_pkt60ms2)],
      ));
      expect(caf, isNotNull);
      final chunks = _cafChunks(caf!);

      final desc = ByteData.sublistView(chunks['desc']!);
      expect(desc.getFloat64(0), 48000.0);
      expect(desc.getUint32(8), 0x6F707573); // 'opus'
      expect(desc.getUint32(20), 2880); // framesPerPacket
      expect(desc.getUint32(24), 1); // channels

      final pakt = ByteData.sublistView(chunks['pakt']!);
      expect(pakt.getInt64(0), 2); // packets
      expect(pakt.getInt64(8), 2880 * 2 - 312); // valid frames
      expect(pakt.getInt32(16), 312); // priming = pre-skip
      // VLQ 包大小表:4 与 3
      expect(chunks['pakt']!.sublist(24), [4, 3]);

      // data:editCount + 两包原样拼接
      expect(chunks['data']!.sublist(4), [..._pkt60ms1, ..._pkt60ms2]);
    });

    test('unknown-size Segment/Cluster 照常提取', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_OPUS', private: _opusHead)],
        blocks: [_simpleBlock(_pkt60ms1)],
        unknownSize: true,
      ));
      expect(caf, isNotNull);
    });

    test('含视频轨的 webm 不接管', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [
          _trackEntry('V_VP9', number: 1),
          _trackEntry('A_OPUS', number: 2, private: _opusHead),
        ],
        blocks: [_simpleBlock(_pkt60ms1, track: 2)],
      ));
      expect(caf, isNull);
    });

    test('vorbis 音轨不接管(CoreAudio 不支持)', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_VORBIS', private: _opusHead)],
        blocks: [_simpleBlock(_pkt60ms1)],
      ));
      expect(caf, isNull);
    });

    test('包帧数不恒定不接管(仅实证过恒定形态)', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_OPUS', private: _opusHead)],
        blocks: [_simpleBlock(_pkt60ms1), _simpleBlock(_pkt20ms)],
      ));
      expect(caf, isNull);
    });

    test('lacing 不接管', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_OPUS', private: _opusHead)],
        blocks: [_simpleBlock(_pkt60ms1, flags: 0x02)],
      ));
      expect(caf, isNull);
    });

    test('非 opus 轨的 block 被忽略', () {
      final caf = webmOpusToCaf(_webm(
        trackEntries: [_trackEntry('A_OPUS', number: 2, private: _opusHead)],
        blocks: [
          _simpleBlock([0x00, 0x01], track: 1), // 其他轨,应忽略
          _simpleBlock(_pkt60ms1, track: 2),
        ],
      ));
      expect(caf, isNotNull);
      final chunks = _cafChunks(caf!);
      expect(ByteData.sublistView(chunks['pakt']!).getInt64(0), 1);
    });
  });
}
