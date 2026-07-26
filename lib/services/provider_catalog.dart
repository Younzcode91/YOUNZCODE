import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

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
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(
          Uri.parse('$base/models'),
          headers: {
            ...headers,
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Provider mengembalikan HTTP ${response.statusCode}.',
      );
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
