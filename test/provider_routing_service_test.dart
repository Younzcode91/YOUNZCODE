import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/agent_service.dart';
import 'package:kode_agent_desktop/services/provider_routing_service.dart';

void main() {
  test('memilih fallback sehat setelah provider utama gagal', () async {
    final probed = <String>[];
    final router = ProviderRoutingService(
      probe: (route, _, _) async {
        probed.add(route.baseUrl);
        return route.baseUrl == 'https://healthy.test/v1';
      },
    );
    final routes = router.routes(
      primaryBaseUrl: 'https://primary.test/v1',
      model: 'model-a',
      fallbackBaseUrls: [
        'https://down.test/v1',
        'https://healthy.test/v1',
        'https://healthy.test/v1/',
      ],
    );

    final selected = await router.selectFallback(
      error: const AgentHttpException('unavailable', statusCode: 503),
      currentBaseUrl: routes.first.baseUrl,
      routes: routes,
      apiKey: 'key',
      headers: const {},
    );

    expect(selected?.baseUrl, 'https://healthy.test/v1');
    expect(probed, ['https://down.test/v1', 'https://healthy.test/v1']);
    expect(routes, hasLength(3));
  });

  test('tidak failover untuk authentication error', () {
    expect(
      ProviderRoutingService.shouldFailover(
        const AgentHttpException('unauthorized', statusCode: 401),
      ),
      isFalse,
    );
  });

  test('failover saat provider berulang kali memberi respons kosong', () {
    expect(
      ProviderRoutingService.shouldFailover(
        const AgentEmptyResponseException(),
      ),
      isTrue,
    );
  });
}
