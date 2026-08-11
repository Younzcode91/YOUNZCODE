import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

/// Backs up an Ed25519 release-signing private key.
///
/// Usage:
///   dart run tool/backup_signing_key.dart [privateKeyPath]
///     [--receipt <path>] [--vault-entry <path>]
///
/// Reads the seed at the given path (default
/// tool/signing/update_signing_private_key.txt), derives the public key and
/// verifies it against the keys baked into UpdateService, self-tests the
/// keypair (sign/verify round-trip), writes a complete copy-paste entry for a
/// password manager, and prints it to stdout. Point it at any candidate
/// backup file to verify that backup (it prints the same fingerprint / public
/// key comparison).
///
/// It also upserts a commit-safe RECEIPT (default
/// .ci/signing-backup-receipt.json): per-key fingerprint + timestamp, never
/// key material. The release gate (tool/check_backup_receipt.dart) fails when
/// this receipt is missing, stale, or out of sync with the trusted keys, so
/// commit the receipt alongside each backup. Only a keypair that passes the
/// self-test is recorded.
Future<void> main(List<String> args) async {
  final root = _packageRoot();
  final defaultKeyPath =
      'tool${Platform.pathSeparator}signing'
      '${Platform.pathSeparator}update_signing_private_key.txt';
  final defaultReceipt =
      '.ci${Platform.pathSeparator}signing-backup-receipt.json';

  var privateKeyPath = defaultKeyPath;
  var receiptPath = defaultReceipt;
  var vaultEntryPath =
      'tool${Platform.pathSeparator}signing'
      '${Platform.pathSeparator}backup'
      '${Platform.pathSeparator}signing_key_vault_entry.txt';
  final positionals = <String>[];
  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--receipt':
        if (index + 1 >= args.length) {
          stderr.writeln('--receipt membutuhkan path.');
          exitCode = 1;
          return;
        }
        receiptPath = args[++index];
      case '--vault-entry':
        if (index + 1 >= args.length) {
          stderr.writeln('--vault-entry membutuhkan path.');
          exitCode = 1;
          return;
        }
        vaultEntryPath = args[++index];
      default:
        positionals.add(args[index]);
    }
  }
  if (positionals.isNotEmpty) privateKeyPath = positionals.first;

  final file = File(privateKeyPath);
  if (!file.existsSync()) {
    stderr.writeln('Private key tidak ditemukan: $privateKeyPath');
    stderr.writeln('Generate dulu dengan: dart run tool/update_keys.dart');
    exitCode = 1;
    return;
  }

  final keyBase64 = file.readAsStringSync().trim();
  final seed = base64Decode(keyBase64);
  if (seed.length != 32) {
    stderr.writeln('Seed harus 32 byte (base64), dapat ${seed.length} byte.');
    exitCode = 1;
    return;
  }

  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  final publicKeyBase64 = base64Encode(publicKey.bytes);
  final fingerprint = (await _sha256(
    publicKey.bytes,
  )).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  // Self-test: sign and verify a probe so a corrupt or partial backup is
  // caught before it is relied on.
  final probe = utf8.encode('backup-probe-$fingerprint');
  final signature = await Ed25519().sign(probe, keyPair: keyPair);
  final probeOk = await Ed25519().verify(
    probe,
    signature: Signature(signature.bytes, publicKey: publicKey),
  );
  final matchesBakedIn = updateSigningPublicKeys.contains(publicKeyBase64);

  final now = DateTime.now().toUtc().toIso8601String();
  final entry =
      '''
========================================================================
YOUNZCODE RELEASE-SIGNING KEY - BACKUP ENTRY
========================================================================
Created      : $now (UTC)
Purpose      : Signs updates.json release manifests (Ed25519)
Source file  : $privateKeyPath
Fingerprint  : ${fingerprint.substring(0, 16)}... (sha256 of public key)
Public key   : $publicKeyBase64
  == updateSigningPublicKeys (update_service.dart): ${matchesBakedIn ? 'YES' : 'NO - PERIKSA!'}
Self-test    : sign/verify round-trip ${probeOk ? 'PASS' : 'FAIL'}

PRIVATE KEY (base64, 32-byte seed) - RAHASIA, this is the secret:
$keyBase64
---------------------------------------------------------------------
If lost: regenerate and re-distribute - see docs/update-signing.md
========================================================================
''';

  final backupDir = Directory(File(vaultEntryPath).parent.path);
  await backupDir.create(recursive: true);
  await File(vaultEntryPath).writeAsString(entry);
  stdout.writeln(entry);
  stdout.writeln('Backup entry ditulis ke: $vaultEntryPath');

  // Only a self-test-passing keypair is recorded in the receipt.
  if (probeOk) {
    await _upsertReceipt(root, receiptPath, publicKeyBase64, fingerprint);
    stdout.writeln(
      'Receipt diperbarui: $receiptPath '
      '(commit file ini bersama backup agar gate rilis lulus)',
    );
  }

  if (!matchesBakedIn) {
    stdout.writeln(
      'PERINGATAN: public key backup TIDAK ada di updateSigningPublicKeys.',
    );
  }
  if (!probeOk) {
    stderr.writeln('SELF-TEST GAGAL: keypair tidak valid, jangan dipakai.');
    exitCode = 1;
  }
}

/// Adds/updates the entry for [publicKeyBase64] in the commit-safe receipt.
/// The receipt holds only fingerprints and timestamps — never key material.
Future<void> _upsertReceipt(
  String packageRoot,
  String receiptPath,
  String publicKeyBase64,
  String fingerprint,
) async {
  final file = File(receiptPath);
  Map<String, dynamic> payload;
  if (file.existsSync()) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      payload = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      payload = {};
    }
  } else {
    payload = {};
  }
  final keys = payload['keys'];
  final map = keys is Map<String, dynamic> ? keys : <String, dynamic>{};
  map[publicKeyBase64] = {
    'fingerprint': fingerprint,
    'backedUpAt': DateTime.now().toUtc().toIso8601String(),
  };
  payload['keys'] = map;
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
}

/// Walks up from the CWD until the package root (pubspec.yaml) is found.
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

Future<List<int>> _sha256(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes;
