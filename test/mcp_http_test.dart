import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/models/addon.dart';
import 'package:kode_agent_desktop/services/mcp_client.dart';

MockClient _server({bool sseToolCall = false}) {
  return MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final method = body['method'];
    final id = body['id'];
    if (method == 'notifications/initialized') {
      return http.Response('', 202); // notification, no id
    }
    Map<String, dynamic> result;
    switch (method) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'test', 'version': '1'},
        };
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
          200,
          headers: {
            'content-type': 'application/json',
            'mcp-session-id': 'sess-123',
          },
        );
      case 'tools/list':
        result = {
          'tools': [
            {
              'name': 'echo',
              'description': 'Echo a value',
              'inputSchema': {'type': 'object'},
            },
          ],
        };
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
          200,
          headers: {'content-type': 'application/json'},
        );
      case 'tools/call':
        // Session id must be echoed on non-initialize requests.
        expect(request.headers['mcp-session-id'], 'sess-123');
        result = {
          'content': [
            {'type': 'text', 'text': 'halo mcp'},
          ],
        };
        final payload = jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        });
        if (sseToolCall) {
          return http.Response(
            'event: message\ndata: $payload\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      default:
        return http.Response('{}', 400);
    }
  });
}

McpClient _client(MockClient server) => McpClient(
  const McpServerConfig(
    name: 'remote',
    transport: McpTransport.http,
    url: 'https://mcp.test/rpc',
  ),
  workspace: '.',
  httpClient: server,
);

void main() {
  test('MCP HTTP initialize + tools/list + tools/call (JSON)', () async {
    final client = _client(_server());
    addTearDown(client.dispose);

    var approvedUrl = '';
    await client.initialize(
      approveLaunch: (command, arguments) async {
        approvedUrl = command;
        return true;
      },
    );

    expect(approvedUrl, 'https://mcp.test/rpc');
    expect(client.tools.map((tool) => tool.name), ['echo']);
    expect(await client.callTool('echo', {'value': 'x'}), 'halo mcp');
  });

  test('MCP HTTP menangani respons tool/call ber-SSE', () async {
    final client = _client(_server(sseToolCall: true));
    addTearDown(client.dispose);
    await client.initialize(approveLaunch: (_, _) async => true);
    expect(await client.callTool('echo', {}), 'halo mcp');
  });

  test('MCP HTTP menolak peluncuran yang tidak disetujui', () async {
    final client = _client(_server());
    addTearDown(client.dispose);
    await expectLater(
      client.initialize(approveLaunch: (_, _) async => false),
      throwsA(isA<StateError>()),
    );
  });

  test('MCP HTTP menolak URL non-HTTPS non-loopback', () async {
    final client = McpClient(
      const McpServerConfig(
        name: 'insecure',
        transport: McpTransport.http,
        url: 'http://mcp.evil/rpc',
      ),
      workspace: '.',
      httpClient: _server(),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.initialize(approveLaunch: (_, _) async => true),
      throwsA(isA<StateError>()),
    );
  });
}
