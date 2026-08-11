import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

/// Signs every release in the update manifest with the private Ed25519 key.
///
/// Usage:
///   dart run tool/sign_update.dart [privateKeyPath] [manifestPath]
///
/// Defaults: private key at tool/signing/update_signing_private_key.txt,
/// manifest at updates.json. The signature covers the canonical payload
/// (version, download_url, sha256) — see
/// [UpdateService.canonicalUpdatePayload].
Future<void> main(List<String> args) async {
  final privateKeyPath = args.isNotEmpty
      ? args.first
      : 'tool${Platform.pathSeparator}signing'
            '${Platform.pathSeparator}update_signing_private_key.txt';
  final manifestPath = args.length > 1 ? args[1] : 'updates.json';

  if (!File(privateKeyPath).existsSync()) {
    stderr.writeln('Private key tidak ditemukan: $privateKeyPath');
    stderr.writeln('Generate dulu dengan: dart run tool/update_keys.dart');
    exitCode = 1;
    return;
  }

  final payload = jsonDecode(File(manifestPath).readAsStringSync());
  if (payload is! Map<String, dynamic> || payload['releases'] is! List) {
    stderr.writeln('Manifest harus berupa objek JSON dengan daftar "releases".');
    exitCode = 1;
    return;
  }

  // Ed25519 private key bytes are the signing seed; rebuild the keypair from
  // them so the public key is derived automatically.
  final keyPair = await Ed25519().newKeyPairFromSeed(
    base64Decode(File(privateKeyPath).readAsStringSync().trim()),
  );

  for (final rawRelease in payload['releases'] as List) {
    final release = (rawRelease as Map).cast<String, dynamic>();
    final update = AppUpdate.fromJson(release);
    final signature = await Ed25519().sign(
      utf8.encode(UpdateService.canonicalUpdatePayload(update)),
      keyPair: keyPair,
    );
    release['signature'] = base64Encode(signature.bytes);
    stdout.writeln('Ditandatangani ${update.version} (${update.channel})');
  }

  File(manifestPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  stdout.writeln('Manifest ditandatangani: $manifestPath');
}
