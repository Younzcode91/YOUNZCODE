import 'dart:convert';

import 'package:cryptography/cryptography.dart';
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

  test(
    'tanda tangan Ed25519 diterima jika valid, ditolak jika dirusak',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final pubB64 = base64Encode(publicKey.bytes);

      const base = AppUpdate(
        version: '2.0.0',
        channel: 'stable',
        notes: '',
        downloadUrl: 'https://dl.younz.test/app.exe',
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final signature = await algorithm.sign(
        utf8.encode(UpdateService.canonicalUpdatePayload(base)),
        keyPair: keyPair,
      );
      final signed = AppUpdate(
        version: base.version,
        channel: base.channel,
        notes: base.notes,
        downloadUrl: base.downloadUrl,
        sha256: base.sha256,
        signature: base64Encode(signature.bytes),
      );

      expect(await UpdateService.verifySignature(signed, pubB64), isTrue);
      // No signature at all → rejected.
      expect(await UpdateService.verifySignature(base, pubB64), isFalse);
      // Tampered download URL under the same signature → rejected.
      final tampered = AppUpdate(
        version: base.version,
        channel: base.channel,
        notes: base.notes,
        downloadUrl: 'https://evil.test/app.exe',
        sha256: base.sha256,
        signature: signed.signature,
      );
      expect(await UpdateService.verifySignature(tampered, pubB64), isFalse);
    },
  );

  test('host pinning menolak host di luar allowlist', () async {
    await expectLater(
      const UpdateService(allowedHosts: ['releases.younz.test']).check(
        manifestUrl: 'https://cdn.evil.test/manifest.json',
        channel: 'stable',
        currentVersion: '1.0.0',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
