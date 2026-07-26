import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/addon.dart';
import 'package:kode_agent_desktop/services/mcp_client.dart';

void main() {
  test('MCP stdio menemukan dan menjalankan tool', () async {
    final directory = await Directory.systemTemp.createTemp('younzcode-mcp-');
    addTearDown(() => directory.delete(recursive: true));
    final server = File(
      '${directory.path}${Platform.pathSeparator}server.dart',
    );
    await server.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['id'] == null) continue;
    final method = message['method'];
    Object result = {};
    if (method == 'initialize') {
      result = {'protocolVersion': '2025-03-26', 'capabilities': {}, 'serverInfo': {'name': 'test', 'version': '1'}};
    } else if (method == 'tools/list') {
      result = {'tools': [{'name': 'echo', 'description': 'Echo text', 'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}}}]};
    } else if (method == 'tools/call') {
      result = {'content': [{'type': 'text', 'text': message['params']['arguments']['text']}], 'isError': false};
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result}));
  }
}
''');
    final client = McpClient(
      McpServerConfig(
        name: 'test-server',
        transport: McpTransport.stdio,
        command: 'dart',
        arguments: ['run', server.path],
      ),
      workspace: directory.path,
    );
    addTearDown(client.dispose);

    await client.initialize(approveLaunch: (_, _) async => true);
    expect(client.tools.single.name, 'echo');
    expect(await client.callTool('echo', {'text': 'hello MCP'}), 'hello MCP');
  });
}
