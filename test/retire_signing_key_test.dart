import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

import 'tool_runner.dart';

typedef _Signer = ({
  Ed25519 algorithm,
  SimpleKeyPair keyPair,
  String publicKey,
});

Future<_Signer> _newKeyPair() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return (
    algorithm: algorithm,
    keyPair: keyPair,
    publicKey: base64Encode(publicKey.bytes),
  );
}

String _historyCsv(int rows, {int latestDaysAgo = 0}) {
  final lines = <String>['timestamp,os,workers,adapter,totalMs,ratio'];
  for (var index = 0; index < rows; index++) {
    final age = rows - 1 - index + latestDaysAgo;
    final timestamp = DateTime.now()
        .toUtc()
        .subtract(Duration(days: age))
        .toIso8601String();
    lines.add('$timestamp,ubuntu-latest,3,dart,3000,0.10');
  }
  return lines.join('\n');
}

/// Writes a manifest whose newest release is signed by every [signers] key.
Future<void> _writeManifest(
  String path,
  List<_Signer> signers, {
  String version = '2.0.0',
}) async {
  final signatures = <Map<String, String>>[];
  for (final signer in signers) {
    final payload = utf8.encode(
      UpdateService.canonicalUpdatePayload(
        AppUpdate(
          version: version,
          channel: 'stable',
          notes: 'retire fixture',
          downloadUrl:
              'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
              'v$version/YOUNZCODE-Setup-$version.exe',
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ),
    );
    final signature = await signer.algorithm.sign(
      payload,
      keyPair: signer.keyPair,
    );
    signatures.add({
      'public_key': signer.publicKey,
      'signature': base64Encode(signature.bytes),
    });
  }
  await File(path).writeAsString(
    jsonEncode({
      'channel': 'stable',
      'releases': [
        {
          'version': version,
          'channel': 'stable',
          'notes': 'retire fixture',
          'download_url':
              'https://github.com/Younzcode91/YOUNZCODE/releases/download/'
              'v$version/YOUNZCODE-Setup-$version.exe',
          'sha256':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signatures': signatures,
        },
      ],
    }),
  );
}

String _pingsCsv({
  required int adopted,
  required int total,
  required String version,
}) {
  final lines = <String>['timestamp,version,channel,os,install_id'];
  for (var index = 0; index < total; index++) {
    final value = index < adopted ? version : '1.0.0';
    final timestamp = DateTime.now()
        .toUtc()
        .subtract(Duration(days: index % 10))
        .toIso8601String();
    lines.add('$timestamp,$value,stable,windows,install-$index');
  }
  return lines.join('\n');
}

/// Walks up from the test CWD until the package root (pubspec.yaml) is found.
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

Future<ProcessResult> _runRetire(List<String> args, {String? cwd}) {
  final (executable, arguments) = toolLaunch('tool/retire_signing_key.dart', args);
  return Process.run(
    executable,
    arguments,
    workingDirectory: cwd ?? _packageRoot(),
    runInShell: false,
  ).timeout(const Duration(seconds: 90));
}

void main() {
  test('retire diterima bila semua prekondisi terpenuhi', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await history.writeAsString(_historyCsv(14));
    await _writeManifest(manifest.path, [keyB]); // survivor B signs

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('READY'));
  });

  test('prefix unik juga diterima', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await history.writeAsString(_historyCsv(14));
    await _writeManifest(manifest.path, [keyB]);

    final result = await _runRetire([
      '--retire',
      keyA.publicKey.substring(0, 8),
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('READY'));
  });

  test('retire ditolak bila kunci tidak dipercaya', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();
    final stranger = await _newKeyPair();

    final result = await _runRetire([
      '--retire',
      stranger.publicKey,
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('tidak ditemukan'));
  });

  test('retire ditolak bila hanya ada satu kunci yang dipercaya', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();

    await history.writeAsString(_historyCsv(14));
    await _writeManifest(manifest.path, [keyA]);

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--trusted-keys',
      keyA.publicKey,
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('MENGOSONGKAN'));
  });

  test('retire ditolak bila riwayat malam tidak ada', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}missing.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await _writeManifest(manifest.path, [keyB]);

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('HISTORY TIDAK ADA'));
  });

  test('retire ditolak bila baris riwayat kurang dari minimum', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await history.writeAsString(_historyCsv(5));
    await _writeManifest(manifest.path, [keyB]);

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('HISTORY KURANG'));
  });

  test('retire ditolak bila riwayat terakhir terlalu tua', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await history.writeAsString(_historyCsv(14, latestDaysAgo: 20));
    await _writeManifest(manifest.path, [keyB]);

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--max-history-age-days',
      '7',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('HISTORY STALE'));
  });

  test(
    'retire ditolak bila manifest tidak terverifikasi kunci tersisa',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-retire-');
      addTearDown(() => root.delete(recursive: true));
      final sep = Platform.pathSeparator;
      final history = File('${root.path}${sep}history.csv');
      final manifest = File('${root.path}${sep}updates.json');
      final keyA = await _newKeyPair();
      final keyB = await _newKeyPair();

      await history.writeAsString(_historyCsv(14));
      // Manifest hanya ditandatangani kunci yang akan di-retire (A), bukan B.
      await _writeManifest(manifest.path, [keyA]);

      final result = await _runRetire([
        '--retire',
        keyA.publicKey,
        '--history',
        history.path,
        '--manifest',
        manifest.path,
        '--min-history-rows',
        '14',
        '--trusted-keys',
        '${keyA.publicKey},${keyB.publicKey}',
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('TIDAK TERVERIFIKASI'));
    },
  );

  test(
    '--apply menghapus kunci dari blok updateSigningPublicKeys',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-retire-');
      addTearDown(() => root.delete(recursive: true));
      final sep = Platform.pathSeparator;
      final history = File('${root.path}${sep}history.csv');
      final manifest = File('${root.path}${sep}updates.json');
      final service = File('${root.path}${sep}update_service.dart');
      final keyA = await _newKeyPair();
      final keyB = await _newKeyPair();

      await history.writeAsString(_historyCsv(14));
      await _writeManifest(manifest.path, [keyB]);
      await service.writeAsString('''
// fixture service untuk menguji penulisan ulang sumber
const updateSigningPublicKeys = <String>[
  '${keyA.publicKey}',
  '${keyB.publicKey}',
];
''');

      final result = await _runRetire([
        '--retire',
        keyA.publicKey,
        '--history',
        history.path,
        '--manifest',
        manifest.path,
        '--min-history-rows',
        '14',
        '--trusted-keys',
        '${keyA.publicKey},${keyB.publicKey}',
        '--service',
        service.path,
        '--apply',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final rewritten = await service.readAsString();
      expect(rewritten, contains(keyB.publicKey));
      expect(rewritten, isNot(contains(keyA.publicKey)));
      expect(rewritten, contains('const updateSigningPublicKeys = <String>['));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('telemetri adopsi menggantikan proksi riwayat malam', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final pings = File('${root.path}${sep}pings.csv');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    // Riwayat malam hanya 1 baris (proksi GAGAL), tapi adopsi 9/10 >= 2.0.0
    // (telemetri) harus menggantikannya dan lolos.
    await history.writeAsString(_historyCsv(1));
    await _writeManifest(manifest.path, [keyB]);
    await pings.writeAsString(
      _pingsCsv(adopted: 9, total: 10, version: '2.0.0'),
    );

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--pings',
      pings.path,
      '--adoption-version',
      '2.0.0',
      '--min-adoption-ratio',
      '0.9',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('Telemetri adopsi'));
  });

  test('retire ditolak bila adopsi rendah', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final pings = File('${root.path}${sep}pings.csv');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    await history.writeAsString(_historyCsv(14));
    await _writeManifest(manifest.path, [keyB]);
    await pings.writeAsString(
      _pingsCsv(adopted: 7, total: 10, version: '2.0.0'),
    );

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--pings',
      pings.path,
      '--adoption-version',
      '2.0.0',
      '--min-adoption-ratio',
      '0.9',
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('ADOPTSI RENDAH'));
  });

  test('file ping kosong tetap memakai proksi riwayat malam', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-retire-');
    addTearDown(() => root.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final history = File('${root.path}${sep}history.csv');
    final manifest = File('${root.path}${sep}updates.json');
    final pings = File('${root.path}${sep}pings.csv');
    final keyA = await _newKeyPair();
    final keyB = await _newKeyPair();

    // Header saja: tidak ada data telemetri -> proksi riwayat malam berlaku.
    await history.writeAsString(_historyCsv(14));
    await _writeManifest(manifest.path, [keyB]);
    await pings.writeAsString('timestamp,version,channel,os,install_id\n');

    final result = await _runRetire([
      '--retire',
      keyA.publicKey,
      '--history',
      history.path,
      '--manifest',
      manifest.path,
      '--min-history-rows',
      '14',
      '--pings',
      pings.path,
      '--trusted-keys',
      '${keyA.publicKey},${keyB.publicKey}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('proksi riwayat malam'));
  });
}
