import 'dart:convert';

/// Which wire protocol a provider speaks, detected from its base URL.
enum ProviderProtocol { openai, anthropic, gemini }

/// A fully-built native (non-OpenAI) HTTP request.
class NativeRequest {
  const NativeRequest({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

/// The result of parsing a native response back into an OpenAI-shaped assistant
/// message the agent loop understands, plus normalized usage.
typedef NativeParseResult = ({
  Map<String, dynamic> message,
  Map<String, dynamic>? usage,
});

/// Detects the wire protocol from the base URL. Anthropic and Google's *native*
/// endpoints get their own adapters; Google's OpenAI-compatible endpoint (path
/// contains `/openai`) and everything else use the OpenAI protocol.
ProviderProtocol detectProviderProtocol(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  final host = uri?.host.toLowerCase() ?? '';
  final path = uri?.path.toLowerCase() ?? '';
  if (host.contains('anthropic.com')) return ProviderProtocol.anthropic;
  if (host.contains('generativelanguage.googleapis.com') &&
      !path.contains('/openai')) {
    return ProviderProtocol.gemini;
  }
  return ProviderProtocol.openai;
}

// Extract plain text from an OpenAI-style message `content` (String or list of
// {type: text, text}) — mirrors AgentService._messageText.
String _openAiText(Object? value) {
  if (value is String) return value;
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) => item['text'])
        .whereType<String>()
        .join();
  }
  return '';
}

Map<String, dynamic> _decodeArguments(Object? raw) {
  try {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    // Malformed arguments become an empty object rather than crashing.
  }
  return <String, dynamic>{};
}

String _stripTrailingSlash(String value) =>
    value.trim().replaceAll(RegExp(r'/+$'), '');

// ---------------------------------------------------------------------------
// Anthropic Messages API (POST {base}/v1/messages, x-api-key auth).
// ---------------------------------------------------------------------------

NativeRequest buildAnthropicRequest({
  required String baseUrl,
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  required List<Map<String, Object>> tools,
  Map<String, String> extraHeaders = const {},
  int maxTokens = 8192,
}) {
  final systemParts = <String>[];
  final anthropicMessages = <Map<String, dynamic>>[];

  for (final message in messages) {
    final role = message['role'];
    if (role == 'system') {
      final text = _openAiText(message['content']);
      if (text.isNotEmpty) systemParts.add(text);
    } else if (role == 'tool') {
      anthropicMessages.add({
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': '${message['tool_call_id']}',
            'content': _openAiText(message['content']),
          },
        ],
      });
    } else if (role == 'assistant') {
      final blocks = <Map<String, dynamic>>[];
      final text = _openAiText(message['content']);
      if (text.isNotEmpty) blocks.add({'type': 'text', 'text': text});
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final call in calls) {
          if (call is! Map) continue;
          final function = call['function'];
          if (function is! Map) continue;
          blocks.add({
            'type': 'tool_use',
            'id': '${call['id']}',
            'name': '${function['name']}',
            'input': _decodeArguments(function['arguments']),
          });
        }
      }
      if (blocks.isEmpty) blocks.add({'type': 'text', 'text': '(no content)'});
      anthropicMessages.add({'role': 'assistant', 'content': blocks});
    } else {
      anthropicMessages.add({
        'role': 'user',
        'content': _openAiText(message['content']),
      });
    }
  }

  final base = _stripTrailingSlash(baseUrl);
  final endpoint = base.endsWith('/v1')
      ? '$base/messages'
      : '$base/v1/messages';

  return NativeRequest(
    url: Uri.parse(endpoint),
    headers: {
      ...extraHeaders,
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: {
      'model': model,
      'max_tokens': maxTokens,
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      'messages': anthropicMessages,
      if (tools.isNotEmpty)
        'tools': [for (final tool in tools) _anthropicTool(tool)],
      'stream': false,
    },
  );
}

Map<String, dynamic> _anthropicTool(Map<String, Object> openAiTool) {
  final function = openAiTool['function'];
  final map = function is Map ? function : const {};
  return {
    'name': '${map['name']}',
    'description': '${map['description'] ?? ''}',
    'input_schema': map['parameters'] is Map
        ? Map<String, dynamic>.from(map['parameters'] as Map)
        : const {'type': 'object'},
  };
}

NativeParseResult parseAnthropicResponse(Map<String, dynamic> payload) {
  final text = StringBuffer();
  final toolCalls = <Map<String, dynamic>>[];
  final content = payload['content'];
  if (content is List) {
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] == 'text') {
        text.write('${block['text'] ?? ''}');
      } else if (block['type'] == 'tool_use') {
        toolCalls.add({
          'id': '${block['id']}',
          'type': 'function',
          'function': {
            'name': '${block['name']}',
            'arguments': jsonEncode(block['input'] ?? const {}),
          },
        });
      }
    }
  }
  final usageRaw = payload['usage'];
  return (
    message: <String, dynamic>{
      'role': 'assistant',
      'content': text.isEmpty ? null : text.toString(),
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
    },
    usage: _normalizeUsage(
      prompt: usageRaw is Map ? usageRaw['input_tokens'] : null,
      completion: usageRaw is Map ? usageRaw['output_tokens'] : null,
    ),
  );
}

