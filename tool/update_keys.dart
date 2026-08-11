import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// Generates the Ed25519 keypair used to sign release manifests.
///
/// Usage:
///   dart run tool/update_keys.dart [privateKeyPath]
///
/// The public key (base64) must be appended to the `updateSigningPublicKeys`
/// list in lib/services/update_service.dart (or replace it entirely when
/// rotating). The private key is written to the given path (default
/// tool/signing/update_signing_private_key.txt) and must NEVER be committed
/// or shared; it is one of the secrets needed to publish updates.
Future<void> main(List<String> args) async {
  final privateKeyPath = args.isNotEmpty
      ? args.first
      : 'tool${Platform.pathSeparator}signing'
            '${Platform.pathSeparator}update_signing_private_key.txt';
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final privateKey = await keyPair.extractPrivateKeyBytes();

  final file = File(privateKeyPath);
  await file.create(recursive: true);
  await file.writeAsString(base64Encode(privateKey));

  final publicKeyBase64 = base64Encode(publicKey.bytes);
  stdout.writeln('Private key -> $privateKeyPath (RAHASIA, jangan di-commit)');
  stdout.writeln();
  stdout.writeln('Public key (base64) untuk updateSigningPublicKeys:');
  stdout.writeln(publicKeyBase64);
}
