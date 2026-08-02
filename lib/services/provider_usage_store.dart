import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ProviderUsageRecord {
  const ProviderUsageRecord({
    required this.timestamp,
    required this.baseUrl,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.estimatedCostUsd,
  });

  factory ProviderUsageRecord.fromJson(Map<String, dynamic> json) =>
      ProviderUsageRecord(
        timestamp: DateTime.parse(json['timestamp'] as String),
        baseUrl: json['baseUrl'] as String,
        model: json['model'] as String,
        promptTokens: json['promptTokens'] as int? ?? 0,
        completionTokens: json['completionTokens'] as int? ?? 0,
        totalTokens: json['totalTokens'] as int? ?? 0,
        estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0,
      );

  final DateTime timestamp;
  final String baseUrl;
  final String model;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final double estimatedCostUsd;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'baseUrl': baseUrl,
    'model': model,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'estimatedCostUsd': estimatedCostUsd,
  };
}

class ProviderUsageSummary {
  const ProviderUsageSummary({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.estimatedCostUsd,
    required this.byRoute,
  });

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final double estimatedCostUsd;
  final Map<String, int> byRoute;
}

class ProviderUsageStore {
  ProviderUsageStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _storageKey = 'provider_usage_v1';
  final Future<SharedPreferences> Function() _preferences;
  Future<void> _mutation = Future.value();

  Future<List<ProviderUsageRecord>> load(String workspace) async {
    if (workspace.isEmpty) return const [];
    final preferences = await _preferences();
    final all = _decode(preferences.getString(_storageKey));
    final raw = all[workspace];
    if (raw is! List) return const [];
    final records = <ProviderUsageRecord>[];
    for (final item in raw.whereType<Map>()) {
      try {
        records.add(
          ProviderUsageRecord.fromJson(Map<String, dynamic>.from(item)),
        );
      } on FormatException {
        // Skip malformed historical entries.
      }
    }
    records.sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return records;
  }

  Future<void> record(String workspace, ProviderUsageRecord record) {
    if (workspace.isEmpty || record.totalTokens <= 0) return Future.value();
    return _locked(() async {
      final preferences = await _preferences();
      final all = _decode(preferences.getString(_storageKey));
      final current = (all[workspace] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      current.insert(0, record.toJson());
      all[workspace] = current.take(1000).toList();
      await preferences.setString(_storageKey, jsonEncode(all));
    });
  }

  Future<void> clear(String workspace) => _locked(() async {
    final preferences = await _preferences();
    final all = _decode(preferences.getString(_storageKey));
    all.remove(workspace);
    await preferences.setString(_storageKey, jsonEncode(all));
  });

  Future<void> _locked(Future<void> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.catchError((_) {});
    return result;
  }

  static ProviderUsageSummary summarize(
    Iterable<ProviderUsageRecord> records, {
    DateTime? since,
  }) {
    var prompt = 0;
    var completion = 0;
    var total = 0;
    var cost = 0.0;
    final byRoute = <String, int>{};
    for (final record in records) {
      if (since != null && record.timestamp.isBefore(since)) continue;
      prompt += record.promptTokens;
      completion += record.completionTokens;
      total += record.totalTokens;
      cost += record.estimatedCostUsd;
      final route =
          '${record.model} · ${Uri.tryParse(record.baseUrl)?.host ?? record.baseUrl}';
      byRoute[route] = (byRoute[route] ?? 0) + record.totalTokens;
    }
    return ProviderUsageSummary(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      estimatedCostUsd: cost,
      byRoute: byRoute,
    );
  }

  static double estimateCost({
    required int promptTokens,
    required int completionTokens,
    required double inputCostPerMillion,
    required double outputCostPerMillion,
  }) =>
      (promptTokens / 1000000 * inputCostPerMillion) +
      (completionTokens / 1000000 * outputCostPerMillion);

  static Map<String, dynamic> _decode(String? value) {
    if (value == null || value.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } on FormatException {
      return {};
    }
  }
}
