import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/services/process_launch.dart';
import 'package:kode_agent_desktop/services/secret_scanner.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

Future<({Ed25519 algorithm, SimpleKeyPair keyPair, String publicKey})>
_newKeyPair() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return (
    algorithm: algorithm,
    keyPair: keyPair,
    publicKey: base64Encode(publicKey.bytes),
  );
}

Future<AppUpdate> _signed(
  AppUpdate update,
  Ed25519 algorithm,
  SimpleKeyPair keyPair,
) async {
  final signature = await algorithm.sign(
    utf8.encode(UpdateService.canonicalUpdatePayload(update)),
    keyPair: keyPair,
  );
  return AppUpdate(
    version: update.version,
    channel: update.channel,
    notes: update.notes,
    downloadUrl: update.downloadUrl,
    sha256: update.sha256,
    signature: base64Encode(signature.bytes),
  );
}

Map<String, dynamic> _toManifestEntry(AppUpdate update) => {
  'version': update.version,
  'channel': update.channel,
  'notes': update.notes,
  'download_url': update.downloadUrl,
  'sha256': update.sha256,
  'signature': update.signature,
};

Future<String> _sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Walks up from the test CWD until the package root (pubspec.yaml) is found,
/// so the signing CLI can resolve `package:kode_agent_desktop/...` imports.
String _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

