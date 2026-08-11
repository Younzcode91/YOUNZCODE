import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/services/secret_scanner.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

import 'tool_runner.dart';

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
  if (update.signatures.isNotEmpty)
    'signatures': [
      for (final sig in update.signatures)
        {'public_key': sig.publicKey, 'signature': sig.signature},
    ],
};

/// Signs with every key in [signers], producing a structured per-key
/// signature list plus the legacy single field (first key).
Future<AppUpdate> _signedWithKeys(
  AppUpdate update,
  List<({Ed25519 algorithm, SimpleKeyPair keyPair, String publicKey})> signers,
) async {
  final signatures = <UpdateSignature>[];
  for (final signer in signers) {
    final signature = await signer.algorithm.sign(
      utf8.encode(UpdateService.canonicalUpdatePayload(update)),
      keyPair: signer.keyPair,
    );
    signatures.add(
      UpdateSignature(
        publicKey: signer.publicKey,
        signature: base64Encode(signature.bytes),
      ),
    );
  }
  return AppUpdate(
    version: update.version,
    channel: update.channel,
    notes: update.notes,
    downloadUrl: update.downloadUrl,
    sha256: update.sha256,
    signature: signatures.isEmpty ? '' : signatures.first.signature,
    signatures: signatures,
  );
}

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

  test(
    'key ring: diterima bila salah satu kunci yang dipercaya menandatangani',
    () async {
      final keyA = await _newKeyPair();
      final keyB = await _newKeyPair();
      final other = await _newKeyPair();

      final signed = await _signedWithKeys(_baseUpdate(), [keyA, keyB]);

      // Either trusted key alone accepts its own signature.
      expect(
        await UpdateService.verifySignatureWithAny(signed, [keyA.publicKey]),
        isTrue,
      );
      expect(
        await UpdateService.verifySignatureWithAny(signed, [keyB.publicKey]),
        isTrue,
      );
      // An untrusted key alone rejects; a mixed ring accepts via its member.
      expect(
        await UpdateService.verifySignatureWithAny(signed, [other.publicKey]),
        isFalse,
      );
      expect(
        await UpdateService.verifySignatureWithAny(signed, [
          other.publicKey,
          keyB.publicKey,
        ]),
        isTrue,
      );
      // Legacy single-key verifier still works (legacy field = first key).
      expect(
        await UpdateService.verifySignature(signed, keyA.publicKey),
        isTrue,
      );
      expect(
        await UpdateService.verifySignature(signed, keyB.publicKey),
        isFalse,
      );
    },
  );

  test('matchingSigningKey melaporkan kunci yang memverifikasi', () async {
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();
    final dual = await _signedWithKeys(_baseUpdate(), [keyA, keyB]);

    expect(
      await UpdateService.matchingSigningKey(dual, [keyA.publicKey]),
      keyA.publicKey,
    );
    expect(
      await UpdateService.matchingSigningKey(dual, [keyB.publicKey]),
      keyB.publicKey,
    );
    expect(
      await UpdateService.matchingSigningKey(dual, [
        keyA.publicKey,
        keyB.publicKey,
      ]),
      keyA.publicKey,
    );
    final stranger = await _newKeyPair();
    expect(
      await UpdateService.matchingSigningKey(dual, [stranger.publicKey]),
      isNull,
    );
    expect(await UpdateService.matchingSigningKey(dual, const []), isNull);

    // Legacy single signature matches whichever trusted key validates it.
    final single = await _signed(_baseUpdate(), keyA.algorithm, keyA.keyPair);
    expect(
      await UpdateService.matchingSigningKey(single, [
        keyB.publicKey,
        keyA.publicKey,
      ]),
      keyA.publicKey,
    );
  });

  test('check melaporkan kunci yang memverifikasi via onVerified', () async {
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
    String? reported;
    final service = UpdateService(
      signingPublicKeyBase64: signer.publicKey,
      httpClient: client,
    );
    final found = await service.check(
      currentVersion: '1.3.5',
      onVerified: (key) => reported = key,
    );
    expect(found?.version, '2.0.0');
    expect(reported, signer.publicKey);
  });

  test('onVerified null saat enforcement tanda tangan dinonaktifkan', () async {
    final unsigned = _baseUpdate(version: '2.0.0');
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(unsigned)],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    String? reported = 'sentinel';
    final service = UpdateService(
      signingPublicKeys: const [],
      signingPublicKeyBase64: '',
      httpClient: client,
    );
    final found = await service.check(
      currentVersion: '1.3.5',
      onVerified: (key) => reported = key,
    );
    expect(found?.version, '2.0.0');
    expect(reported, isNull);
  });

  test('check tidak memanggil onVerified bila tanda tangan ditolak', () async {
    final signer = await _newKeyPair();
    final update = await _signed(
      _baseUpdate(version: '2.0.0'),
      signer.algorithm,
      signer.keyPair,
    );
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
    var calls = 0;
    final service = UpdateService(
      signingPublicKeyBase64: signer.publicKey,
      httpClient: client,
    );
    await expectLater(
      service.check(currentVersion: '1.3.5', onVerified: (_) => calls++),
      throwsA(isA<StateError>()),
    );
    expect(calls, 0);
  });

  test('check melaporkan latensi via onLatency (jaringan lambat)', () async {
    final signer = await _newKeyPair();
    final update = await _signed(
      _baseUpdate(version: '2.0.0'),
      signer.algorithm,
      signer.keyPair,
    );
    final client = MockClient((request) async {
      // Simulasikan koneksi lambat: respons manifest butuh 300 ms.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    Duration? reported;
    final service = UpdateService(
      signingPublicKeyBase64: signer.publicKey,
      httpClient: client,
    );
    final found = await service.check(
      currentVersion: '1.3.5',
      onLatency: (elapsed) => reported = elapsed,
    );
    expect(found?.version, '2.0.0');
    expect(reported, isNotNull);
    expect(reported!.inMilliseconds, greaterThanOrEqualTo(300));
  });

  test('onLatency tetap dipanggil saat check gagal', () async {
    final client = MockClient(
      (request) async => http.Response('server error', 500),
    );
    Duration? reported;
    final service = UpdateService(
      signingPublicKeyBase64: '',
      signingPublicKeys: const [],
      httpClient: client,
    );
    await expectLater(
      service.check(
        currentVersion: '1.3.5',
        onLatency: (elapsed) => reported = elapsed,
      ),
      throwsA(isA<HttpException>()),
    );
    // Latensi dilaporkan walau gagal — kasus jaringan lambat justru penting.
    expect(reported, isNotNull);
  });

  test('key ring: tanda tangan lama (satu kunci) diterima oleh kunci mana pun '
      'yang dipercaya', () async {
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();
    final signed = await _signed(_baseUpdate(), keyA.algorithm, keyA.keyPair);

    expect(
      await UpdateService.verifySignatureWithAny(signed, [
        keyB.publicKey,
        keyA.publicKey,
      ]),
      isTrue,
    );
    expect(
      await UpdateService.verifySignatureWithAny(signed, [keyB.publicKey]),
      isFalse,
    );
  });

  test(
    'key ring: daftar kunci kosong menonaktifkan pemeriksaan tanda tangan',
    () async {
      final unsigned = _baseUpdate(version: '2.0.0');
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'channel': 'stable',
            'releases': [_toManifestEntry(unsigned)],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final service = UpdateService(
        signingPublicKeys: const [],
        signingPublicKeyBase64: '',
        httpClient: client,
      );

      final found = await service.check(currentVersion: '1.3.5');
      expect(found?.version, '2.0.0');
    },
  );

  test('rotasi kunci: rilis transisi diterima klien lama dan baru', () async {
    final oldKey = await _newKeyPair();
    final newKey = await _newKeyPair();

    UpdateService serviceWith(List<String> trusted, AppUpdate release) {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'channel': 'stable',
            'releases': [_toManifestEntry(release)],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      return UpdateService(signingPublicKeys: trusted, httpClient: client);
    }

    // Transition release signed by BOTH keys: old clients (trusting only the
    // old key) and new clients (trusting both) must both accept it, so the
    // rotation ships through the normal update flow.
    final dual = await _signedWithKeys(_baseUpdate(version: '2.0.0'), [
      oldKey,
      newKey,
    ]);
    for (final trusted in [
      [oldKey.publicKey],
      [oldKey.publicKey, newKey.publicKey],
    ]) {
      final found = await serviceWith(
        trusted,
        dual,
      ).check(currentVersion: '1.3.5');
      expect(found?.version, '2.0.0');
    }

    // After the fleet has caught up, sign with the new key only.
    final newOnly = await _signedWithKeys(_baseUpdate(version: '2.0.1'), [
      newKey,
    ]);
    final newClient = await serviceWith([
      oldKey.publicKey,
      newKey.publicKey,
    ], newOnly).check(currentVersion: '1.3.5');
    expect(newClient?.version, '2.0.1');

    // A client stuck on the old key alone rejects the new-only release
    // instead of offering an unverifiable install.
    await expectLater(
      serviceWith([oldKey.publicKey], newOnly).check(currentVersion: '1.3.5'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'pemulihan kunci hilang: tanda tangan lama ditolak, baru diterima',
    () async {
      // Kunci lama = "hilang"; kunci baru = hasil pemulihan.
      final lostKey = await _newKeyPair();
      final recoveryKey = await _newKeyPair();

      // Manifest lama (sudah beredar) ditandatangani dengan kunci yang hilang.
      final oldRelease = await _signed(
        _baseUpdate(version: '2.0.0'),
        lostKey.algorithm,
        lostKey.keyPair,
      );

      // "Rebake": build baru hanya memercayai kunci pemulihan.
      final recoveryPub = recoveryKey.publicKey;
      expect(
        await UpdateService.verifySignatureWithAny(oldRelease, [recoveryPub]),
        isFalse,
      );

      // Via check(): manifest lama ditolak, tidak pernah ditawarkan ke user.
      final oldClient = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'channel': 'stable',
            'releases': [_toManifestEntry(oldRelease)],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final serviceOld = UpdateService(
        signingPublicKeys: [recoveryPub],
        httpClient: oldClient,
      );
      await expectLater(
        serviceOld.check(currentVersion: '1.3.5'),
        throwsA(isA<StateError>()),
      );

      // Rilis baru ditandatangani dengan kunci pemulihan -> diterima penuh.
      final newRelease = await _signed(
        _baseUpdate(version: '2.1.0'),
        recoveryKey.algorithm,
        recoveryKey.keyPair,
      );
      expect(
        await UpdateService.verifySignatureWithAny(newRelease, [recoveryPub]),
        isTrue,
      );
      final newClient = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'channel': 'stable',
            'releases': [_toManifestEntry(newRelease)],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final serviceNew = UpdateService(
        signingPublicKeys: [recoveryPub],
        httpClient: newClient,
      );
      final found = await serviceNew.check(currentVersion: '2.0.0');
      expect(found?.version, '2.1.0');
    },
  );

  test(
    'pemulihan kunci hilang end-to-end: update_keys + sign_update + verifikasi',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final sep = Platform.pathSeparator;
      final newKeyFile = File('${root.path}${sep}recovery_key.txt');
      final oldManifestFile = File('${root.path}${sep}old_updates.json');
      final newManifestFile = File('${root.path}${sep}new_updates.json');

      // Manifest lama yang sudah beredar, ditandatangani kunci yang "hilang".
      final lostKey = await _newKeyPair();
      final oldRelease = await _signed(
        _baseUpdate(version: '2.0.0'),
        lostKey.algorithm,
        lostKey.keyPair,
      );
      await oldManifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(oldRelease)],
        }),
      );

      // Pemulihan: generate keypair baru dengan tool sungguhan.
      final (genExecutable, genArguments) = toolLaunch(
        'tool/update_keys.dart',
        [newKeyFile.path],
      );
      final genResult = await Process.run(
        genExecutable,
        genArguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(
        genResult.exitCode,
        0,
        reason: 'update_keys gagal: ${genResult.stdout}\n${genResult.stderr}',
      );
      expect(newKeyFile.existsSync(), isTrue);

      // Public key pemulihan diturunkan dari seed yang ditulis tool.
      final recoveryKeyPair = await Ed25519().newKeyPairFromSeed(
        base64Decode(newKeyFile.readAsStringSync().trim()),
      );
      final recoveryPub = base64Encode(
        (await recoveryKeyPair.extractPublicKey()).bytes,
      );

      // "Rebake": build baru memercayai kunci pemulihan SAJA; manifest lama
      // (kunci hilang) ditolak sebelum sempat ditawarkan.
      final oldClient = MockClient(
        (request) async => http.Response(
          await oldManifestFile.readAsString(),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await expectLater(
        UpdateService(
          signingPublicKeys: [recoveryPub],
          httpClient: oldClient,
        ).check(currentVersion: '1.3.5'),
        throwsA(isA<StateError>()),
      );

      // Rilis baru: manifest ditandatangani dengan kunci pemulihan via CLI.
      await newManifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [
            {
              'version': '2.1.0',
              'channel': 'stable',
              'notes': 'release pasca-recovery',
              'download_url':
                  'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
                  'v2.1.0/YOUNZCODE-Setup-2.1.0.exe',
              'sha256':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            },
          ],
        }),
      );
      final (signExecutable, signArguments) = toolLaunch(
        'tool/sign_update.dart',
        [newKeyFile.path, newManifestFile.path],
      );
      final signResult = await Process.run(
        signExecutable,
        signArguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(
        signResult.exitCode,
        0,
        reason: 'sign_update gagal: ${signResult.stdout}\n${signResult.stderr}',
      );

      // Build pasca-recovery menerima rilis baru yang ditandatangani kunci
      // pemulihan, dan menolak tanda tangan lama dari kunci yang hilang.
      final newClient = MockClient(
        (request) async => http.Response(
          await newManifestFile.readAsString(),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final recovered = UpdateService(
        signingPublicKeys: [recoveryPub],
        httpClient: newClient,
      );
      final found = await recovered.check(currentVersion: '2.0.0');
      expect(found?.version, '2.1.0');
      expect(
        await UpdateService.verifySignatureWithAny(oldRelease, [recoveryPub]),
        isFalse,
      );
      final signedPayload =
          jsonDecode(await newManifestFile.readAsString())
              as Map<String, dynamic>;
      final signedUpdate = AppUpdate.fromJson(
        (signedPayload['releases'] as List).first as Map<String, dynamic>,
      );
      expect(
        await UpdateService.verifySignature(signedUpdate, recoveryPub),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'jalur cadangan: kunci cadangan yang sudah dipercaya menjaga update tetap jalan',
    () async {
      final mainKey = await _newKeyPair(); // kemudian hilang
      final spareKey = await _newKeyPair(); // sudah dipercaya fleet

      // Rilis transisi terakhir ditandatangani dengan KEDUA kunci (praktik
      // yang disarankan: simpan >= 2 kunci di updateSigningPublicKeys).
      final transition = await _signedWithKeys(_baseUpdate(version: '2.0.0'), [
        mainKey,
        spareKey,
      ]);

      // Kunci utama hilang -> build baru memercayai kunci cadangan saja;
      // rilis transisi tetap diterima lewat tanda tangan cadangan.
      expect(
        await UpdateService.verifySignatureWithAny(transition, [
          spareKey.publicKey,
        ]),
        isTrue,
      );
      // Rilis berikutnya ditandatangani kunci cadangan saja -> diterima.
      final next = await _signed(
        _baseUpdate(version: '2.1.0'),
        spareKey.algorithm,
        spareKey.keyPair,
      );
      expect(
        await UpdateService.verifySignatureWithAny(next, [spareKey.publicKey]),
        isTrue,
      );
      // Tanda tangan hanya-kunci-utama (tanpa cadangan) -> ditolak setelah
      // kunci utama hilang.
      final mainOnly = await _signed(
        _baseUpdate(version: '2.0.1'),
        mainKey.algorithm,
        mainKey.keyPair,
      );
      expect(
        await UpdateService.verifySignatureWithAny(mainOnly, [
          spareKey.publicKey,
        ]),
        isFalse,
      );
    },
  );

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
      final (executable, arguments) = toolLaunch('tool/sign_update.dart', [
        keyFile.path,
        manifestFile.path,
      ]);
      final result = await Process.run(
        executable,
        arguments,
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
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'CLI sign_update.dart --key: multi-tanda tangan untuk rotasi kunci',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'younzcode-sign-ring-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keyAFile = File('${root.path}${Platform.pathSeparator}old_key.txt');
      final keyBFile = File('${root.path}${Platform.pathSeparator}new_key.txt');
      final manifestFile = File(
        '${root.path}${Platform.pathSeparator}updates.json',
      );

      final keyA = await _newKeyPair();
      final keyB = await _newKeyPair();
      await keyAFile.writeAsString(
        base64Encode(await keyA.keyPair.extractPrivateKeyBytes()),
      );
      await keyBFile.writeAsString(
        base64Encode(await keyB.keyPair.extractPrivateKeyBytes()),
      );
      await manifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [
            {
              'version': '2.0.0',
              'channel': 'stable',
              'notes': 'rotated release',
              'download_url':
                  'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
                  'v2.0.0/YOUNZCODE-Setup-2.0.0.exe',
              'sha256':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            },
          ],
        }),
      );

      // Sign with both keys; the first (old) key keeps the legacy field.
      final (executable, arguments) = toolLaunch('tool/sign_update.dart', [
        '--key',
        keyAFile.path,
        '--key',
        keyBFile.path,
        manifestFile.path,
      ]);
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(
        result.exitCode,
        0,
        reason: 'sign_update gagal: ${result.stdout}\n${result.stderr}',
      );

      final payload =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final update = AppUpdate.fromJson(
        (payload['releases'] as List).first as Map<String, dynamic>,
      );
      expect(update.signatures, hasLength(2));
      expect(
        update.signatures.map((sig) => sig.publicKey),
        containsAll([keyA.publicKey, keyB.publicKey]),
      );
      // Legacy single field mirrors the first key's signature.
      expect(update.signature, update.signatures.first.signature);

      // Both keys' signatures verify against the paired public keys.
      expect(
        await UpdateService.verifySignatureWithAny(update, [keyA.publicKey]),
        isTrue,
      );
      expect(
        await UpdateService.verifySignatureWithAny(update, [keyB.publicKey]),
        isTrue,
      );
      expect(
        await UpdateService.verifySignature(update, keyA.publicKey),
        isTrue,
      );

      // Full service path: a new client trusting both keys accepts it, and a
      // client trusting only the old key accepts it via the legacy field.
      for (final trusted in [
        [keyA.publicKey, keyB.publicKey],
        [keyA.publicKey],
      ]) {
        final client = MockClient(
          (request) async => http.Response(
            await manifestFile.readAsString(),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        final service = UpdateService(
          signingPublicKeys: trusted,
          httpClient: client,
        );
        final found = await service.check(currentVersion: '1.3.5');
        expect(found?.version, '2.0.0');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
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

  test(
    'e2e tool: manifest lokal yang valid lulus verifikasi',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-e2e-');
      addTearDown(() => root.delete(recursive: true));
      final key = await _newKeyPair();
      final update = await _signed(
        _baseUpdate(version: '2.0.0'),
        key.algorithm,
        key.keyPair,
      );
      final manifestFile = File(
        '${root.path}${Platform.pathSeparator}updates.json',
      );
      await manifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
      );

      final (executable, arguments) = toolLaunch('tool/e2e_update_check.dart', [
        '--manifest',
        manifestFile.path,
        '--trust',
        key.publicKey,
        '--current-version',
        '1.3.5',
        '--expect-version',
        '2.0.0',
      ]);
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(
        result.exitCode,
        0,
        reason: 'e2e_update_check gagal: ${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('LOCAL: PASS'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'e2e tool: manifest lokal yang dirusak ditolak',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-e2e-');
      addTearDown(() => root.delete(recursive: true));
      final key = await _newKeyPair();
      final update = await _signed(
        _baseUpdate(version: '2.0.0'),
        key.algorithm,
        key.keyPair,
      );
      final manifestFile = File(
        '${root.path}${Platform.pathSeparator}updates.json',
      );
      await manifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
      ); // Tamper dengan mengubah sha256 setelah penandatanganan.
      final tampered =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      ((tampered['releases'] as List).first as Map<String, dynamic>)['sha256'] =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      await manifestFile.writeAsString(jsonEncode(tampered));

      final (executable, arguments) = toolLaunch('tool/e2e_update_check.dart', [
        '--manifest',
        manifestFile.path,
        '--trust',
        key.publicKey,
        '--current-version',
        '1.3.5',
      ]);
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('LOCAL: FAIL'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'e2e tool: versi tak sesuai --expect-version ditolak',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-e2e-');
      addTearDown(() => root.delete(recursive: true));
      final key = await _newKeyPair();
      final update = await _signed(
        _baseUpdate(version: '2.0.0'),
        key.algorithm,
        key.keyPair,
      );
      final manifestFile = File(
        '${root.path}${Platform.pathSeparator}updates.json',
      );
      await manifestFile.writeAsString(
        jsonEncode({
          'channel': 'stable',
          'releases': [_toManifestEntry(update)],
        }),
      );

      final (executable, arguments) = toolLaunch('tool/e2e_update_check.dart', [
        '--manifest',
        manifestFile.path,
        '--trust',
        key.publicKey,
        '--current-version',
        '1.3.5',
        '--expect-version',
        '9.9.9',
      ]);
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('9.9.9'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