// ---------------------------------------------------------------------------
// Google Gemini generateContent (key in x-goog-api-key header, never the URL).
// ---------------------------------------------------------------------------

NativeRequest buildGeminiRequest({
  required String baseUrl,
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  required List<Map<String, Object>> tools,
  Map<String, String> extraHeaders = const {},
}) {
  final systemParts = <String>[];
  final contents = <Map<String, dynamic>>[];
  // Gemini's functionResponse is keyed by tool NAME, not id. We resolve each
  // tool result's name from the assistant turn that requested it by keeping a
  // running id->name map updated as we walk the history. A tool result always
  // follows its own assistant turn (before the next one), so this stays correct
  // even when synthesized call ids repeat across turns — Gemini ids are only
  // unique within a single response, so a global pre-pass would let a later
  // turn mislabel an earlier turn's result.
  final idToName = <String, String>{};

  for (final message in messages) {
    final role = message['role'];
    if (role == 'system') {
      final text = _openAiText(message['content']);
      if (text.isNotEmpty) systemParts.add(text);
    } else if (role == 'tool') {
      contents.add({
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': idToName['${message['tool_call_id']}'] ?? 'tool',
              'response': {'result': _openAiText(message['content'])},
            },
          },
        ],
      });
    } else if (role == 'assistant') {
      final parts = <Map<String, dynamic>>[];
      final text = _openAiText(message['content']);
      if (text.isNotEmpty) parts.add({'text': text});
      if (message['tool_calls'] is List) {
        for (final call in message['tool_calls'] as List) {
          if (call is! Map) continue;
          final function = call['function'];
          if (function is! Map) continue;
          final name = '${function['name']}';
          // Bind this id to its name now so a following tool result resolves
          // against this turn, before any later turn can reuse the same id.
          idToName['${call['id']}'] = name;
          parts.add({
            'functionCall': {
              'name': name,
              'args': _decodeArguments(function['arguments']),
            },
          });
        }
      }
      if (parts.isEmpty) parts.add({'text': '(no content)'});
      contents.add({'role': 'model', 'parts': parts});
    } else {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': _openAiText(message['content'])},
        ],
      });
    }
  }

  final base = _stripTrailingSlash(baseUrl);
  return NativeRequest(
    url: Uri.parse('$base/models/$model:generateContent'),
    headers: {
      ...extraHeaders,
      'x-goog-api-key': apiKey,
      'content-type': 'application/json',
    },
    body: {
      if (systemParts.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemParts.join('\n\n')},
          ],
        },
      'contents': contents,
      if (tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final tool in tools) _geminiFunction(tool),
            ],
          },
        ],
    },
  );
}

Map<String, dynamic> _geminiFunction(Map<String, Object> openAiTool) {
  final function = openAiTool['function'];
  final map = function is Map ? function : const {};
  return {
    'name': '${map['name']}',
    'description': '${map['description'] ?? ''}',
    if (map['parameters'] is Map)
      'parameters': Map<String, dynamic>.from(map['parameters'] as Map),
  };
}

NativeParseResult parseGeminiResponse(Map<String, dynamic> payload) {
  final text = StringBuffer();
  final toolCalls = <Map<String, dynamic>>[];
  final candidates = payload['candidates'];
  if (candidates is List && candidates.isNotEmpty) {
    final first = candidates.first;
    final content = first is Map ? first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is List) {
      var index = 0;
      for (final part in parts) {
        if (part is! Map) continue;
        if (part['text'] is String) {
          text.write(part['text'] as String);
        } else if (part['functionCall'] is Map) {
          final call = part['functionCall'] as Map;
          toolCalls.add({
            'id': 'gemini-call-${index++}',
            'type': 'function',
            'function': {
              'name': '${call['name']}',
              'arguments': jsonEncode(call['args'] ?? const {}),
            },
          });
        }
      }
    }
  }
  final usageRaw = payload['usageMetadata'];
  return (
    message: <String, dynamic>{
      'role': 'assistant',
      'content': text.isEmpty ? null : text.toString(),
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
    },
    usage: _normalizeUsage(
      prompt: usageRaw is Map ? usageRaw['promptTokenCount'] : null,
      completion: usageRaw is Map ? usageRaw['candidatesTokenCount'] : null,
      total: usageRaw is Map ? usageRaw['totalTokenCount'] : null,
    ),
  );
}

Map<String, dynamic>? _normalizeUsage({
  Object? prompt,
  Object? completion,
  Object? total,
}) {
  final promptTokens = prompt is num ? prompt.toInt() : null;
  final completionTokens = completion is num ? completion.toInt() : null;
  final totalTokens = total is num
      ? total.toInt()
      : (promptTokens != null && completionTokens != null)
      ? promptTokens + completionTokens
      : null;
  if (promptTokens == null && completionTokens == null && totalTokens == null) {
    return null;
  }
  return {
    'prompt_tokens': ?promptTokens,
    'completion_tokens': ?completionTokens,
    'total_tokens': ?totalTokens,
  };
}
