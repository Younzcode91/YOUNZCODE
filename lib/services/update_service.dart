import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.channel,
    required this.notes,
    required this.downloadUrl,
    required this.sha256,
  });

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
    version: '${json['version'] ?? ''}',
    channel: '${json['channel'] ?? 'stable'}',
    notes: '${json['notes'] ?? ''}',
    downloadUrl: '${json['download_url'] ?? ''}',
    sha256: '${json['sha256'] ?? ''}'.toLowerCase(),
  );

  final String version;
  final String channel;
  final String notes;
  final String downloadUrl;
  final String sha256;
}

class UpdateService {
  const UpdateService();

  Future<AppUpdate?> check({
    required String manifestUrl,
    required String channel,
    required String currentVersion,
  }) async {
    final manifestUri = Uri.parse(manifestUrl);
    if (manifestUri.scheme != 'https') {
      throw const FormatException('URL manifest update harus memakai HTTPS.');
    }
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
    final response = await http
        .get(downloadUri)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Download update HTTP ${response.statusCode}');
    }
    final file = File(destination);
    await file.writeAsBytes(response.bodyBytes, flush: true);
    final result = await Process.run('certutil.exe', [
      '-hashfile',
      file.path,
      'SHA256',
    ]);
    if (result.exitCode != 0) throw StateError('Verifikasi SHA-256 gagal.');
    final hash = RegExp(
      r'\b[A-Fa-f0-9]{64}\b',
    ).firstMatch('${result.stdout}')?.group(0);
    if (hash?.toLowerCase() != update.sha256) {
      await file.delete();
      throw StateError('Checksum installer tidak cocok; file dihapus.');
    }
    return file;
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
