import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

/// Release gate: fails when the signing-key backup receipt is missing, stale,
/// or out of sync with the trusted keys baked into the app.
///
/// Usage:
///   dart run tool/check_backup_receipt.dart
///     [--receipt <path>] [--max-age-days <days>]
///
/// Defaults: receipt at .ci/signing-backup-receipt.json (written by
/// tool/backup_signing_key.dart), freshness window 30 days. For every key in
/// [updateSigningPublicKeys] the receipt must contain an entry with a matching
/// fingerprint recorded within the window; otherwise it exits 1 with
/// instructions — run this job before any release is signed.
Future<void> main(List<String> args) async {
  var receiptPath = '.ci${Platform.pathSeparator}signing-backup-receipt.json';
  var maxAgeDays = 30;
  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--receipt':
        if (index + 1 >= args.length) {
          stderr.writeln('--receipt membutuhkan path.');
          exitCode = 1;
          return;
        }
        receiptPath = args[++index];
      case '--max-age-days':
        if (index + 1 >= args.length) {
          stderr.writeln('--max-age-days membutuhkan angka.');
          exitCode = 1;
          return;
        }
        maxAgeDays = int.tryParse(args[++index]) ?? 30;
    }
  }
  if (maxAgeDays < 1) {
    stderr.writeln('--max-age-days harus >= 1.');
    exitCode = 1;
    return;
  }

  final file = File(receiptPath);
  if (!file.existsSync()) {
    stderr.writeln('GAGAL: tidak ada receipt backup di $receiptPath');
    stderr.writeln('Jalankan: dart run tool/backup_signing_key.dart');
    stderr.writeln('Lalu commit .ci/signing-backup-receipt.json.');
    exitCode = 1;
    return;
  }

  Map<String, dynamic> payload;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    payload = decoded is Map<String, dynamic> ? decoded : {};
  } catch (_) {
    stderr.writeln('GAGAL: receipt backup bukan JSON valid: $receiptPath');
    exitCode = 1;
    return;
  }
  final keys = payload['keys'];
  final entries = keys is Map<String, dynamic> ? keys : <String, dynamic>{};
  final now = DateTime.now().toUtc();
  final failures = <String>[];
  stdout.writeln('Receipt: $receiptPath');
  stdout.writeln('Jendela kesegaran: $maxAgeDays hari');
  for (final key in updateSigningPublicKeys) {
    String fingerprint;
    try {
      fingerprint = (await _sha256(
        base64Decode(key),
      )).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    } catch (_) {
      failures.add('KUNCI TIDAK VALID di updateSigningPublicKeys: $key');
      continue;
    }
    final entry = entries[key];
    final entryFingerprint = entry is Map
        ? '${entry['fingerprint'] ?? ''}'
        : '';
    final backedUpAt = DateTime.tryParse(
      entry is Map ? '${entry['backedUpAt'] ?? ''}' : '',
    );
    final ok =
        entry is Map &&
        entryFingerprint == fingerprint &&
        backedUpAt != null &&
        now.difference(backedUpAt.toUtc()) <= Duration(days: maxAgeDays);
    if (!ok) {
      if (entry is! Map) {
        failures.add('KUNCI TIDAK ADA DI RECEIPT: $key');
      } else if (entryFingerprint != fingerprint) {
        failures.add(
          'FINGERPRINT TIDAK COCOK untuk kunci $key: '
          'receipt=$entryFingerprint, seharusnya=$fingerprint',
        );
      } else if (backedUpAt == null) {
        failures.add('backedUpAt TIDAK VALID untuk kunci $key');
      } else {
        final age = now.difference(backedUpAt.toUtc());
        failures.add(
          'BACKUP STALE (${age.inDays} hari > $maxAgeDays): kunci $key '
          'terakhir dibackup $backedUpAt',
        );
      }
    }
    stdout.writeln(
      '  ${ok ? 'OK  ' : 'FAIL'} kunci ${key.substring(0, 12)}...',
    );
  }

  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('GAGAL: $failure');
    }
    stderr.writeln(
      'Backup kunci penandatanganan hilang/kadaluarsa sebelum rilis: '
      'jalankan dart run tool/backup_signing_key.dart, simpan hasilnya di '
      'password manager + vault offline, lalu commit receipt-nya.',
    );
    exitCode = 1;
  } else {
    stdout.writeln('PASS: semua kunci penandatanganan punya backup segar.');
  }
}

Future<List<int>> _sha256(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes;
