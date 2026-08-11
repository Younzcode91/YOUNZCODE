import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// URL of the release manifest the app checks for updates against.
/// Must be HTTPS; the host must be in [updateAllowedHosts]. Publish
/// `updates.json` at this location — raw.githubusercontent.com serves the
/// repo's DEFAULT branch directly, so keep this path in sync with the
/// branch the release pipeline publishes to (release.yml MANIFEST_BRANCH,
/// which defaults to the repo default branch).
const updateManifestUrl =
    'https://raw.githubusercontent.com/Younzcode91/YOUNZCODE/'
    'feature/multiprovider-and-polish/updates.json';

/// Channel this build tracks. The manifest may list multiple channels; only
/// releases matching this channel are considered.
const updateChannel = 'stable';

/// Hosts allowed to serve the manifest and installer downloads.
const updateAllowedHosts = <String>['raw.githubusercontent.com', 'github.com'];

/// Primary base64-encoded Ed25519 public key that release manifests are signed
/// with. Equals the first entry of [updateSigningPublicKeys]; kept for
/// backward compatibility (single-key deployments and tooling).
const updateSigningPublicKey = 'sCshyfPyPgyUnsmtc3fK1oWeTXj2szd3sckqv5R/0eU=';

/// Trusted Ed25519 public keys that release manifests may be signed with.
/// A release is accepted if ANY of these keys validates its signature, so a
/// new key can be added here and shipped in a normal update before it is
/// used for signing; once the fleet has caught up, the old key can be
/// removed. Generate keys with `dart run tool/update_keys.dart`, sign each
/// manifest's canonical payload (see
/// [UpdateService.canonicalUpdatePayload]) with `dart run tool/sign_update.dart`
/// (`--key old.txt --key new.txt` during rotation), and keep this list in
/// sync with the private keys you hold. Once non-empty, unsigned or tampered
/// updates are rejected.
const updateSigningPublicKeys = <String>[
  'sCshyfPyPgyUnsmtc3fK1oWeTXj2szd3sckqv5R/0eU=',
  'KRtmNU7aHdQ2tkrylk8wdO6D7iamMpuORru4q7FDBdA=',
];

/// One signature of a release, paired with the public key that produced it.
class UpdateSignature {
  const UpdateSignature({required this.publicKey, required this.signature});

  final String publicKey;
  final String signature;
}

/// Reports which trusted signing key verified an update (null when signature
/// enforcement is disabled). Kept as a plain typedef so the service stays
/// importable from pure-Dart release tools (`dart run`).
typedef UpdateVerifiedCallback = void Function(String? signingKey);

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.channel,
    required this.notes,
    required this.downloadUrl,
    required this.sha256,
    this.signature = '',
    this.signatures = const [],
  });

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
    version: '${json['version'] ?? ''}',
    channel: '${json['channel'] ?? 'stable'}',
    notes: '${json['notes'] ?? ''}',
    downloadUrl: '${json['download_url'] ?? ''}',
    sha256: '${json['sha256'] ?? ''}'.toLowerCase(),
    signature: '${json['signature'] ?? ''}',
    signatures: _parseSignatures(json['signatures']),
  );

  final String version;
  final String channel;
  final String notes;
  final String downloadUrl;
  final String sha256;

  /// Legacy single signature (the format older clients read). Kept in sync
  /// with the first entry of [signatures] by the signing tool.
  final String signature;

  /// Structured per-key signatures ("public_key" + "signature" pairs).
  final List<UpdateSignature> signatures;

  static List<UpdateSignature> _parseSignatures(Object? raw) {
    if (raw is! List) return const [];
    final result = <UpdateSignature>[];
    for (final item in raw) {
      if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        final publicKey = '${map['public_key'] ?? ''}';
        final signature = '${map['signature'] ?? ''}';
        if (publicKey.isNotEmpty && signature.isNotEmpty) {
          result.add(
            UpdateSignature(publicKey: publicKey, signature: signature),
          );
        }
      }
    }
    return result;
  }
}

class UpdateService {
  const UpdateService({
    this.signingPublicKeyBase64 = updateSigningPublicKey,
    this.signingPublicKeys = const [],
    this.allowedHosts = updateAllowedHosts,
    this.manifestUrl = updateManifestUrl,
    this.channel = updateChannel,
    this.httpClient,
  });

  /// Ed25519 public key updates must be signed with (legacy single-key form).
  /// Ignored when [signingPublicKeys] is non-empty. Empty disables signature
  /// enforcement (HTTPS + SHA-256 integrity still apply).
  final String signingPublicKeyBase64;

  /// Trusted Ed25519 public keys (key ring). A release is accepted when ANY of
  /// these keys validates its signature. Empty list disables enforcement.
  final List<String> signingPublicKeys;

  /// Resolved trusted keys: the explicit ring wins, else the single legacy
  /// key; empty means signature enforcement is disabled.
  List<String> get trustedSigningKeys => signingPublicKeys.isNotEmpty
      ? signingPublicKeys
      : signingPublicKeyBase64.isEmpty
      ? const []
      : [signingPublicKeyBase64];

