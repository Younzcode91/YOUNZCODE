import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/services/update_ping_service.dart';

void main() {
  test('tidak mengirim apa pun bila endpoint tidak dikonfigurasi', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('accepted', 200);
    });
    final service = UpdatePingService(endpointUrl: '', httpClient: client);
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: true,
    );
    expect(requests, 0);
  });

  test('tidak mengirim apa pun saat telemetri dimatikan', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('accepted', 200);
    });
    final service = UpdatePingService(
      endpointUrl: 'https://ping.younz.test/ping',
      httpClient: client,
    );
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: false,
    );
    expect(requests, 0);
  });

  test('menolak endpoint non-HTTPS', () async {
    final service = UpdatePingService(
      endpointUrl: 'http://ping.younz.test/ping',
      allowedHosts: const ['ping.younz.test'],
      httpClient: MockClient((request) async => http.Response('ok', 200)),
    );
    await expectLater(
      service.ping(
        version: '1.3.6',
        channel: 'stable',
        os: 'windows',
        installId: 'install-1',
        enabled: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('menolak host di luar allowlist', () async {
    final service = UpdatePingService(
      endpointUrl: 'https://evil.example.test/ping',
      allowedHosts: const ['ping.younz.test'],
      httpClient: MockClient((request) async => http.Response('ok', 200)),
    );
    await expectLater(
      service.ping(
        version: '1.3.6',
        channel: 'stable',
        os: 'windows',
        installId: 'install-1',
        enabled: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('mengirim POST dengan payload versi yang benar', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('accepted', 200);
    });
    final service = UpdatePingService(
      endpointUrl: 'https://ping.younz.test/ping',
      allowedHosts: const ['ping.younz.test'],
      httpClient: client,
    );
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: true,
    );

    expect(captured.method, 'POST');
    expect(captured.url.toString(), 'https://ping.younz.test/ping');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['version'], '1.3.6');
    expect(body['channel'], 'stable');
    expect(body['os'], 'windows');
    expect(body['install_id'], 'install-1');
    expect(DateTime.tryParse('${body['timestamp']}'), isNotNull);
  });

  test('rate limit: ping kedua dalam interval dilewati', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('accepted', 200);
    });
    final service = UpdatePingService(
      endpointUrl: 'https://ping.younz.test/ping',
      allowedHosts: const ['ping.younz.test'],
      minInterval: const Duration(hours: 1),
      httpClient: client,
    );
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: true,
    );
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: true,
    );
    expect(requests, 1);
  });

  test('kegagalan transport ditelan tanpa melempar', () async {
    final client = MockClient(
      (request) async => throw http.ClientException('down'),
    );
    final service = UpdatePingService(
      endpointUrl: 'https://ping.younz.test/ping',
      allowedHosts: const ['ping.younz.test'],
      httpClient: client,
    );
    await service.ping(
      version: '1.3.6',
      channel: 'stable',
      os: 'windows',
      installId: 'install-1',
      enabled: true,
    );
  });
}
