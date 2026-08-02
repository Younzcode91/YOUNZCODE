import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'agent_errors.dart';
import 'provider_adapter.dart';
import 'settings_store.dart';

typedef CompletionStatus = void Function(String status);
typedef CompletionInsight =
    void Function({
      String? reasoning,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens,
    });

class AgentCompletionClient {
  AgentCompletionClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.timeoutMs,
    required this.headers,
    required this.maxRequestAttempts,
    required this.retryBaseDelay,
    required this.onStatus,
    required this.isCancelled,
    required this.shouldStop,
    this.onInsight,
    http.Client? httpClient,
  }) : _injectedHttpClient = httpClient;

  final String baseUrl;
  final String apiKey;
  final String model;
  final int timeoutMs;
  final Map<String, String> headers;
  final int maxRequestAttempts;
  final Duration retryBaseDelay;
  final CompletionStatus onStatus;
  final bool Function() isCancelled;
  final bool Function() shouldStop;
  final CompletionInsight? onInsight;
  final http.Client? _injectedHttpClient;
  http.Client? _activeHttpClient;

  Future<Map<String, dynamic>> request({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, Object>> toolDefinitions,
    bool allowTools = true,
    String? finalInstruction,
  }) async {
    Object? lastError;
    var useStreaming = !_isLocal9Router;
    String? emptyRetryInstruction;
    for (var attempt = 1; attempt <= maxRequestAttempts; attempt++) {
      _throwIfCancelled();
      if (allowTools && shouldStop()) {
        throw const AgentCompletionStoppedException();
      }
      var switchingToCompatibleMode = false;
      try {
        return await _performRequest(
          messages: messages,
          toolDefinitions: toolDefinitions,
          stream: useStreaming,
          allowTools: allowTools,
          finalInstruction: _combineInstructions(
            finalInstruction,
            emptyRetryInstruction,
          ),
        );
      } on AgentEmptyResponseException catch (error) {
        lastError = error;
        if (attempt == maxRequestAttempts) rethrow;
        useStreaming = !useStreaming;
        switchingToCompatibleMode = true;
        emptyRetryInstruction =
            'Respons sebelumnya kosong. Berikan jawaban akhir yang berisi teks '
            'untuk pengguna. Jangan mengembalikan content kosong.';
      } on AgentHttpException catch (error) {
        lastError = error;
        if (!error.isRetryable || attempt == maxRequestAttempts) rethrow;
      } on TimeoutException catch (error) {
        lastError = error;
        if (attempt == maxRequestAttempts) rethrow;
      } on http.ClientException catch (error) {
        _throwIfCancelled();
        if (allowTools && shouldStop()) {
          throw const AgentCompletionStoppedException();
        }
        lastError = error;
        final nextStreamingMode = _isLocal9Router;
        switchingToCompatibleMode = useStreaming != nextStreamingMode;
        useStreaming = nextStreamingMode;
        if (attempt == maxRequestAttempts) rethrow;
      }
      final transportClosed = lastError is http.ClientException;
      final emptyResponse = lastError is AgentEmptyResponseException;
      onStatus(
        '${emptyResponse
            ? 'Respons provider kosong, meminta jawaban ulang'
            : switchingToCompatibleMode
            ? _isLocal9Router
                  ? 'Respons lokal terputus, beralih ke streaming'
                  : 'Streaming terputus, beralih ke mode kompatibel'
            : transportClosed
            ? 'Koneksi provider terputus'
            : 'Gangguan koneksi'}, '
        'mencoba ulang ($attempt/$maxRequestAttempts)',
      );
      final retryDelay = Duration(
        milliseconds: retryBaseDelay.inMilliseconds * (1 << (attempt - 1)),
      );
      if (retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw StateError('Request model gagal: $lastError');
  }

  String? _combineInstructions(String? first, String? second) {
    final values = [first, second]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    return values.isEmpty ? null : values.join('\n\n');
  }

  void closeActiveTransport() {
    if (identical(_activeHttpClient, _injectedHttpClient)) return;
    _activeHttpClient?.close();
    _activeHttpClient = null;
  }

  void dispose() {
    _activeHttpClient?.close();
    _activeHttpClient = null;
    _injectedHttpClient?.close();
  }

  bool get _isLocal9Router {
    final uri = Uri.tryParse(baseUrl);
    return uri != null &&
        uri.scheme == 'http' &&
        {'127.0.0.1', 'localhost'}.contains(uri.host.toLowerCase()) &&
        uri.port == 20128;
  }

  Future<Map<String, dynamic>> _performRequest({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, Object>> toolDefinitions,
    required bool stream,
    required bool allowTools,
    String? finalInstruction,
  }) async {
    final protocol = detectProviderProtocol(baseUrl);
    final native = protocol != ProviderProtocol.openai;
    final client = _injectedHttpClient ?? http.Client();
    _activeHttpClient = client;
    final requestMessages = <Map<String, dynamic>>[
      ...messages,
      if (finalInstruction != null)
        {'role': 'system', 'content': finalInstruction},
    ];
    final toolDefs = allowTools
        ? toolDefinitions
        : const <Map<String, Object>>[];
    final http.Request request;
    if (protocol == ProviderProtocol.anthropic) {
      final built = buildAnthropicRequest(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        messages: requestMessages,
        tools: toolDefs,
        extraHeaders: headers,
      );
      request = http.Request('POST', built.url)
        ..headers.addAll(built.headers)
        ..body = jsonEncode(built.body);
    } else if (protocol == ProviderProtocol.gemini) {
      final built = buildGeminiRequest(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        messages: requestMessages,
        tools: toolDefs,
        extraHeaders: headers,
      );
      request = http.Request('POST', built.url)
        ..headers.addAll(built.headers)
        ..body = jsonEncode(built.body);
    } else {
      final requestBaseUrl = normalizeProviderBaseUrl(baseUrl);
      final requestBody = <String, Object?>{
        'model': model,
        'messages': requestMessages,
        if (allowTools) 'tools': toolDefs,
        if (allowTools) 'tool_choice': 'auto',
        'stream': stream,
      };
      request =
          http.Request('POST', Uri.parse('$requestBaseUrl/chat/completions'))
            ..headers.addAll({
              ...headers,
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'Accept': stream
                  ? 'text/event-stream, application/json'
                  : 'application/json',
            })
            ..body = jsonEncode(requestBody);
    }
    final requestTimeout = Duration(
      milliseconds: timeoutMs > 0 ? timeoutMs : 120000,
    );
    try {
      final response = await client
          .send(request)
          .timeout(
            requestTimeout,
            onTimeout: () {
              if (_injectedHttpClient == null) client.close();
              throw TimeoutException(
                'Model tidak merespons dalam ${requestTimeout.inSeconds} detik.',
                requestTimeout,
              );
            },
          );
      final byteStream = response.stream.timeout(
        requestTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'Aliran respons model berhenti lebih dari '
              '${requestTimeout.inSeconds} detik.',
              requestTimeout,
            ),
          );
          sink.close();
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decodeStream(byteStream);
        throw AgentHttpException.fromParts(response.statusCode, body);
      }
      if (native) {
        final body = await utf8.decodeStream(byteStream);
        final decoded = jsonDecode(body);
        if (decoded is! Map) {
          throw const FormatException('Respons provider bukan objek JSON.');
        }
        final payload = Map<String, dynamic>.from(decoded);
        final result = protocol == ProviderProtocol.anthropic
            ? parseAnthropicResponse(payload)
            : parseGeminiResponse(payload);
        _emitInsight('', result.usage);
        return _normalizeAssistantMessage(result.message);
      }
      return await (stream
          ? _decodeCompletionStream(byteStream)
          : _decodeJsonCompletion(byteStream));
    } finally {
      if (identical(_activeHttpClient, client)) _activeHttpClient = null;
      if (_injectedHttpClient == null) client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeJsonCompletion(
    Stream<List<int>> byteStream,
  ) async {
    final bytes = BytesBuilder(copy: false);
    http.ClientException? transportError;
    try {
      await for (final chunk in byteStream) {
        _throwIfCancelled();
        bytes.add(chunk);
      }
    } on http.ClientException catch (error) {
      _throwIfCancelled();
      transportError = error;
    }
    final body = utf8.decode(bytes.takeBytes()).trim();
    if (body.isEmpty) {
      if (transportError != null) throw transportError;
      throw const AgentEmptyResponseException(
        'Provider mengembalikan body respons kosong.',
      );
    }
    try {
      final payload = jsonDecode(body);
      if (payload is! Map) {
        throw const FormatException('Respons provider bukan objek JSON.');
      }
      return _messageFromPayload(Map<String, dynamic>.from(payload));
    } catch (_) {
      if (transportError != null) throw transportError;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _decodeCompletionStream(
    Stream<List<int>> byteStream,
  ) async {
    final plainBody = StringBuffer();
    final content = StringBuffer();
    final reasoning = StringBuffer();
    Object? usage;
    final toolCalls = <int, Map<String, dynamic>>{};
    Map<String, dynamic>? fullMessage;
    var role = 'assistant';
    var sawSse = false;
    var sawTerminalEvent = false;
    try {
      await for (final line
          in byteStream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        _throwIfCancelled();
        if (!line.startsWith('data:')) {
          if (line.trim().isNotEmpty) plainBody.writeln(line);
          continue;
        }
        sawSse = true;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          sawTerminalEvent = true;
          continue;
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        if (payload['error'] != null) {
          throw AgentHttpException.fromParts(502, jsonEncode(payload));
        }
        if (payload['usage'] != null) usage = payload['usage'];
        final choices = payload['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) continue;
        final choice = Map<String, dynamic>.from(choices.first as Map);
        if (choice['finish_reason'] != null) sawTerminalEvent = true;
        final rawMessage = choice['message'];
        if (rawMessage is Map) {
          fullMessage = Map<String, dynamic>.from(rawMessage);
          continue;
        }
        final rawDelta = choice['delta'];
        if (rawDelta is! Map) continue;
        final delta = Map<String, dynamic>.from(rawDelta);
        if (delta['role'] is String) role = delta['role'] as String;
        content.write(_messageText(delta['content']));
        reasoning.write(
          _messageText(delta['reasoning_content'] ?? delta['reasoning']),
        );
        for (final rawCall
            in delta['tool_calls'] as List<dynamic>? ?? const []) {
          final call = Map<String, dynamic>.from(rawCall as Map);
          final index = call['index'] as int? ?? toolCalls.length;
          final target = toolCalls.putIfAbsent(
            index,
            () => {
              'id': '',
              'type': 'function',
              'function': {'name': '', 'arguments': ''},
            },
          );
          if (call['id'] is String) {
            target['id'] = '${target['id']}${call['id']}';
          }
          if (call['type'] is String) target['type'] = call['type'];
          final rawFunction = call['function'];
          if (rawFunction is Map) {
            final function = target['function'] as Map<String, dynamic>;
            if (rawFunction['name'] is String) {
              function['name'] =
                  '${function['name']}${rawFunction['name'] as String}';
            }
            if (rawFunction['arguments'] is String) {
              function['arguments'] =
                  '${function['arguments']}${rawFunction['arguments'] as String}';
            }
          }
        }
      }
    } on http.ClientException {
      if (!sawTerminalEvent) rethrow;
    }
    if (!sawSse) {
      final body = plainBody.toString().trim();
      if (body.isEmpty) {
        throw const AgentEmptyResponseException(
          'Provider mengembalikan stream kosong.',
        );
      }
      return _messageFromPayload(jsonDecode(body) as Map<String, dynamic>);
    }
    _emitInsight(reasoning.toString(), usage);
    if (fullMessage != null) {
      return _normalizeAssistantMessage(fullMessage);
    }
    final orderedCalls = toolCalls.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    if (content.isEmpty && orderedCalls.isEmpty) {
      throw const AgentEmptyResponseException();
    }
    return _normalizeAssistantMessage({
      'role': role,
      'content': content.isEmpty ? null : content.toString(),
      if (orderedCalls.isNotEmpty)
        'tool_calls': orderedCalls.map((entry) => entry.value).toList(),
    });
  }

  Map<String, dynamic> _messageFromPayload(Map<String, dynamic> payload) {
    final choices = payload['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      final responsesText = _responsesApiText(payload);
      if (responsesText.isNotEmpty) {
        _emitInsight('', payload['usage']);
        return {'role': 'assistant', 'content': responsesText};
      }
      throw const AgentEmptyResponseException(
        'Provider tidak mengembalikan pilihan atau isi jawaban.',
      );
    }
    final choice = Map<String, dynamic>.from(choices.first as Map);
    final rawMessage = choice['message'];
    final message = rawMessage is Map
        ? Map<String, dynamic>.from(rawMessage)
        : <String, dynamic>{
            'role': 'assistant',
            'content': choice['text'] ?? choice['delta'],
          };
    _emitInsight(
      _messageText(message['reasoning_content'] ?? message['reasoning']),
      payload['usage'],
    );
    return _normalizeAssistantMessage(message);
  }

  Map<String, dynamic> _normalizeAssistantMessage(Map<String, dynamic> raw) {
    final message = Map<String, dynamic>.from(raw);
    final calls = message['tool_calls'];
    final hasToolCalls = calls is List && calls.isNotEmpty;
    final content =
        [
              message['content'],
              message['output_text'],
              message['text'],
              message['response'],
              message['refusal'],
            ]
            .map(_messageText)
            .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    message
      ..remove('reasoning_content')
      ..remove('reasoning')
      ..remove('output_text')
      ..remove('text')
      ..remove('response')
      ..remove('refusal')
      ..['role'] = '${message['role'] ?? 'assistant'}'
      ..['content'] = content.trim().isEmpty ? null : content;
    if (content.trim().isEmpty && !hasToolCalls) {
      throw const AgentEmptyResponseException();
    }
    return message;
  }

  String _responsesApiText(Map<String, dynamic> payload) {
    final direct = _messageText(payload['output_text']).trim();
    if (direct.isNotEmpty) return direct;
    final output = payload['output'];
    if (output is! List) return '';
    final parts = <String>[];
    for (final rawBlock in output) {
      if (rawBlock is! Map) continue;
      final type = '${rawBlock['type'] ?? ''}';
      if (type != 'message' && type != 'output_text') continue;
      final text = _messageText(
        rawBlock['content'] ?? rawBlock['text'] ?? rawBlock['output_text'],
      ).trim();
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join('\n');
  }

  void _emitInsight(String reasoning, Object? usage) {
    final callback = onInsight;
    if (callback == null) return;
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    final usageMap = usage is Map ? usage : null;
    final trimmedReasoning = reasoning.trim();
    final prompt = asInt(usageMap?['prompt_tokens']);
    final completion = asInt(usageMap?['completion_tokens']);
    final total =
        asInt(usageMap?['total_tokens']) ??
        ((prompt != null && completion != null) ? prompt + completion : null);
    if (trimmedReasoning.isEmpty &&
        prompt == null &&
        completion == null &&
        total == null) {
      return;
    }
    callback(
      reasoning: trimmedReasoning.isEmpty ? null : trimmedReasoning,
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
    );
  }

  void _throwIfCancelled() {
    if (isCancelled()) throw const AgentCancelledException();
  }

  static String _messageText(Object? value) {
    if (value is String) return value;
    if (value is Map) {
      for (final key in const ['value', 'text', 'content', 'output_text']) {
        final text = _messageText(value[key]);
        if (text.isNotEmpty) return text;
      }
      return '';
    }
    if (value is List) {
      return value.map(_messageText).join();
    }
    return '';
  }
}
