import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
  McpClient(this.config, {required this.workspace, http.Client? httpClient})
    : _injectedHttpClient = httpClient;

  final McpServerConfig config;
  final String workspace;
  final http.Client? _injectedHttpClient;
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  http.Client? _httpClient; // active client for Streamable HTTP transport
  String? _sessionId;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _sequence = 1;
  List<McpTool> _tools = const [];

  bool get _isHttp => config.transport == McpTransport.http;

  List<McpTool> get tools => _tools;

  Future<void> initialize({required McpLaunchApproval approveLaunch}) async {
    if (_isHttp) {
      await _initializeHttp(approveLaunch);
      return;
    }
    if (_process != null) return;
    if (config.command == null) {
      throw StateError('MCP stdio server requires a command.');
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
      'clientInfo': {'name': 'YOUNZCODE', 'version': '1.1.0'},
    });
    _notify('notifications/initialized');
    await refreshTools();
  }

  Future<void> _initializeHttp(McpLaunchApproval approveLaunch) async {
    if (_httpClient != null) return;
    final url = config.url?.trim() ?? '';
    final uri = Uri.tryParse(url);
    if (url.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        !(uri.isScheme('https') || _isLoopback(uri))) {
      throw StateError('MCP HTTP url must use HTTPS (or a loopback address).');
    }
    if (!await approveLaunch(url, const [])) {
      throw StateError('MCP server launch was denied.');
    }
    _httpClient = _injectedHttpClient ?? http.Client();
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': {},
      'clientInfo': {'name': 'YOUNZCODE', 'version': '1.1.0'},
    });
    _notify('notifications/initialized');
    await refreshTools();
  }

  static bool _isLoopback(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '::1' || host.startsWith('127.');
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
    if (_isHttp) return _httpRequest(method, params);
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
    if (_isHttp) {
      unawaited(
        _httpRequest(
          method,
          params,
          isNotification: true,
        ).catchError((_) => const <String, dynamic>{}),
      );
      return;
    }
    _process?.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  Future<Map<String, dynamic>> _httpRequest(
    String method,
    Map<String, dynamic>? params, {
    bool isNotification = false,
  }) async {
    final client = _httpClient;
    final url = config.url;
    if (client == null || url == null) {
      throw StateError('MCP HTTP client is not running.');
    }
    final id = _sequence++;
    final response = await client
        .post(
          Uri.parse(url),
          headers: {
            ...config.headers,
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'Mcp-Session-Id': ?_sessionId,
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            if (!isNotification) 'id': id,
            'method': method,
            'params': ?params,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;
    if (isNotification) return const {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'MCP ${config.name} HTTP ${response.statusCode}: ${response.body}',
      );
    }
    return _extractJsonRpcResult(response, id, method);
  }

  Map<String, dynamic> _extractJsonRpcResult(
    http.Response response,
    int id,
    String method,
  ) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    final body = utf8.decode(response.bodyBytes);
    final messages = <Map<String, dynamic>>[];
    if (contentType.contains('text/event-stream')) {
      for (final line in const LineSplitter().convert(body)) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final decoded = _tryDecode(data);
        if (decoded is Map) messages.add(Map<String, dynamic>.from(decoded));
      }
    } else {
      final decoded = _tryDecode(body);
      if (decoded is Map) {
        messages.add(Map<String, dynamic>.from(decoded));
      } else if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) messages.add(Map<String, dynamic>.from(item));
        }
      }
    }
    for (final message in messages) {
      if (message['method'] == 'notifications/tools/list_changed') {
        unawaited(refreshTools().catchError((_) {}));
      }
    }
    for (final message in messages) {
      if (message['id'] != id) continue;
      if (message['error'] != null) {
        throw StateError('MCP ${config.name}: ${message['error']}');
      }
      return Map<String, dynamic>.from(message['result'] as Map? ?? const {});
    }
    throw StateError('MCP ${config.name}: tidak ada respons untuk $method.');
  }

  static Object? _tryDecode(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
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
    if (_isHttp) {
      final client = _httpClient;
      _httpClient = null;
      _sessionId = null;
      if (_injectedHttpClient == null) client?.close();
      return;
    }
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
