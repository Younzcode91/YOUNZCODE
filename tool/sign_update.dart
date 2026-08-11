import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:kode_agent_desktop/services/update_service.dart';

/// Signs every release in the update manifest with one or more Ed25519 keys.
///
/// Usage:
///   dart run tool/sign_update.dart [--key <privateKeyPath>]... [manifestPath]
///
/// Back-compatible positional form (single key):
///   dart run tool/sign_update.dart [privateKeyPath] [manifestPath]
///
/// Defaults: private key at tool/signing/update_signing_private_key.txt,
/// manifest at updates.json. Every signature covers the canonical payload
/// (version, download_url, sha256) — see
/// [UpdateService.canonicalUpdatePayload].
///
/// The manifest records all signatures in "signatures" (public_key +
/// signature pairs) and keeps the legacy single "signature" field set to the
/// FIRST key's signature, so clients that predate the key ring keep
/// verifying. During rotation pass the oldest in-field key first:
///   dart run tool/sign_update.dart --key old.txt --key new.txt updates.json
Future<void> main(List<String> args) async {
  final defaultKeyPath =
      'tool${Platform.pathSeparator}signing'
      '${Platform.pathSeparator}update_signing_private_key.txt';

  // --key <path> may repeat; positionals keep the back-compatible form
  // [privateKeyPath] [manifestPath] when no --key flags are given.
  final keyPaths = <String>[];
  final positionals = <String>[];
  for (var index = 0; index < args.length; index++) {
    if (args[index] == '--key') {
      if (index + 1 >= args.length) {
        stderr.writeln('--key membutuhkan path private key.');
        exitCode = 1;
        return;
      }
      keyPaths.add(args[index + 1]);
      index++;
    } else {
      positionals.add(args[index]);
    }
  }
  if (keyPaths.isEmpty) {
    keyPaths.add(
      positionals.isNotEmpty ? positionals.removeAt(0) : defaultKeyPath,
    );
  }
  final manifestPath = positionals.isNotEmpty
      ? positionals.first
      : 'updates.json';

  final keyPairs = <SimpleKeyPair>[];
  for (final path in keyPaths) {
    if (!File(path).existsSync()) {
      stderr.writeln('Private key tidak ditemukan: $path');
      stderr.writeln('Generate dulu dengan: dart run tool/update_keys.dart');
      exitCode = 1;
      return;
    }
    // Ed25519 private key bytes are the signing seed; rebuild the keypair from
    // them so the public key is derived automatically.
    keyPairs.add(
      await Ed25519().newKeyPairFromSeed(
        base64Decode(File(path).readAsStringSync().trim()),
      ),
    );
  }

  final payload = jsonDecode(File(manifestPath).readAsStringSync());
  if (payload is! Map<String, dynamic> || payload['releases'] is! List) {
    stderr.writeln(
      'Manifest harus berupa objek JSON dengan daftar "releases".',
    );
    exitCode = 1;
    return;
  }

  for (final rawRelease in payload['releases'] as List) {
    final release = (rawRelease as Map).cast<String, dynamic>();
    final update = AppUpdate.fromJson(release);
    final signatures = <Map<String, String>>[];
    for (var index = 0; index < keyPairs.length; index++) {
      final keyPair = keyPairs[index];
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyBase64 = base64Encode(publicKey.bytes);
      final signature = await Ed25519().sign(
        utf8.encode(UpdateService.canonicalUpdatePayload(update)),
        keyPair: keyPair,
      );
      signatures.add({
        'public_key': publicKeyBase64,
        'signature': base64Encode(signature.bytes),
      });
      stdout.writeln(
        'Ditandatangani ${update.version} (${update.channel}) dengan kunci #${index + 1}',
      );
    }
    release['signatures'] = signatures;
    // Legacy single field = first key, for clients without key-ring support.
    release['signature'] = signatures.first['signature'];
  }

  File(
    manifestPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
  stdout.writeln('Manifest ditandatangani: $manifestPath');
}
