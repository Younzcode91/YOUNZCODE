import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// Base64-encoded Ed25519 public key that release manifests are signed with.
/// Empty by default: generate a keypair, sign each manifest's canonical payload
/// (see [UpdateService.canonicalUpdatePayload]) with the private key, publish
/// the signature as the manifest `signature` field, and paste the public key
/// here. Once set, unsigned or tampered updates are rejected.
const updateSigningPublicKey = '';

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.channel,
    required this.notes,
    required this.downloadUrl,
    required this.sha256,
    this.signature = '',
  });

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
    version: '${json['version'] ?? ''}',
    channel: '${json['channel'] ?? 'stable'}',
    notes: '${json['notes'] ?? ''}',
    downloadUrl: '${json['download_url'] ?? ''}',
    sha256: '${json['sha256'] ?? ''}'.toLowerCase(),
    signature: '${json['signature'] ?? ''}',
  );

  final String version;
  final String channel;
  final String notes;
  final String downloadUrl;
  final String sha256;
  final String signature;
}

class UpdateService {
  const UpdateService({
    this.signingPublicKeyBase64 = updateSigningPublicKey,
    this.allowedHosts = const [],
  });

  /// Ed25519 public key updates must be signed with. Empty disables signature
  /// enforcement (HTTPS + SHA-256 integrity still apply).
  final String signingPublicKeyBase64;

  /// If non-empty, the manifest and download hosts must be in this allowlist.
  final List<String> allowedHosts;

  Future<AppUpdate?> check({
    required String manifestUrl,
    required String channel,
    required String currentVersion,
  }) async {
    final manifestUri = Uri.parse(manifestUrl);
    if (manifestUri.scheme != 'https') {
      throw const FormatException('URL manifest update harus memakai HTTPS.');
    }
    _requireAllowedHost(manifestUri, 'Manifest');
    final response = await http
        .get(manifestUri)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Update manifest HTTP ${response.statusCode}');
    }
    final payload = jsonDecode(response.body);
    final entries = payload is List
        ? payload
        : payload is Map && payload['releases'] is List
        ? payload['releases'] as List
        : [payload];
    final releases =
        entries
            .whereType<Map>()
            .map((item) => AppUpdate.fromJson(Map<String, dynamic>.from(item)))
            .where((item) => item.channel == channel)
            .toList()
          ..sort((left, right) => compareVersions(right.version, left.version));
    if (releases.isEmpty ||
        compareVersions(releases.first.version, currentVersion) <= 0) {
      return null;
    }
    return releases.first;
  }

  Future<File> downloadAndVerify(AppUpdate update, String destination) async {
    if (update.downloadUrl.isEmpty || update.sha256.length != 64) {
      throw const FormatException(
        'Manifest update tidak memiliki URL/SHA-256 valid.',
      );
    }
    final downloadUri = Uri.parse(update.downloadUrl);
    if (downloadUri.scheme != 'https') {
      throw const FormatException('URL download update harus memakai HTTPS.');
    }
    _requireAllowedHost(downloadUri, 'Download');
    // Authenticity: when a signing key is configured, require a valid signature
    // over (version, downloadUrl, sha256) before trusting any of them.
    if (signingPublicKeyBase64.isNotEmpty &&
        !await verifySignature(update, signingPublicKeyBase64)) {
      throw StateError('Tanda tangan update tidak valid atau tidak ada.');
    }
    final response = await http
        .get(downloadUri)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Download update HTTP ${response.statusCode}');
    }
    final file = File(destination);
    await file.writeAsBytes(response.bodyBytes, flush: true);
    final digest = await Sha256().hash(response.bodyBytes);
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (hex != update.sha256) {
      await file.delete();
      throw StateError('Checksum installer tidak cocok; file dihapus.');
    }
    return file;
  }

  void _requireAllowedHost(Uri uri, String what) {
    if (allowedHosts.isEmpty) return;
    if (!allowedHosts.contains(uri.host.toLowerCase())) {
      throw FormatException('$what host ${uri.host} tidak diizinkan.');
    }
  }

  /// Canonical bytes a manifest signature must cover.
  static String canonicalUpdatePayload(AppUpdate update) =>
      '${update.version}\n${update.downloadUrl}\n${update.sha256}';

  static Future<bool> verifySignature(
    AppUpdate update,
    String publicKeyBase64,
  ) async {
    if (update.signature.isEmpty || publicKeyBase64.isEmpty) return false;
    try {
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );
      return await Ed25519().verify(
        utf8.encode(canonicalUpdatePayload(update)),
        signature: Signature(
          base64Decode(update.signature),
          publicKey: publicKey,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  static int compareVersions(String left, String right) {
    final leftParts = left.split(RegExp(r'[-+]')).first.split('.');
    final rightParts = right.split(RegExp(r'[-+]')).first.split('.');
    for (var index = 0; index < 3; index++) {
      final difference =
          (int.tryParse(leftParts.elementAtOrNull(index) ?? '') ?? 0) -
          (int.tryParse(rightParts.elementAtOrNull(index) ?? '') ?? 0);
      if (difference != 0) return difference.sign;
    }
    return 0;
  }
}
