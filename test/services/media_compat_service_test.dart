import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media_compat_service.dart';

Uint8List _bytes(List<int> head) => Uint8List.fromList([
      ...head,
      ...List.filled(64, 0),
    ]);

/// mp4 (ftyp isom) 头,linux.do 实测「.xz 装 mp4」帖子的真实头部形态
final _ftypIsom = _bytes([
  0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, // ....ftyp
  0x69, 0x73, 0x6F, 0x6D, // isom
]);

final _ftypQt = _bytes([
  0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, // ....ftyp
  0x71, 0x74, 0x20, 0x20, // 'qt  '
]);

final _id3Mp3 = _bytes([0x49, 0x44, 0x33, 0x04, 0x00]); // ID3v2

final _xzMagic = _bytes([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]); // 真 xz

void main() {
  setUp(() => MediaCompatService.debugAvPlatformOverride = true);
  tearDown(() => MediaCompatService.debugAvPlatformOverride = null);

  group('needsProbe', () {
    final svc = MediaCompatService.instance;

    test('known media extensions skip probing', () {
      expect(svc.needsProbe('https://cdn.example.com/a.mp4'), isFalse);
      expect(svc.needsProbe('https://cdn.example.com/a.mov'), isFalse);
      expect(svc.needsProbe('https://cdn.example.com/a.mp3'), isFalse);
      expect(svc.needsProbe('https://cdn.example.com/a.webm'), isFalse);
    });

    test('unknown/non-media extensions need probing', () {
      expect(svc.needsProbe('https://cdn.example.com/a.xz'), isTrue);
      expect(svc.needsProbe('https://cdn.example.com/a.bin'), isTrue);
      expect(svc.needsProbe('https://cdn.example.com/noext'), isTrue);
    });

    test('non-http and non-AV-platform skip probing', () {
      expect(svc.needsProbe('file:///tmp/a.xz'), isFalse);
      MediaCompatService.debugAvPlatformOverride = false;
      expect(svc.needsProbe('https://cdn.example.com/a.xz'), isFalse);
    });
  });

  group('sniffMime', () {
    test('detects mp4 renamed to .xz (real-world header)', () {
      expect(
        MediaCompatService.sniffMime('https://c.example.com/a.xz', _ftypIsom),
        'video/mp4',
      );
    });

    test('detects quicktime brand via ftyp fallback', () {
      expect(
        MediaCompatService.sniffMime('https://c.example.com/a.xz', _ftypQt),
        'video/quicktime',
      );
    });

    test('detects M4A brand via ftyp fallback (real-world header)', () {
      // linux.do 「.xz 装 m4a」帖子的真实头部形态(ftyp M4A )
      final header = _bytes([
        0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, // ....ftyp
        0x4D, 0x34, 0x41, 0x20, // 'M4A '
      ]);
      expect(
        MediaCompatService.sniffMime('https://c.example.com/a.xz', header),
        'audio/mp4',
      );
    });

    test('detects mp3 (ID3) renamed to .xz', () {
      expect(
        MediaCompatService.sniffMime('https://c.example.com/a.xz', _id3Mp3),
        'audio/mpeg',
      );
    });

    test('real xz archive is not media', () {
      expect(
        MediaCompatService.sniffMime('https://c.example.com/a.xz', _xzMagic),
        isNot(startsWith('video/')),
      );
    });
  });

  group('extensionForMimeType', () {
    test('maps to player-friendly extensions', () {
      expect(MediaCompatService.extensionForMimeType('video/mp4'), 'mp4');
      expect(
          MediaCompatService.extensionForMimeType('video/quicktime'), 'mov');
      expect(MediaCompatService.extensionForMimeType('audio/mpeg'), 'mp3');
      expect(MediaCompatService.extensionForMimeType('audio/mp4'), 'm4a');
      expect(MediaCompatService.extensionForMimeType('x/unknown'), 'bin');
    });
  });
}
