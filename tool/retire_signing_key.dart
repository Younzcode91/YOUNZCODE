import 'dart:convert';
import 'dart:io';

import 'package:kode_agent_desktop/services/update_service.dart';

/// Retires a signing key from `updateSigningPublicKeys` once the nightly
/// margin history shows the fleet has had time to catch up.
///
/// Usage:
///   dart run tool/retire_signing_key.dart --retire `<publicKey|prefix>`
///     [--history `<csv>`] [--manifest `<json>`]
///     [--min-history-rows `<n>`] [--max-history-age-days `<n>`]
///     [--trusted-keys `<k1,k2>`] [--service `<path>`] [--apply]
///
/// The margin history (`.ci/dap-load-history.csv`, maintained nightly by
/// `dap-load-test.yml`) is the fleet-catch-up proxy: the app has no update
/// telemetry, so "the fleet caught up" is approximated as "the dual-key
/// releases have been out for at least --min-history-rows nightly cycles and
/// the pipeline is still fresh (latest row within --max-history-age-days)".
/// True per-version adoption would need an update ping endpoint.
///
/// Preconditions (all must hold; dry-run by default):
///   1. the key to retire is currently trusted;
///   2. at least one trusted key remains (never empty the ring);
///   3. the margin history exists with >= --min-history-rows rows;
///   4. the latest history row is within --max-history-age-days;
///   5. the newest release in --manifest verifies with a SURVIVING key, so
///      the shipped manifest stays verifiable after the drop.
///
/// With `--apply` the key's entry is removed from `updateSigningPublicKeys`
/// in `--service` (default lib/services/update_service.dart). The NEXT
/// release must then be signed with a surviving key only:
///   dart run tool/sign_update.dart --key `<surviving-key-path>` updates.json
Future<void> main(List<String> args) async {
  var retiree = '';
  var historyPath = '.ci${Platform.pathSeparator}dap-load-history.csv';
  var manifestPath = 'updates.json';
  var servicePath =
      'lib${Platform.pathSeparator}services${Platform.pathSeparator}update_service.dart';
  var minHistoryRows = 14;
  var maxHistoryAgeDays = 7;
  var apply = false;
  var trustedOverride = <String>[];
  var pingsPath = '.ci${Platform.pathSeparator}update-pings.csv';
  var minAdoptionRatio = 0.9;
  var adoptionWindowDays = 30;
  var adoptionVersionArg = '';

  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--retire':
        if (index + 1 >= args.length) {
          stderr.writeln('--retire membutuhkan public key (atau prefix unik).');
          exitCode = 1;
          return;
        }
        retiree = args[++index];
      case '--history':
        if (index + 1 >= args.length) {
          stderr.writeln('--history membutuhkan path CSV.');
          exitCode = 1;
          return;
        }
        historyPath = args[++index];
      case '--manifest':
        if (index + 1 >= args.length) {
          stderr.writeln('--manifest membutuhkan path JSON.');
          exitCode = 1;
          return;
        }
        manifestPath = args[++index];
      case '--min-history-rows':
        if (index + 1 >= args.length) {
          stderr.writeln('--min-history-rows membutuhkan angka.');
          exitCode = 1;
          return;
        }
        minHistoryRows = int.tryParse(args[++index]) ?? 14;
      case '--max-history-age-days':
        if (index + 1 >= args.length) {
          stderr.writeln('--max-history-age-days membutuhkan angka.');
          exitCode = 1;
          return;
        }
        maxHistoryAgeDays = int.tryParse(args[++index]) ?? 7;
      case '--pings':
        if (index + 1 >= args.length) {
          stderr.writeln('--pings membutuhkan path CSV.');
          exitCode = 1;
          return;
        }
        pingsPath = args[++index];
      case '--min-adoption-ratio':
        if (index + 1 >= args.length) {
          stderr.writeln('--min-adoption-ratio membutuhkan angka.');
          exitCode = 1;
          return;
        }
        minAdoptionRatio = double.tryParse(args[++index]) ?? 0.9;
      case '--adoption-window-days':
        if (index + 1 >= args.length) {
          stderr.writeln('--adoption-window-days membutuhkan angka.');
          exitCode = 1;
          return;
        }
        adoptionWindowDays = int.tryParse(args[++index]) ?? 30;
      case '--adoption-version':
        if (index + 1 >= args.length) {
          stderr.writeln('--adoption-version membutuhkan versi.');
          exitCode = 1;
          return;
        }
        adoptionVersionArg = args[++index];
      case '--trusted-keys':
        if (index + 1 >= args.length) {
          stderr.writeln('--trusted-keys membutuhkan daftar kunci.');
          exitCode = 1;
          return;
        }
        trustedOverride = args[++index]
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
      case '--service':
        if (index + 1 >= args.length) {
          stderr.writeln('--service membutuhkan path file service.');
          exitCode = 1;
          return;
        }
        servicePath = args[++index];
      case '--apply':
        apply = true;
      default:
        stderr.writeln('Argumen tidak dikenal: ${args[index]}');
        exitCode = 1;
        return;
    }
  }
  if (retiree.isEmpty) {
    stderr.writeln(
      'Gunakan: dart run tool/retire_signing_key.dart '
      '--retire <publicKey|prefix> [--apply]',
    );
    exitCode = 1;
    return;
  }

  final trusted = trustedOverride.isNotEmpty
      ? trustedOverride
      : updateSigningPublicKeys;
  final resolved = _resolveKey(retiree, trusted);
  if (resolved == null) {
    stderr.writeln(
      'GAGAL: kunci tidak ditemukan (atau prefix ambigu): $retiree',
    );
    stderr.writeln('Kunci yang dipercaya saat ini:');
    for (final key in trusted) {
      stderr.writeln('  ${key.substring(0, 16)}...');
    }
    exitCode = 1;
    return;
  }
  final survivors = trusted.where((key) => key != resolved).toList();

  final failures = <String>[];
  if (survivors.isEmpty) {
    failures.add(
      'TIDAK BOLEH MENGOSONGKAN RING: hanya satu kunci yang dipercaya.',
    );
  }

  // True fleet adoption (update-ping telemetry) REPLACES the nightly-run
  // proxy: distinct installs seen in the window that run the adoption-version
  // or newer, as a fraction of all distinct installs in the window. When no
  // ping data exists, the nightly margin history proxy still applies.
  final pingsRows = File(pingsPath).existsSync()
      ? File(pingsPath)
            .readAsLinesSync()
            .where(
              (line) =>
                  line.trim().isNotEmpty && !line.startsWith('timestamp,'),
            )
            .toList()
      : const <String>[];
  final hasPings = pingsRows.isNotEmpty;

  final history = File(historyPath);
  var latestHistoryAt = '';
  if (!hasPings) {
    if (!history.existsSync()) {
      failures.add('HISTORY TIDAK ADA: $historyPath (jalankan nightly dulu).');
    } else {
      final rows = history
          .readAsLinesSync()
          .where(
            (line) => line.trim().isNotEmpty && !line.startsWith('timestamp,'),
          )
          .toList();
      if (rows.length < minHistoryRows) {
        failures.add(
          'HISTORY KURANG: ${rows.length} baris < $minHistoryRows '
          '(masa tenggang fleet belum terpenuhi).',
        );
      }
      if (rows.isNotEmpty) {
        latestHistoryAt = rows.last.split(',').first.trim();
        final latest = DateTime.tryParse(latestHistoryAt);
        if (latest == null) {
          failures.add('HISTORY TIMESTAMP TIDAK VALID: $latestHistoryAt');
        } else {
          final age = DateTime.now().toUtc().difference(latest.toUtc());
          if (age > Duration(days: maxHistoryAgeDays)) {
            failures.add(
              'HISTORY STALE: baris terakhir $latestHistoryAt '
              '(${age.inDays} hari > $maxHistoryAgeDays).',
            );
          }
        }
      }
    }
  }

  final manifest = File(manifestPath);
  var newestReleaseVersion = '';
  if (!manifest.existsSync()) {
    failures.add('MANIFEST TIDAK ADA: $manifestPath');
  } else {
    try {
      final payload = jsonDecode(manifest.readAsStringSync());
      final rawReleases =
          payload is Map<String, dynamic> && payload['releases'] is List
          ? payload['releases'] as List
          : <Object?>[];
      final releases =
          rawReleases
              .whereType<Map>()
              .map(
                (item) => AppUpdate.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
            ..sort(
              (left, right) =>
                  UpdateService.compareVersions(right.version, left.version),
            );
      if (releases.isEmpty) {
        failures.add('MANIFEST TANPA RELEASE.');
      } else {
        final newest = releases.first;
        newestReleaseVersion = newest.version;
        final verified = await UpdateService.verifySignatureWithAny(
          newest,
          survivors,
        );
        if (!verified) {
          failures.add(
            'MANIFEST TIDAK TERVERIFIKASI KUNCI TERSISA: rilis '
            '${newest.version} harus ditandatangani oleh kunci yang tersisa.',
          );
        }
      }
    } catch (_) {
      failures.add('MANIFEST TIDAK VALID JSON: $manifestPath');
    }
  }

  var adoptionReport = '';
  if (hasPings) {
    final adoptionVersion = adoptionVersionArg.isNotEmpty
        ? adoptionVersionArg
        : newestReleaseVersion;
    if (adoptionVersion.isEmpty) {
      failures.add(
        'ADOPTSI TIDAK DAPAT DIHITUNG: versi target tidak diketahui.',
      );
    } else {
      final adoption = _computeAdoption(
        pingsRows,
        adoptionVersion,
        adoptionWindowDays,
      );
      if (adoption == null) {
        failures.add(
          'ADOPTSI TIDAK DAPAT DIHITUNG: tidak ada ping valid dalam '
          '$adoptionWindowDays hari terakhir.',
        );
      } else {
        final ratio = adoption.adoptedCount / adoption.totalCount;
        adoptionReport =
            '${adoption.totalCount} install unik, '
            '${adoption.adoptedCount} >= $adoptionVersion '
            '(${ratio.toStringAsFixed(2)})';
        if (ratio < minAdoptionRatio) {
          failures.add(
            'ADOPTSI RENDAH: ${adoption.adoptedCount}/${adoption.totalCount} '
            '(${ratio.toStringAsFixed(2)}) < '
            '${minAdoptionRatio.toStringAsFixed(2)} untuk versi '
            '$adoptionVersion.',
          );
        }
      }
    }
  }

  final suffix = apply ? ' dengan --apply' : '';
  stdout.writeln('Retire kunci : ${resolved.substring(0, 16)}...$suffix');
  stdout.writeln(
    'Kunci tersisa: ${survivors.map((k) => '${k.substring(0, 16)}...').join(', ')}',
  );
  if (latestHistoryAt.isNotEmpty) {
    stdout.writeln('Riwayat terakhir: $latestHistoryAt');
  }
  if (adoptionReport.isNotEmpty) {
    stdout.writeln('Telemetri adopsi: $adoptionReport');
  } else if (!hasPings) {
    stdout.writeln(
      'Telemetri adopsi: tidak ada data ping — memakai proksi riwayat malam.',
    );
  }

  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('GAGAL: $failure');
    }
    stderr.writeln('Retire DITOLAK - perbaiki prekondisi di atas.');
    exitCode = 1;
    return;
  }

  if (!apply) {
    stdout.writeln('READY: kunci dapat di-retire (dry-run).');
    stdout.writeln(
      'Jalankan dengan --apply untuk menghapusnya dari '
      'updateSigningPublicKeys.',
    );
    return;
  }

  final source = File(servicePath);
  if (!source.existsSync()) {
    stderr.writeln('GAGAL: file service tidak ada: $servicePath');
    exitCode = 1;
    return;
  }
  final original = source.readAsStringSync();
  final pattern = RegExp(
    r"const updateSigningPublicKeys = <String>\[([^\]]*)\];",
    dotAll: true,
  );
  final match = pattern.firstMatch(original);
  if (match == null) {
    stderr.writeln(
      'GAGAL: blok updateSigningPublicKeys tidak ditemukan di '
      '$servicePath.',
    );
    exitCode = 1;
    return;
  }
  final keysLines = match.group(1)!.split('\n');
  final keptLines = keysLines
      .where((line) => !line.contains("'$resolved'"))
      .toList();
  final newBlock =
      'const updateSigningPublicKeys = <String>[${keptLines.join('\n')}];';
  source.writeAsStringSync(original.replaceFirst(match.group(0)!, newBlock));
  stdout.writeln(
    'APPLIED: kunci ${resolved.substring(0, 16)}... dihapus dari '
    '$servicePath.',
  );
  stdout.writeln('Kunci yang dipercaya sekarang:');
  for (final key in survivors) {
    stdout.writeln('  $key');
  }
  stdout.writeln(
    'Langkah berikut: rilis BERIKUTNYA ditandatangani dengan kunci '
    'tersisa saja:',
  );
  stdout.writeln(
    '  dart run tool/sign_update.dart --key <path kunci tersisa> '
    'updates.json',
  );
  stdout.writeln(
    'Lalu backup (vault entry + receipt) kunci tersisa agar gate '
    'rilis tetap lulus.',
  );
}

