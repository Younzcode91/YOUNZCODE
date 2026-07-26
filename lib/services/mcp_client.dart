import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/addon.dart';

typedef McpLaunchApproval =
    Future<bool> Function(String command, List<String> arguments);

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

class McpClient {
  McpClient(this.config, {required this.workspace});

  final McpServerConfig config;
  final String workspace;
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _sequence = 1;
  List<McpTool> _tools = const [];

  List<McpTool> get tools => _tools;

  Future<void> initialize({required McpLaunchApproval approveLaunch}) async {
    if (_process != null) return;
    if (config.transport != McpTransport.stdio || config.command == null) {
      throw StateError('Only MCP stdio is executable in this version.');
    }
    if (!await approveLaunch(config.command!, config.arguments)) {
      throw StateError('MCP server launch was denied.');
    }
    final process = await Process.start(
      config.command!,
      config.arguments,
      workingDirectory: workspace,
      environment: {...Platform.environment, ...config.environment},
      runInShell: Platform.isWindows,
    );
    _process = process;
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderr = process.stderr.transform(utf8.decoder).listen((_) {});
    unawaited(process.exitCode.then((_) => _closePending()));
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': {},
      'clientInfo': {'name': 'YOUNZCODE', 'version': '1.0.1'},
    });
    _notify('notifications/initialized');
    await refreshTools();
  }

  Future<void> refreshTools() async {
    final result = await _request('tools/list');
    final values = result['tools'] as List? ?? const [];
    final tools = <McpTool>[];
    for (final value in values) {
      if (value is! Map) continue;
      final tool = Map<String, dynamic>.from(value);
      final name = tool['name'];
      if (name is! String || name.isEmpty) continue; // skip malformed entry
      tools.add(
        McpTool(
          name: name,
          description: tool['description'] as String? ?? '',
          inputSchema: tool['inputSchema'] is Map
              ? Map<String, dynamic>.from(tool['inputSchema'] as Map)
              : const {'type': 'object'},
        ),
      );
    }
    _tools = tools;
  }

  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final output = <String>[];
    for (final raw in result['content'] as List? ?? const []) {
      final content = Map<String, dynamic>.from(raw as Map);
      if (content['type'] == 'text') output.add('${content['text'] ?? ''}');
    }
    if (result['structuredContent'] != null) {
      output.add(jsonEncode(result['structuredContent']));
    }
    if (output.isEmpty) output.add(jsonEncode(result));
    return '${result['isError'] == true ? 'MCP error: ' : ''}${output.join('\n')}';
  }

  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final process = _process;
    if (process == null) throw StateError('MCP server is not running.');
    final id = _sequence++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    await process.stdin.flush();
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
          'MCP server ${config.name} did not answer $method.',
        );
      },
    );
  }

  void _notify(String method, [Map<String, dynamic>? params]) {
    _process?.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (message['method'] == 'notifications/tools/list_changed') {
        // Fire-and-forget refresh must swallow its own errors; otherwise a
        // malformed tools/list or a timeout becomes an unhandled async crash.
        unawaited(refreshTools().catchError((_) {}));
        return;
      }
      final id = message['id'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (message['error'] != null) {
        completer.completeError(
          StateError('MCP ${config.name}: ${message['error']}'),
        );
      } else {
        completer.complete(
          Map<String, dynamic>.from(message['result'] as Map? ?? const {}),
        );
      }
    } catch (_) {
      // Non-protocol stdout is ignored; well-behaved MCP servers log to stderr.
    }
  }

  void _closePending() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('MCP server ${config.name} stopped.'),
        );
      }
    }
    _pending.clear();
    _process = null;
  }

  Future<void> dispose() async {
    final process = _process;
    _process = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    try {
      await process?.stdin.close();
    } catch (_) {
      // A broken pipe / already-exited process must not skip the kill below.
    }
    if (process != null) await _terminateProcessTree(process);
    _closePending();
  }

  static Future<void> _terminateProcessTree(Process process) async {
    final exitCode = process.exitCode;
    if (Platform.isWindows) {
      try {
        await Process.run(
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
          r'\System32\taskkill.exe',
          ['/PID', '${process.pid}', '/T', '/F'],
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    } else {
      process.kill(ProcessSignal.sigkill);
    }
    await exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }
}
