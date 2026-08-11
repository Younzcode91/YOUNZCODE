import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

import 'tool_runner.dart';

Future<String> _fingerprint(String publicKeyBase64) async {
  final digest = await Sha256().hash(base64Decode(publicKeyBase64));
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Walks up from the test CWD until the package root (pubspec.yaml) is found,
/// so the CLI tools can resolve `package:kode_agent_desktop/...` imports.
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

Future<ProcessResult> _runCheck(String receiptPath, {int maxAgeDays = 30}) {
  final (executable, arguments) = toolLaunch(
    'tool/check_backup_receipt.dart',
    ['--receipt', receiptPath, '--max-age-days', '$maxAgeDays'],
  );
  return Process.run(
    executable,
    arguments,
    workingDirectory: _packageRoot(),
    runInShell: false,
  ).timeout(const Duration(seconds: 90));
}

String _receiptJson(Map<String, dynamic> entries) =>
    const JsonEncoder.withIndent('  ').convert({'keys': entries});

String _entry(String fingerprint, {int daysAgo = 0}) => jsonEncode({
  'fingerprint': fingerprint,
  'backedUpAt': DateTime.now()
      .toUtc()
      .subtract(Duration(days: daysAgo))
      .toIso8601String(),
});

void main() {
  test('gate gagal bila receipt tidak ada', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final missing = '${root.path}${Platform.pathSeparator}nope.json';

    final result = await _runCheck(missing);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('tidak ada receipt backup'));
  });

  test('gate gagal bila receipt bukan JSON valid', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}receipt.json');
    await file.writeAsString('{not json');

    final result = await _runCheck(file.path);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('bukan JSON valid'));
  });

  test(
    'gate lulus bila semua kunci yang dipercaya punya receipt segar',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}receipt.json');
      final entries = <String, dynamic>{};
      for (final key in updateSigningPublicKeys) {
        entries[key] = jsonDecode(_entry(await _fingerprint(key)));
      }
      await file.writeAsString(_receiptJson(entries));

      final result = await _runCheck(file.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS'));
    },
  );

  test('gate gagal bila salah satu kunci tidak ada di receipt', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}receipt.json');
    // Receipt only records a dummy key, not the trusted one.
    final dummy = await Ed25519().newKeyPair();
    final dummyPub = base64Encode((await dummy.extractPublicKey()).bytes);
    await file.writeAsString(
      _receiptJson({
        dummyPub: jsonDecode(_entry(await _fingerprint(dummyPub))),
      }),
    );

    final result = await _runCheck(file.path);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('TIDAK ADA DI RECEIPT'));
  });

  test('gate gagal bila fingerprint receipt tidak cocok', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}receipt.json');
    final key = updateSigningPublicKeys.first;
    // Wrong fingerprint (all zeros) for the real key.
    await file.writeAsString(
      _receiptJson({
        key: jsonDecode(
          _entry(
            '0000000000000000000000000000000000000000000000000000000000000000',
          ),
        ),
      }),
    );

    final result = await _runCheck(file.path);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('FINGERPRINT TIDAK COCOK'));
  });

  test('gate gagal bila backup lebih tua dari jendela kesegaran', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}receipt.json');
    final key = updateSigningPublicKeys.first;
    await file.writeAsString(
      _receiptJson({
        key: jsonDecode(_entry(await _fingerprint(key), daysAgo: 40)),
      }),
    );

    final result = await _runCheck(file.path, maxAgeDays: 30);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('BACKUP STALE'));
  });

  test(
    'backup_signing_key.dart menulis receipt untuk kunci yang diverifikasi',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-backup-');
      addTearDown(() => root.delete(recursive: true));
      final sep = Platform.pathSeparator;
      final keyFile = File('${root.path}${sep}key.txt');
      final receiptFile = File('${root.path}${sep}receipt.json');
      final vaultFile = File('${root.path}${sep}vault_entry.txt');

      final keyPair = await Ed25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyBase64 = base64Encode(publicKey.bytes);
      final seed = await keyPair.extractPrivateKeyBytes();
      await keyFile.writeAsString(base64Encode(seed));

      final (executable, arguments) = toolLaunch(
        'tool/backup_signing_key.dart',
        [
          keyFile.path,
          '--receipt',
          receiptFile.path,
          '--vault-entry',
          vaultFile.path,
        ],
      );
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: _packageRoot(),
        runInShell: false,
      ).timeout(const Duration(seconds: 90));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      // The vault entry was written and the receipt records the key.
      expect(vaultFile.existsSync(), isTrue);
      final receipt =
          jsonDecode(await receiptFile.readAsString()) as Map<String, dynamic>;
      final keys = receipt['keys'] as Map<String, dynamic>;
      final entry = keys[publicKeyBase64] as Map<String, dynamic>;
      expect(entry['fingerprint'], await _fingerprint(publicKeyBase64));
      expect(DateTime.tryParse('${entry['backedUpAt']}'), isNotNull);

      // That receipt satisfies the gate for this key when the key is trusted.
      final gate = await _runCheck(receiptFile.path);
      // The key is not in the baked-in list, so the gate still fails on the
      // real trusted key — but the temp key itself is recorded and fresh.
      expect(gate.exitCode, 1);
      expect(gate.stderr, contains('TIDAK ADA DI RECEIPT'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