/// Exact match wins; otherwise a unique prefix (>= 6 chars) resolves the key.
String? _resolveKey(String retiree, List<String> trusted) {
  if (trusted.contains(retiree)) return retiree;
  if (retiree.length < 6) return null;
  final matches = trusted.where((key) => key.startsWith(retiree)).toList();
  return matches.length == 1 ? matches.first : null;
}

/// Adoption over ping rows: distinct installs in the window whose LATEST
/// version is >= [targetVersion], over all distinct installs in the window.
/// Returns null when no valid row falls inside the window.
({int totalCount, int adoptedCount})? _computeAdoption(
  List<String> rows,
  String targetVersion,
  int windowDays,
) {
  final cutoff = DateTime.now().toUtc().subtract(Duration(days: windowDays));
  final latestByInstall = <String, String>{};
  for (final row in rows) {
    final fields = _csvFields(row);
    if (fields.length < 5) continue;
    final timestamp = DateTime.tryParse(fields[0].trim());
    if (timestamp == null || timestamp.toUtc().isBefore(cutoff)) continue;
    final installId = fields[4].trim();
    final version = fields[1].trim();
    if (installId.isEmpty || version.isEmpty) continue;
    final current = latestByInstall[installId];
    if (current == null ||
        UpdateService.compareVersions(version, current) > 0) {
      latestByInstall[installId] = version;
    }
  }
  if (latestByInstall.isEmpty) return null;
  var adopted = 0;
  for (final version in latestByInstall.values) {
    if (UpdateService.compareVersions(version, targetVersion) >= 0) {
      adopted++;
    }
  }
  return (totalCount: latestByInstall.length, adoptedCount: adopted);
}

/// Minimal CSV line splitter honoring double-quoted fields.
List<String> _csvFields(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (inQuotes) {
      if (char == '"') {
        if (index + 1 < line.length && line[index + 1] == '"') {
          buffer.write('"');
          index++;
        } else {
          inQuotes = false;
        }
      } else {
        buffer.write(char);
      }
    } else if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      fields.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  fields.add(buffer.toString());
  return fields;
}