  /// If non-empty, the manifest and download hosts must be in this allowlist.
  final List<String> allowedHosts;

  /// Default manifest URL when [check] is called without one.
  final String manifestUrl;

  /// Default channel when [check] is called without one.
  final String channel;

  /// Injectable HTTP client (mainly for tests); defaults to a shared client.
  final http.Client? httpClient;

  http.Client get _client => httpClient ?? _sharedClient;
  static final http.Client _sharedClient = http.Client();

  Future<AppUpdate?> check({
    String? manifestUrl,
    String? channel,
    required String currentVersion,
    UpdateVerifiedCallback? onVerified,
    void Function(Duration elapsed)? onLatency,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await _checkInner(
        manifestUrl: manifestUrl,
        channel: channel,
        currentVersion: currentVersion,
        onVerified: onVerified,
      );
    } finally {
      stopwatch.stop();
      // Reported on success, up-to-date, AND failure — slow-network cases are
      // exactly the ones worth surfacing.
      onLatency?.call(stopwatch.elapsed);
    }
  }

  Future<AppUpdate?> _checkInner({
    String? manifestUrl,
    String? channel,
    required String currentVersion,
    UpdateVerifiedCallback? onVerified,
  }) async {
    final effectiveManifestUrl = manifestUrl ?? this.manifestUrl;
    final effectiveChannel = channel ?? this.channel;
    final manifestUri = Uri.parse(effectiveManifestUrl);
    if (manifestUri.scheme != 'https') {
      throw const FormatException('URL manifest update harus memakai HTTPS.');
    }
    _requireAllowedHost(manifestUri, 'Manifest');
    final response = await _client
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
            .where((item) => item.channel == effectiveChannel)
            .toList()
          ..sort((left, right) => compareVersions(right.version, left.version));
    if (releases.isEmpty ||
        compareVersions(releases.first.version, currentVersion) <= 0) {
      return null;
    }
    // Only a validly signed release may be presented as available; a tampered
    // manifest must not even reach the user as an install offer. Any trusted
    // key may sign it (key-ring rotation); report which one verified it.
    final keys = trustedSigningKeys;
    if (keys.isNotEmpty) {
      final matched = await matchingSigningKey(releases.first, keys);
      if (matched == null) {
        throw StateError('Tanda tangan update tidak valid atau tidak ada.');
      }
      onVerified?.call(matched);
    } else {
      onVerified?.call(null);
    }
    return releases.first;
  }

  Future<File> downloadAndVerify(
    AppUpdate update,
    String destination, {
    UpdateVerifiedCallback? onVerified,
  }) async {
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
    // over (version, downloadUrl, sha256) before trusting any of them. Any
    // trusted key may sign it (key-ring rotation); report which one verified it.
    final keys = trustedSigningKeys;
    if (keys.isNotEmpty) {
      final matched = await matchingSigningKey(update, keys);
      if (matched == null) {
        throw StateError('Tanda tangan update tidak valid atau tidak ada.');
      }
      onVerified?.call(matched);
    } else {
      onVerified?.call(null);
    }
    final response = await _client
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

  /// Key-ring verification: accepts when ANY of [trustedKeys] validates the
  /// release. Structured per-key signatures are checked against their paired
  /// key; a legacy single [AppUpdate.signature] (unknown signer) is tried
  /// against every trusted key.
  static Future<bool> verifySignatureWithAny(
    AppUpdate update,
    List<String> trustedKeys,
  ) async => await matchingSigningKey(update, trustedKeys) != null;

  /// The trusted key that validated [update], or null when none did (or the
  /// list is empty). Useful to report which key verified the last update.
  static Future<String?> matchingSigningKey(
    AppUpdate update,
    List<String> trustedKeys,
  ) async {
    if (trustedKeys.isEmpty) return null;
    for (final key in trustedKeys) {
      for (final entry in update.signatures) {
        if (entry.publicKey == key &&
            await _verify(update, entry.signature, key)) {
          return key;
        }
      }
    }
    if (update.signature.isNotEmpty) {
      for (final key in trustedKeys) {
        if (await _verify(update, update.signature, key)) return key;
      }
    }
    return null;
  }

  /// Verifies [update.signature] against a single public key (legacy form).
  static Future<bool> verifySignature(
    AppUpdate update,
    String publicKeyBase64,
  ) => _verify(update, update.signature, publicKeyBase64);

  static Future<bool> _verify(
    AppUpdate update,
    String signatureBase64,
    String publicKeyBase64,
  ) async {
    if (signatureBase64.isEmpty || publicKeyBase64.isEmpty) return false;
    try {
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );
      return await Ed25519().verify(
        utf8.encode(canonicalUpdatePayload(update)),
        signature: Signature(
          base64Decode(signatureBase64),
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
