import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/services/provider_catalog.dart';

void main() {
  test('mem-parse bentuk OpenAI {data:[{id}]} terurut & unik', () async {
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/models'));
      expect(request.headers['authorization'], 'Bearer secret');
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'gpt-4o'},
            {'id': 'gpt-4.1'},
            {'id': 'gpt-4o'}, // duplicate
          ],
        }),
        200,
      );
    });

    final models = await fetchProviderModels(
      'https://api.openai.com/v1',
      'secret',
      client: client,
    );
    expect(models, ['gpt-4.1', 'gpt-4o']);
  });

  test('mendukung bentuk {models:[...]} dan list telanjang', () async {
    final mapShape = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'models': [
            {'name': 'gemini-2.5-pro'},
          ],
        }),
        200,
      ),
    );
    expect(
      await fetchProviderModels('https://x.test/v1', '', client: mapShape),
      ['gemini-2.5-pro'],
    );

    final listShape = MockClient(
      (_) async => http.Response(jsonEncode(['a-model', 'b-model']), 200),
    );
    expect(
      await fetchProviderModels('https://x.test/v1', '', client: listShape),
      ['a-model', 'b-model'],
    );
  });

  test('melempar pada status non-2xx', () async {
    final client = MockClient((_) async => http.Response('nope', 401));
    await expectLater(
      fetchProviderModels('https://x.test/v1', 'k', client: client),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('menolak Base URL non-HTTPS non-loopback', () async {
    final client = MockClient((_) async => http.Response('[]', 200));
    await expectLater(
      fetchProviderModels('http://evil.test/v1', 'k', client: client),
      throwsA(isA<FormatException>()),
    );
  });
}
