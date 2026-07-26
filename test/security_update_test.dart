import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/secret_scanner.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

void main() {
  test('secret scanner meredaksi credential umum', () {
    const source = 'api_key=sk-abcdefghijklmnopqrstuvwxyz123456\n';
    final redacted = SecretScanner.redact(source);

    expect(redacted, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz123456')));
    expect(redacted, contains('REDACTED'));
  });

  test('version comparison memilih versi lebih baru', () {
    expect(UpdateService.compareVersions('1.2.0', '1.1.9'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0.1+4', '1.0.1+2'), 0);
    expect(UpdateService.compareVersions('1.0.0', '2.0.0'), lessThan(0));
  });

  test('check menolak manifest non-HTTPS', () async {
    await expectLater(
      const UpdateService().check(
        manifestUrl: 'http://example.test/manifest.json',
        channel: 'stable',
        currentVersion: '1.0.0',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('downloadAndVerify menolak URL download non-HTTPS', () async {
    const update = AppUpdate(
      version: '2.0.0',
      channel: 'stable',
      notes: '',
      downloadUrl: 'http://example.test/app.exe',
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    await expectLater(
      const UpdateService().downloadAndVerify(update, 'ignored'),
      throwsA(isA<FormatException>()),
    );
  });
}
