import 'dart:convert';

import 'package:http/http.dart' as http;

/// HTTPS endpoint the app pings with its installed version so release
/// engineers can measure true fleet adoption (see tool/ping_server.dart for a
/// reference implementation). Empty disables telemetry — set it to your
/// deployed collector and add its host to [updatePingAllowedHosts].
const updatePingEndpointUrl = '';

/// Hosts allowed to receive pings. Empty means only HTTPS is enforced; set it
/// alongside [updatePingEndpointUrl].
const updatePingAllowedHosts = <String>[];

/// Minimum interval between pings per install (politeness + bounded data).
const updatePingMinInterval = Duration(hours: 1);

/// Fire-and-forget fleet telemetry: reports the INSTALLED version (plus
/// channel, os, and an install id) to the configured endpoint. No personal
/// data — the install id is a random opaque token generated once per install.
/// Never throws on transport errors and is safe to call with `unawaited`.
///
/// The server stores only what is needed for adoption math (see
/// tool/ping_server.dart); the retire gate (tool/retire_signing_key.dart)
/// counts distinct installs per version to replace the nightly-run proxy once
/// telemetry is available.
class UpdatePingService {
  UpdatePingService({
    this.endpointUrl = updatePingEndpointUrl,
    this.allowedHosts = updatePingAllowedHosts,
    this.minInterval = updatePingMinInterval,
    this.httpClient,
  });

  final String endpointUrl;
  final List<String> allowedHosts;
  final Duration minInterval;
  final http.Client? httpClient;

  DateTime? _lastPingAt;

  http.Client get _client => httpClient ?? _sharedClient;
  static final http.Client _sharedClient = http.Client();

  /// Reports the installed [version]. Configuration errors (disabled,
  /// non-HTTPS, host not allowlisted) throw so misconfiguration is visible in
  /// tests; transport failures are swallowed — telemetry must never disturb
  /// the app.
  Future<void> ping({
    required String version,
    required String channel,
    required String os,
    required String installId,
    required bool enabled,
  }) async {
    if (!enabled || endpointUrl.isEmpty) return;
    final now = DateTime.now().toUtc();
    if (_lastPingAt != null && now.difference(_lastPingAt!) < minInterval) {
      return;
    }
    final uri = Uri.parse(endpointUrl);
    if (uri.scheme != 'https') {
      throw const FormatException('Update ping endpoint harus memakai HTTPS.');
    }
    if (allowedHosts.isNotEmpty &&
        !allowedHosts.contains(uri.host.toLowerCase())) {
      throw FormatException('Update ping host ${uri.host} tidak diizinkan.');
    }
    _lastPingAt = now;
    try {
      await _client
          .post(
            uri,
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'version': version,
              'channel': channel,
              'os': os,
              'install_id': installId,
              'timestamp': now.toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Telemetry failures are dropped silently.
    }
  }
}
