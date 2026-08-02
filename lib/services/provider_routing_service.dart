import 'dart:async';

import 'package:http/http.dart' as http;

import 'agent_errors.dart';
import 'settings_store.dart';

class ProviderRoute {
  const ProviderRoute({required this.baseUrl, required this.model});

  final String baseUrl;
  final String model;
}

typedef ProviderProbe =
    Future<bool> Function(
      ProviderRoute route,
      String apiKey,
      Map<String, String> headers,
    );

class ProviderRoutingService {
  ProviderRoutingService({ProviderProbe? probe})
    : _probe = probe ?? _defaultProbe;

  final ProviderProbe _probe;

  List<ProviderRoute> routes({
    required String primaryBaseUrl,
    required String model,
    required List<String> fallbackBaseUrls,
  }) {
    final seen = <String>{};
    final routes = <ProviderRoute>[];
    for (final candidate in [primaryBaseUrl, ...fallbackBaseUrls]) {
      try {
        final normalized = normalizeProviderBaseUrl(candidate);
        if (seen.add(normalized)) {
          routes.add(ProviderRoute(baseUrl: normalized, model: model));
        }
      } on FormatException {
        // Invalid persisted fallback entries are ignored.
      }
    }
    return routes;
  }

  Future<ProviderRoute?> selectFallback({
    required Object error,
    required String currentBaseUrl,
    required List<ProviderRoute> routes,
    required String apiKey,
    required Map<String, String> headers,
  }) async {
    if (!shouldFailover(error)) return null;
    final current = normalizeProviderBaseUrl(currentBaseUrl);
    final currentIndex = routes.indexWhere((route) => route.baseUrl == current);
    for (final route in routes.skip(currentIndex < 0 ? 0 : currentIndex + 1)) {
      if (await _probe(route, apiKey, headers)) return route;
    }
    return null;
  }

  static bool shouldFailover(Object error) {
    if (error is AgentEmptyResponseException) return true;
    if (error is TimeoutException || error is http.ClientException) return true;
    if (error is AgentHttpException) {
      final status = error.statusCode;
      return status == null ||
          status == 408 ||
          status == 425 ||
          status == 429 ||
          (status >= 500 && status <= 599);
    }
    return false;
  }

  static Future<bool> _defaultProbe(
    ProviderRoute route,
    String apiKey,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('${route.baseUrl}/models'),
            headers: {
              ...headers,
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
