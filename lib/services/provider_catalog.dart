import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

class ProviderCatalogException implements Exception {
  const ProviderCatalogException(this.message, {this.statusCode});

  factory ProviderCatalogException.fromResponse(
    Uri endpoint,
    http.Response response,
  ) {
    final detail = _providerErrorDetail(response.body);
    if (response.statusCode == 401) {
      final agentRouterClientRejected =
          endpoint.host.toLowerCase() == 'agentrouter.org' &&
          detail.toLowerCase().contains('unauthorized client detected');
      if (agentRouterClientRejected) {
        return ProviderCatalogException(
          'HTTP 401: AgentRouter menolak identitas client YOUNZCODE. '
          'Base URL sudah benar (${endpoint.origin}/v1), tetapi provider '
          'membatasi client yang boleh memakai API. Hubungi dukungan '
          'AgentRouter untuk meminta YOUNZCODE diizinkan/di-whitelist.'
          '${detail.isEmpty ? '' : ' Detail provider: $detail'}',
          statusCode: response.statusCode,
        );
      }
      return ProviderCatalogException(
        'HTTP 401: API key tidak dikirim, tidak valid, atau tidak aktif. '
        'Isi API KEY sebelum menekan Fetch dan pastikan key memang dibuat '
        'untuk endpoint ini.'
        '${detail.isEmpty ? '' : ' Detail provider: $detail'}',
        statusCode: response.statusCode,
      );
    }
    return ProviderCatalogException(
      'Provider mengembalikan HTTP ${response.statusCode}'
      '${detail.isEmpty ? '.' : ': $detail'}',
      statusCode: response.statusCode,
    );
  }

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Fetches available model ids from an OpenAI-compatible `{baseUrl}/models`
/// endpoint. Tolerates the common response shapes: `{data: [{id}]}` (OpenAI),
/// `{models: [...]}`, or a bare list. Returns a sorted, de-duplicated list.
Future<List<String>> fetchProviderModels(
  String baseUrl,
  String apiKey, {
  Map<String, String> headers = const {},
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final base = normalizeProviderBaseUrl(baseUrl);
  final endpoint = Uri.parse('$base/models');
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(
          endpoint,
          headers: {
            ...headers,
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderCatalogException.fromResponse(endpoint, response);
    }
    final decoded = jsonDecode(response.body);
    final rawList = decoded is List
        ? decoded
        : decoded is Map
        ? (decoded['data'] ?? decoded['models'] ?? const [])
        : const [];
    final ids = <String>{};
    for (final entry in rawList is List ? rawList : const []) {
      final id = entry is Map ? (entry['id'] ?? entry['name']) : entry;
      if (id is String && id.trim().isNotEmpty) ids.add(id.trim());
    }
    return ids.toList()..sort();
  } finally {
    if (client == null) httpClient.close();
  }
}

String _providerErrorDetail(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final error = decoded['error'];
      final detail = error is Map
          ? error['message']
          : error is String
          ? error
          : decoded['message'] ?? decoded['msg'];
      if (detail is String && detail.trim().isNotEmpty) {
        return _safeProviderDetail(detail);
      }
    }
  } catch (_) {
    // Fall back to a short plain-text response below.
  }
  if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) {
    return '';
  }
  return _safeProviderDetail(trimmed);
}

String _safeProviderDetail(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return compact.length <= 240 ? compact : '${compact.substring(0, 240)}...';
}