AppUpdate _baseUpdate({String version = '2.0.0'}) => AppUpdate(
  version: version,
  channel: 'stable',
  notes: 'next release',
  downloadUrl:
      'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
      'v$version/YOUNZCODE-Setup-$version.exe',
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

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

  test('tanda tangan ditolak dengan kunci publik berbeda', () async {
    final signer = await _newKeyPair();
    final signed = await _signed(
      _baseUpdate(),
      signer.algorithm,
      signer.keyPair,
    );
    final other = await _newKeyPair();

    expect(
      await UpdateService.verifySignature(signed, other.publicKey),
      isFalse,
    );
  });

  test('tanda tangan ditolak bila sha256 atau versi dirusak', () async {
    final signer = await _newKeyPair();
    final signed = await _signed(
      _baseUpdate(),
      signer.algorithm,
      signer.keyPair,
    );

    // Tampered checksum under the same valid signature.
    final tamperedChecksum = AppUpdate(
      version: signed.version,
      channel: signed.channel,
      notes: signed.notes,
      downloadUrl: signed.downloadUrl,
      sha256:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      signature: signed.signature,
    );
    expect(
      await UpdateService.verifySignature(tamperedChecksum, signer.publicKey),
      isFalse,
    );

    // Tampered version under the same valid signature.
    final tamperedVersion = AppUpdate(
      version: '9.9.9',
      channel: signed.channel,
      notes: signed.notes,
      downloadUrl: signed.downloadUrl,
      sha256: signed.sha256,
      signature: signed.signature,
    );
    expect(
      await UpdateService.verifySignature(tamperedVersion, signer.publicKey),
      isFalse,
    );
  });

  test('check mengembalikan rilis lebih baru yang ditandatangani', () async {
    final signer = await _newKeyPair();
    final update = await _signed(
      _baseUpdate(version: '2.0.0'),
      signer.algorithm,
      signer.keyPair,
    );
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = UpdateService(
      signingPublicKeyBase64: signer.publicKey,
      httpClient: client,
    );

    final result = await service.check(currentVersion: '1.3.5');
    expect(result?.version, '2.0.0');
    expect(result?.signature, update.signature);
  });

  test('check mengembalikan null saat versi sama atau lebih tua', () async {
    final signer = await _newKeyPair();
    final update = await _signed(
      _baseUpdate(version: '1.3.5'),
      signer.algorithm,
      signer.keyPair,
    );
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = UpdateService(
      signingPublicKeyBase64: signer.publicKey,
      httpClient: client,
    );

    expect(await service.check(currentVersion: '1.3.5'), isNull);
    expect(await service.check(currentVersion: '2.0.0'), isNull);
  });

  test(
    'check menolak manifest yang dirusak sebelum menawarkan install',
    () async {
      final signer = await _newKeyPair();
      final update = await _signed(
        _baseUpdate(version: '2.0.0'),
        signer.algorithm,
        signer.keyPair,
      );
      // The entry is presented with a *different* (unsigned-for) checksum.
      final tampered = _toManifestEntry(update)
        ..['sha256'] =
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'channel': 'stable',
            'releases': [tampered],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final service = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: client,
      );

      await expectLater(
        service.check(currentVersion: '1.3.5'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'downloadAndVerify menolak tanda tangan tidak valid sebelum unduh',
    () async {
      final signer = await _newKeyPair();
      final other = await _newKeyPair();
      final signedByOther = await _signed(
        _baseUpdate(),
        other.algorithm,
        other.keyPair,
      );
      var downloads = 0;
      final client = MockClient((request) async {
        downloads++;
        return http.Response.bytes(utf8.encode('MZ'), 200);
      });
      final service = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: client,
      );

      await expectLater(
        service.downloadAndVerify(signedByOther, 'ignored'),
        throwsA(isA<StateError>()),
      );
      expect(downloads, 0);
    },
  );

  test(
    'downloadAndVerify menolak installer yang dirusak (SHA-256 tidak cocok)',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-update-');
      addTearDown(() => root.delete(recursive: true));
      final destination = '${root.path}${Platform.pathSeparator}setup.exe';

      final signer = await _newKeyPair();
      final signed = await _signed(
        _baseUpdate(),
        signer.algorithm,
        signer.keyPair,
      );
      final client = MockClient(
        (request) async => http.Response.bytes(
          utf8.encode('MZ fake installer that does not match the manifest'),
          200,
        ),
      );
      final service = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: client,
      );

      await expectLater(
        service.downloadAndVerify(signed, destination),
        throwsA(isA<StateError>()),
      );
      expect(File(destination).existsSync(), isFalse);
    },
  );

  test(
    'downloadAndVerify menulis installer bila tanda tangan dan SHA-256 cocok',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-update-');
      addTearDown(() => root.delete(recursive: true));
      final destination = '${root.path}${Platform.pathSeparator}setup.exe';

      final installerBytes = utf8.encode('MZ verified installer bytes');
      final signer = await _newKeyPair();
      final base = AppUpdate(
        version: '2.0.0',
        channel: 'stable',
        notes: 'next release',
        downloadUrl:
            'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
            'v2.0.0/YOUNZCODE-Setup-2.0.0.exe',
        sha256: await _sha256Hex(installerBytes),
      );
      final signed = await _signed(base, signer.algorithm, signer.keyPair);
      final client = MockClient(
        (request) async => http.Response.bytes(installerBytes, 200),
      );
      final service = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: client,
      );

      final file = await service.downloadAndVerify(signed, destination);
      expect(await file.readAsBytes(), installerBytes);
    },
  );

  test(
    'CLI sign_update.dart: manifest ditandatangani dan lolos verifikasi service',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-sign-e2e-');
      addTearDown(() => root.delete(recursive: true));
      final keyFile = File(
        '${root.path}${Platform.pathSeparator}signing_key.txt',
      );
      final manifestFile = File(
        '${root.path}${Platform.pathSeparator}updates.json',
      );

      // Keypair: write the Ed25519 seed (base64) exactly like update_keys.dart,
      // so the CLI can rebuild the keypair from it via newKeyPairFromSeed.
      final signer = await _newKeyPair();
      final seed = await signer.keyPair.extractPrivateKeyBytes();
      await keyFile.writeAsString(base64Encode(seed));

      const release = {
        'version': '2.0.0',
        'channel': 'stable',
        'notes': 'e2e signed release',
        'download_url':
            'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
            'v2.0.0/YOUNZCODE-Setup-2.0.0.exe',
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
      await manifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [release],
        }),
      );

      // Run the real signing CLI against the temp key + manifest.
      final resolved = resolveProcessLaunch('dart', [
        'run',
        'tool/sign_update.dart',
        keyFile.path,
        manifestFile.path,
      ]);
      final result = await Process.run(
        resolved.executable,
        resolved.arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(
        result.exitCode,
        0,
        reason: 'sign_update gagal: ${result.stdout}\n${result.stderr}',
      );

      // The tool wrote a signature back into the manifest; it must verify
      // against the public key that pairs with the seed it was given.
      final payload =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final update = AppUpdate.fromJson(
        (payload['releases'] as List).first as Map<String, dynamic>,
      );
      expect(update.signature, isNotEmpty);
      expect(
        await UpdateService.verifySignature(update, signer.publicKey),
        isTrue,
        reason: 'Tanda tangan dari CLI harus valid untuk kunci yang sama.',
      );

      // Full service path: check() serves the CLI-signed manifest and accepts it.
      final client = MockClient(
        (request) async => http.Response(
          await manifestFile.readAsString(),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final service = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: client,
      );
      final found = await service.check(currentVersion: '1.3.5');
      expect(found?.version, '2.0.0');
      expect(found?.signature, update.signature);

      // End-to-end tamper: alter the signed manifest and confirm check() rejects
      // it — the CLI-produced signature no longer covers the payload.
      final tampered =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      (tampered['releases'] as List).first['sha256'] =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      await manifestFile.writeAsString(jsonEncode(tampered));
      final tamperClient = MockClient(
        (request) async => http.Response(
          await manifestFile.readAsString(),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final tamperService = UpdateService(
        signingPublicKeyBase64: signer.publicKey,
        httpClient: tamperClient,
      );
      await expectLater(
        tamperService.check(currentVersion: '1.3.5'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('downloadAndVerify menolak host download di luar allowlist', () async {
    final update = AppUpdate(
      version: '2.0.0',
      channel: 'stable',
      notes: '',
      downloadUrl: 'https://cdn.evil.test/YOUNZCODE-Setup-2.0.0.exe',
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    await expectLater(
      const UpdateService().downloadAndVerify(update, 'ignored'),
      throwsA(isA<FormatException>()),
    );
  });
}
