import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/provider_usage_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('mencatat penggunaan dan menghitung estimasi biaya', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ProviderUsageStore();
    final cost = ProviderUsageStore.estimateCost(
      promptTokens: 1000000,
      completionTokens: 500000,
      inputCostPerMillion: 2,
      outputCostPerMillion: 8,
    );
    await store.record(
      'workspace',
      ProviderUsageRecord(
        timestamp: DateTime(2026, 7, 27),
        baseUrl: 'https://provider.test/v1',
        model: 'model-a',
        promptTokens: 1000000,
        completionTokens: 500000,
        totalTokens: 1500000,
        estimatedCostUsd: cost,
      ),
    );

    final records = await store.load('workspace');
    final summary = ProviderUsageStore.summarize(records);
    expect(summary.totalTokens, 1500000);
    expect(summary.estimatedCostUsd, 6);
    expect(summary.byRoute.values.single, 1500000);
  });
}
