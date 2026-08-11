import 'dart:convert';
import 'dart:io';

import 'package:kode_agent_desktop/services/update_service.dart';

/// Verifies the real in-app update path against the live manifest URL and
/// release asset, using the baked-in signing key and host allowlist.
///
/// Usage:
///   dart run tool/e2e_update_check.dart \
///     [--manifest PATH] [--expect-version VER] [--current-version VER]
///     [--trust PUBKEY]
///
/// Flags:
///   --manifest PATH     Verify a LOCAL manifest file (no network): checks
///                       that the newest release newer than the current
///                       version is validly signed by a trusted key. Used by
///                       the release pipeline right after signing, before
///                       anything is published.
///   --expect-version    Fail unless the offered release is exactly this
///                       version (default: warn only in live mode).
///   --current-version   Version the client claims to run (default 1.3.5).
///   --trust PUBKEY      Trusted public key override (repeatable); replaces
///                       the baked-in ring. Mainly for tests and for
///                       verifying a rotation candidate explicitly.
Future<void> main(List<String> args) async {
  String? manifestPath;
  String? expectVersion;
  var currentVersion = '1.3.5';
  final trustedKeys = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--manifest':
        manifestPath = args[++i];
      case '--expect-version':
        expectVersion = args[++i];
      case '--current-version':
        currentVersion = args[++i];
      case '--trust':
        trustedKeys.add(args[++i]);
      default:
        stderr.writeln('Argumen tidak dikenal: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final service = UpdateService(
    signingPublicKeys: trustedKeys.isNotEmpty
        ? trustedKeys
        : updateSigningPublicKeys,
  );

  if (manifestPath != null) {
    await _verifyLocalManifest(
      manifestPath,
      service: service,
      currentVersion: currentVersion,
      expectVersion: expectVersion,
    );
    return;
  }

  final update = await service.check(currentVersion: currentVersion);
  if (update == null) {
    stdout.writeln(
      'CHECK: FAIL - no update offered (should be ${expectVersion ?? 'newer'})',
    );
    exitCode = 1;
    return;
  }
  if (expectVersion != null && update.version != expectVersion) {
    stdout.writeln(
      'CHECK: FAIL - offered ${update.version} != expected $expectVersion',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'CHECK: PASS - ${update.version} offered, signature verified, '
    'sha256=${update.sha256.substring(0, 12)}...',
  );

  final destination =
      '${Directory.systemTemp.path}${Platform.pathSeparator}yz-update-e2e.exe';
  final file = await service.downloadAndVerify(update, destination);
  final bytes = await file.length();
  stdout.writeln(
    'DOWNLOAD: PASS - ${file.path} ($bytes bytes), signature + SHA-256 verified',
  );
  await file.delete();

  // The download_url must resolve to the live release asset.
  if (!update.downloadUrl.contains('v${update.version}')) {
    stdout.writeln(
      'WARNING: download URL does not point at v${update.version}',
    );
  }
  stdout.writeln('E2E: PASS');
}

/// Reads [path] as a manifest and verifies the newest release newer than
/// [currentVersion] against the trusted key ring — no network, no download.
Future<void> _verifyLocalManifest(
  String path, {
  required UpdateService service,
  required String currentVersion,
  String? expectVersion,
}) async {
  final Object? payload;
  try {
    payload = jsonDecode(await File(path).readAsString());
  } on FormatException {
    stderr.writeln('LOCAL: FAIL - $path bukan JSON valid');
    exitCode = 1;
    return;
  }
  final entries = payload is List
      ? payload
      : payload is Map && payload['releases'] is List
      ? payload['releases'] as List
      : <Object?>[payload];
  final releases =
      entries
          .whereType<Map>()
          .map((item) => AppUpdate.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.channel == service.channel)
          .toList()
        ..sort(
          (left, right) =>
              UpdateService.compareVersions(right.version, left.version),
        );
  if (releases.isEmpty ||
      UpdateService.compareVersions(releases.first.version, currentVersion) <=
          0) {
    stderr.writeln(
      'LOCAL: FAIL - no release newer than $currentVersion in $path',
    );
    exitCode = 1;
    return;
  }
  final update = releases.first;
  if (expectVersion != null && update.version != expectVersion) {
    stderr.writeln(
      'LOCAL: FAIL - newest release ${update.version} != expected $expectVersion',
    );
    exitCode = 1;
    return;
  }
  final verified = await UpdateService.verifySignatureWithAny(
    update,
    service.trustedSigningKeys,
  );
  if (!verified) {
    stderr.writeln(
      'LOCAL: FAIL - ${update.version} tidak diverifikasi kunci tepercaya mana pun',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'LOCAL: PASS - ${update.version} verified against trusted key ring, '
    'sha256=${update.sha256.substring(0, 12)}...',
  );
}
