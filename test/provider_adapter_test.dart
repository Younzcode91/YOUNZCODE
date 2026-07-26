import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/provider_adapter.dart';

void main() {
  group('detectProviderProtocol', () {
    test('mengenali Anthropic dari host', () {
      expect(
        detectProviderProtocol('https://api.anthropic.com'),
        ProviderProtocol.anthropic,
      );
      expect(
        detectProviderProtocol('https://api.anthropic.com/v1'),
        ProviderProtocol.anthropic,
      );
    });

    test('mengenali Gemini native, bukan endpoint kompatibel OpenAI', () {
      expect(
        detectProviderProtocol(
          'https://generativelanguage.googleapis.com/v1beta',
        ),
        ProviderProtocol.gemini,
      );
      // Endpoint OpenAI-compatible Google tetap protokol OpenAI.
      expect(
        detectProviderProtocol(
          'https://generativelanguage.googleapis.com/v1beta/openai',
        ),
        ProviderProtocol.openai,
      );
    });

    test('default ke OpenAI untuk host lain', () {
      expect(
        detectProviderProtocol('https://api.openai.com/v1'),
        ProviderProtocol.openai,
      );
      expect(
        detectProviderProtocol('http://127.0.0.1:20128/v1'),
        ProviderProtocol.openai,
      );
    });
  });

  group('Anthropic adapter', () {
    test('membangun request dari riwayat gaya OpenAI', () {
      final built = buildAnthropicRequest(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-test',
        model: 'claude-opus-4-8',
        messages: [
          {'role': 'system', 'content': 'You are helpful.'},
          {'role': 'user', 'content': 'Hi'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'read_file',
                  'arguments': '{"path":"a.txt"}',
                },
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'file body'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'read_file',
              'description': 'Read a file',
              'parameters': {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
              },
            },
          },
        ],
      );

      expect(built.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(built.headers['x-api-key'], 'sk-test');
      expect(built.headers['anthropic-version'], '2023-06-01');
      expect(built.body['model'], 'claude-opus-4-8');
      expect(built.body['system'], 'You are helpful.');
      expect(built.body['stream'], false);

      final msgs = built.body['messages'] as List;
      // user, assistant(tool_use), user(tool_result)
      expect(msgs.length, 3);
      final assistant = msgs[1] as Map;
      final block = (assistant['content'] as List).first as Map;
      expect(block['type'], 'tool_use');
      expect(block['id'], 'call_1');
      expect(block['name'], 'read_file');
      expect((block['input'] as Map)['path'], 'a.txt');

      final toolResult = (msgs[2] as Map)['content'] as List;
      expect((toolResult.first as Map)['type'], 'tool_result');
      expect((toolResult.first as Map)['tool_use_id'], 'call_1');

      final tool = (built.body['tools'] as List).first as Map;
      expect(tool['name'], 'read_file');
      expect((tool['input_schema'] as Map)['type'], 'object');
    });

    test('menggunakan /messages ketika base sudah berakhir /v1', () {
      final built = buildAnthropicRequest(
        baseUrl: 'https://api.anthropic.com/v1',
        apiKey: 'k',
        model: 'm',
        messages: const [
          {'role': 'user', 'content': 'x'},
        ],
        tools: const [],
      );
      expect(built.url.toString(), 'https://api.anthropic.com/v1/messages');
    });

    test('parse respons teks + tool_use jadi pesan OpenAI', () {
      final parsed = parseAnthropicResponse({
        'content': [
          {'type': 'text', 'text': 'Sure, reading now.'},
          {
            'type': 'tool_use',
            'id': 'toolu_9',
            'name': 'read_file',
            'input': {'path': 'b.txt'},
          },
        ],
        'usage': {'input_tokens': 12, 'output_tokens': 7},
      });

      expect(parsed.message['role'], 'assistant');
      expect(parsed.message['content'], 'Sure, reading now.');
      final calls = parsed.message['tool_calls'] as List;
      expect(calls.length, 1);
      final call = calls.first as Map;
      expect(call['id'], 'toolu_9');
      expect(call['type'], 'function');
      expect((call['function'] as Map)['name'], 'read_file');
      expect(
        jsonDecode((call['function'] as Map)['arguments'] as String)['path'],
        'b.txt',
      );

      expect(parsed.usage!['prompt_tokens'], 12);
      expect(parsed.usage!['completion_tokens'], 7);
      expect(parsed.usage!['total_tokens'], 19);
    });
  });

  group('Gemini adapter', () {
    test('membangun request dengan kunci di header, bukan URL', () {
      final built = buildGeminiRequest(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        apiKey: 'goog-key',
        model: 'gemini-2.5-pro',
        messages: [
          {'role': 'system', 'content': 'Be terse.'},
          {'role': 'user', 'content': 'Hello'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_a',
                'type': 'function',
                'function': {'name': 'list_dir', 'arguments': '{"dir":"."}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'a.txt\nb.txt'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'list_dir',
              'description': 'List a directory',
              'parameters': {
                'type': 'object',
                'properties': {
                  'dir': {'type': 'string'},
                },
              },
            },
          },
        ],
      );

      expect(
        built.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-pro:generateContent',
      );
      // The API key must never appear in the URL.
      expect(built.url.toString(), isNot(contains('goog-key')));
      expect(built.headers['x-goog-api-key'], 'goog-key');

      final sys = built.body['systemInstruction'] as Map;
      expect(((sys['parts'] as List).first as Map)['text'], 'Be terse.');

      final contents = built.body['contents'] as List;
      // user, model(functionCall), user(functionResponse)
      expect(contents.length, 3);
      final modelTurn = contents[1] as Map;
      expect(modelTurn['role'], 'model');
      final fnCall =
          ((modelTurn['parts'] as List).first as Map)['functionCall'] as Map;
      expect(fnCall['name'], 'list_dir');
      expect((fnCall['args'] as Map)['dir'], '.');

      final fnResponse = ((contents[2] as Map)['parts'] as List).first as Map;
      final response = (fnResponse['functionResponse'] as Map);
      // functionResponse keyed by tool name, mapped back from the call id.
      expect(response['name'], 'list_dir');

      final decl =
          ((built.body['tools'] as List).first as Map)['functionDeclarations']
              as List;
      expect((decl.first as Map)['name'], 'list_dir');
    });

    test('parse kandidat teks + functionCall jadi pesan OpenAI', () {
      final parsed = parseGeminiResponse({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'Listing.'},
                {
                  'functionCall': {
                    'name': 'list_dir',
                    'args': {'dir': 'src'},
                  },
                },
              ],
            },
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 30,
          'candidatesTokenCount': 5,
          'totalTokenCount': 35,
        },
      });

      expect(parsed.message['content'], 'Listing.');
      final calls = parsed.message['tool_calls'] as List;
      expect(calls.length, 1);
      final fn = (calls.first as Map)['function'] as Map;
      expect(fn['name'], 'list_dir');
      expect(jsonDecode(fn['arguments'] as String)['dir'], 'src');

      expect(parsed.usage!['prompt_tokens'], 30);
      expect(parsed.usage!['completion_tokens'], 5);
      expect(parsed.usage!['total_tokens'], 35);
    });

    test('id gemini-call yang berulang antar-turn tidak salah-nama respons', () {
      // Gemini synthesizes tool-call ids that reset per response, so the SAME
      // id ('gemini-call-0') recurs across steps with different function names.
      // Each tool result must resolve to the function from ITS OWN turn.
      final built = buildGeminiRequest(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        apiKey: 'k',
        model: 'gemini-2.5-pro',
        messages: [
          {'role': 'user', 'content': 'step 1'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'gemini-call-0',
                'type': 'function',
                'function': {'name': 'read_file', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'gemini-call-0',
            'content': 'contents of A',
          },
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'gemini-call-0',
                'type': 'function',
                'function': {'name': 'list_dir', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'gemini-call-0',
            'content': 'a.txt\nb.txt',
          },
        ],
        tools: const [],
      );

      final contents = built.body['contents'] as List;
      // user, model(read_file), user(resp read_file), model(list_dir),
      // user(resp list_dir)
      expect(contents.length, 5);
      final firstResp =
          (((contents[2] as Map)['parts'] as List).first
                  as Map)['functionResponse']
              as Map;
      // Would be mislabeled 'list_dir' under a global last-write-wins map.
      expect(firstResp['name'], 'read_file');
      final secondResp =
          (((contents[4] as Map)['parts'] as List).first
                  as Map)['functionResponse']
              as Map;
      expect(secondResp['name'], 'list_dir');
    });

    test('respons tanpa tool_calls tidak menyertakan kunci tool_calls', () {
      final parsed = parseGeminiResponse({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'Just text.'},
              ],
            },
          },
        ],
      });
      expect(parsed.message.containsKey('tool_calls'), isFalse);
      expect(parsed.message['content'], 'Just text.');
      expect(parsed.usage, isNull);
    });
  });
}
