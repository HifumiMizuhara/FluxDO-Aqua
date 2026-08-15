import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/download_service.dart';

void main() {
  test('sanitizeFileName removes path separators and control characters', () {
    expect(
      DownloadService.sanitizeFileName('..\\secret/target\u0000.txt'),
      '.._secret_target.txt',
    );
  });

  test('resolveFileName sanitizes suggested filenames', () {
    expect(
      DownloadService.resolveFileName(
        'https://linux.do/uploads/ignored.bin',
        suggestedFilename: '../report.pdf',
      ),
      '.._report.pdf',
    );
  });
}
