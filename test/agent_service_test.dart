import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kode_agent_desktop/models/chat_entry.dart';
import 'package:kode_agent_desktop/services/agent_service.dart';
import 'package:kode_agent_desktop/services/workspace_tools.dart';

void main() {
  test('HTTP HTML diringkas menjadi petunjuk Base URL', () {
    final error = AgentHttpException.fromParts(
      404,
      '<!DOCTYPE html><html><body>halaman dashboard</body></html>',
    );

    expect(error.statusCode, 404);
    expect(error.toString(), contains('endpoint API provider tidak ditemukan'));
    expect(error.toString(), isNot(contains('<!DOCTYPE')));
  });

  test('request-time defense menolak HTTP sebelum mengirim API key', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 200);
    });
    final agent = AgentService(
      baseUrl: 'http://provider.example/v1',
      apiKey: 'secret-key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );

    await expectLater(agent.send('hello'), throwsFormatException);
    expect(requests, 0);
  });

  test('system prompt meminta gaya natural dan jarak antarbagian', () async {
    late String systemPrompt;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      systemPrompt =
          (messages.first as Map<String, dynamic>)['content'] as String;
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}',
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('formatkan jawaban'), 'ok');
    expect(systemPrompt, contains('natural, tidak kaku'));
    expect(systemPrompt, contains('satu baris kosong'));
    expect(systemPrompt, contains('jangan memaksa semua jawaban'));
    expect(systemPrompt, contains('Hindari heading Markdown berlebihan'));
    expect(systemPrompt, contains('fenced code block tiga backtick'));
    expect(systemPrompt, contains('selalu gunakan tanda petik ganda'));
    expect(systemPrompt, contains('HTTP "200"'));
    expect(systemPrompt, contains('Jangan gunakan penekanan Markdown'));
  });

  test(
    'request gagal mempertahankan prompt untuk checkpoint berikutnya',
    () async {
      var requestCount = 0;
      late List<dynamic> secondMessages;
      final client = MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.Response('{"error":{"message":"sementara gagal"}}', 500);
        }
        secondMessages =
            (jsonDecode(request.body) as Map<String, dynamic>)['messages']
                as List<dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'berhasil'},
              },
            ],
          }),
          200,
        );
      });
      final agent = AgentService(
        baseUrl: 'https://example.test/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        httpClient: client,
      );

      await expectLater(
        agent.send('gagal'),
        throwsA(isA<AgentHttpException>()),
      );
      expect(await agent.send('berikutnya'), 'berhasil');
      expect(secondMessages.length, 3);
      expect((secondMessages[1] as Map<String, dynamic>)['content'], 'gagal');
      expect(
        (secondMessages.last as Map<String, dynamic>)['content'],
        'berikutnya',
      );
    },
  );

  test('restore memuat konteks sesi sebelum prompt lanjutan', () async {
    late List<dynamic> messages;
    final client = MockClient((request) async {
      messages =
          (jsonDecode(request.body) as Map<String, dynamic>)['messages']
              as List<dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'lanjut'},
            },
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    agent.restore(const [
      ChatEntry(role: ChatRole.user, content: 'pertanyaan lama'),
      ChatEntry(role: ChatRole.assistant, content: 'jawaban lama'),
    ]);

    expect(await agent.send('lanjutkan'), 'lanjut');
    expect(messages.length, 4);
    expect((messages[1] as Map)['content'], 'pertanyaan lama');
    expect((messages[2] as Map)['content'], 'jawaban lama');
    expect((messages[3] as Map)['content'], 'lanjutkan');
  });

  test(
    'continueWithPrompt mempertahankan staged edit antar-turn goal',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'younzcode-goal-staged-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        final message = switch (requestCount) {
          1 => {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'goal-write-1',
                'type': 'function',
                'function': {
                  'name': 'write_file',
                  'arguments': jsonEncode({
                    'path': 'goal.txt',
                    'content': 'turn pertama',
                  }),
                },
              },
            ],
          },
          2 => {'role': 'assistant', 'content': 'turn pertama selesai'},
          _ => {'role': 'assistant', 'content': 'goal selesai'},
        };
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': message},
            ],
          }),
          200,
        );
      });
      final agent = AgentService(
        baseUrl: 'https://example.test/v1',
        apiKey: 'key',
        model: 'model',
        workspace: workspace.path,
        requestPermission: (_, _) async => PermissionDecision.allowOnce,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        allowWrite: true,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        httpClient: client,
      );
      addTearDown(agent.dispose);

      expect(await agent.send('mulai goal'), 'turn pertama selesai');
      expect(agent.pendingChanges?.files.single.path, 'goal.txt');
      expect(await agent.continueWithPrompt('lanjutkan goal'), 'goal selesai');
      expect(agent.pendingChanges?.files.single.path, 'goal.txt');
      expect(await File('${workspace.path}/goal.txt').exists(), isFalse);
    },
  );

  test('plan mode tidak mengirim tool write atau terminal', () async {
    late List<dynamic> tools;
    final client = MockClient((request) async {
      tools =
          (jsonDecode(request.body) as Map<String, dynamic>)['tools'] as List;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'rencana'},
            },
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      planMode: true,
      httpClient: client,
    );

    expect(await agent.send('buat rencana'), 'rencana');
    final names = tools
        .map((tool) => (tool as Map)['function']['name'])
        .toSet();
    expect(names, containsAll(['list_files', 'read_file', 'search_text']));
    expect(names, isNot(contains('write_file')));
    expect(names, isNot(contains('replace_text')));
    expect(names, isNot(contains('run_command')));
  });

  test('agent dapat melanjutkan lebih dari 20 langkah', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      final message = requestCount <= 21
          ? {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call-$requestCount',
                  'type': 'function',
                  'function': {'name': 'unknown_tool', 'arguments': '{}'},
                },
              ],
            }
          : {'role': 'assistant', 'content': 'selesai'};
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.allowOnce,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('lanjut terus'), 'selesai');
    expect(requestCount, 22);
  });

  test('batas tool menyisakan request khusus untuk jawaban akhir', () async {
    var requestCount = 0;
    Map<String, dynamic>? finalRequestBody;
    final activities = <List<String>>[];
    final client = MockClient((request) async {
      requestCount++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (requestCount == 1) {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    for (var index = 1; index <= 3; index++)
                      {
                        'id': 'call-$index',
                        'type': 'function',
                        'function': {'name': 'unknown_tool', 'arguments': '{}'},
                      },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      finalRequestBody = body;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'ringkasan berdasarkan bukti yang tersedia',
              },
            },
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.allowOnce,
      onToolActivity: (id, name, detail, state) {
        activities.add([id, name, detail, state]);
      },
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      maxToolCalls: 2,
      headers: const {},
      httpClient: client,
    );

    expect(
      await agent.send('periksa secukupnya lalu jawab'),
      'ringkasan berdasarkan bukti yang tersedia',
    );
    expect(requestCount, 2);
    expect(finalRequestBody, isNot(contains('tools')));
    expect(finalRequestBody, isNot(contains('tool_choice')));
    expect(
      (finalRequestBody!['messages'] as List).last['content'],
      contains('Berikan jawaban akhir'),
    );
    expect(
      activities.any(
        (activity) =>
            activity.first == 'call-3' && activity.last == 'dibatalkan',
      ),
      isTrue,
    );
  });

  test('tool activity membawa detail command dan transisi status', () async {
    var requestCount = 0;
    final activities = <List<String>>[];
    final client = MockClient((request) async {
      requestCount++;
      final message = requestCount == 1
          ? {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'command-1',
                  'type': 'function',
                  'function': {
                    'name': 'run_command',
                    'arguments': jsonEncode({'command': 'dart analyze'}),
                  },
                },
              ],
            }
          : {'role': 'assistant', 'content': 'selesai'};
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (id, name, detail, state) {
        activities.add([id, name, detail, state]);
      },
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('verifikasi'), 'selesai');
    expect(activities.first, [
      'command-1',
      'run_command',
      'dart analyze',
      'berjalan',
    ]);
    expect(activities.last.last, 'gagal');
    expect(activities.last[2], contains('dart analyze\n'));
    expect(activities.last[2], contains('Eksekusi terminal dinonaktifkan'));
  });

  test('streaming SSE digabung menjadi jawaban lengkap', () async {
    final client = _StreamingClient([
      'data: {"choices":[{"delta":{"role":"assistant","content":"Halo "}}]}\n\n',
      'data: {"choices":[{"delta":{"content":"dunia"}}]}\n\n',
      'data: [DONE]\n\n',
    ]);
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('sapa'), 'Halo dunia');
  });

  test('HTTP 524 dicoba ulang lalu berhasil', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) return http.Response('error code: 524', 524);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'pulih'},
            },
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('coba'), 'pulih');
    expect(requestCount, 2);
  });

  test('HTTP 529 overloaded Anthropic dicoba ulang lalu berhasil', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return http.Response(
          jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
          529,
        );
      }
      return http.Response(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'pulih'},
          ],
          'usage': {'input_tokens': 3, 'output_tokens': 2},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final agent = AgentService(
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'sk-ant',
      model: 'claude-opus-4-8',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('coba'), 'pulih');
    expect(requestCount, 2);
  });

  test('stream putus beralih ke respons non-stream', () async {
    final client = _FlakyStreamingClient(failuresBeforeSuccess: 3);
    final statuses = <String>[];
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: statuses.add,
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      retryBaseDelay: Duration.zero,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('coba lagi'), 'koneksi pulih');
    expect(client.requestCount, 2);
    expect(client.streamingModes, [true, false]);
    expect(
      statuses.where(
        (status) =>
            status.contains('Streaming terputus, beralih ke mode kompatibel'),
      ),
      hasLength(1),
    );
  });

  test('9router lokal beralih ke stream jika respons JSON terputus', () async {
    final client = _LocalJsonThenStreamingClient();
    final statuses = <String>[];
    final agent = AgentService(
      baseUrl: 'http://127.0.0.1:20128/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: statuses.add,
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      retryBaseDelay: Duration.zero,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('gunakan koneksi stabil'), 'koneksi pulih');
    expect(client.streamingModes, [false, true]);
    expect(
      statuses.where(
        (status) =>
            status.contains('Respons lokal terputus, beralih ke streaming'),
      ),
      hasLength(1),
    );
  });

  test('jawaban lengkap dipakai saat socket ditutup setelah finish', () async {
    final client = _TerminalThenClosedClient();
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      retryBaseDelay: Duration.zero,
      headers: const {},
      httpClient: client,
    );

    expect(await agent.send('selesaikan'), 'jawaban lengkap');
    expect(client.requestCount, 1);
  });

  test('client tetap terbuka sampai respons tertunda selesai dibaca', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    unawaited(
      server.forEach((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"choices":[{"message":{"role":"assistant","content":"',
        );
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        request.response.write('respons lengkap"}}]}');
        await request.response.close();
      }),
    );
    final agent = AgentService(
      baseUrl: 'http://${server.address.host}:${server.port}/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
    );
    addTearDown(agent.dispose);

    expect(await agent.send('tunggu respons'), 'respons lengkap');
  });

  test('timeout diterapkan pada request agent utama', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return http.Response('{}', 200);
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 25,
      maxRequestAttempts: 1,
      headers: const {},
      httpClient: client,
    );

    await expectLater(agent.send('lambat'), throwsA(isA<TimeoutException>()));
  });

  test('deadline total menghentikan turn dan menyimpan checkpoint', () async {
    final client = _HangingClient();
    final statuses = <String>[];
    final checkpoints = <List<Map<String, dynamic>>>[];
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: statuses.add,
      onCheckpoint: checkpoints.add,
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 5000,
      maxTurnDuration: const Duration(milliseconds: 50),
      maxRequestAttempts: 1,
      headers: const {},
      httpClient: client,
    );

    await expectLater(
      agent.send('jangan berjalan selamanya'),
      throwsA(isA<AgentTurnTimeoutException>()),
    );
    expect(statuses.last, contains('Batas waktu total'));
    expect(
      checkpoints.last.any(
        (message) => message['content'] == 'jangan berjalan selamanya',
      ),
      isTrue,
    );
  });

  test(
    'cancel membatalkan request aktif dan mempertahankan checkpoint',
    () async {
      final client = _HangingClient();
      final checkpoints = <List<Map<String, dynamic>>>[];
      final agent = AgentService(
        baseUrl: 'https://example.test/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        onCheckpoint: checkpoints.add,
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        httpClient: client,
      );

      final pending = agent.send('jangan hilangkan saya');
      final cancelled = expectLater(
        pending,
        throwsA(isA<AgentCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await agent.cancel();

      await cancelled;
      expect(
        checkpoints.last.any(
          (message) => message['content'] == 'jangan hilangkan saya',
        ),
        isTrue,
      );
    },
  );

  test('argumen tool-call tidak valid tidak meng-crash turn', () async {
    var requestCount = 0;
    List<dynamic>? secondMessages;
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'bad-1',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': '{not valid json',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      secondMessages =
          (jsonDecode(request.body) as Map<String, dynamic>)['messages']
              as List<dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'pulih'},
            },
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('baca file'), 'pulih');
    final toolMessage =
        secondMessages!.firstWhere(
              (message) => (message as Map)['role'] == 'tool',
            )
            as Map<String, dynamic>;
    expect(toolMessage['tool_call_id'], 'bad-1');
    expect(toolMessage['content'], contains('argumen tool tidak valid'));
  });

  test('argumen string kosong diperlakukan sebagai objek kosong', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      final message = requestCount == 1
          ? {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'empty-1',
                  'type': 'function',
                  'function': {'name': 'list_files', 'arguments': ''},
                },
              ],
            }
          : {'role': 'assistant', 'content': 'lanjut'};
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    // Must not throw a FormatException from jsonDecode('').
    expect(await agent.send('daftar file'), 'lanjut');
    expect(requestCount, 2);
  });

  test('baris SSE rusak dilewati tanpa membatalkan stream', () async {
    final client = _StreamingClient([
      'data: {"choices":[{"delta":{"role":"assistant","content":"Ha"}}]}\n\n',
      'data: {rusak bukan json\n\n',
      'data: {"choices":[{"delta":{"content":"lo"}}]}\n\n',
      'data: [DONE]\n\n',
    ]);
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('sapa'), 'Halo');
  });

  test(
    'respons kosong dicoba ulang dengan mode transport alternatif',
    () async {
      var requestCount = 0;
      final streamingModes = <bool>[];
      final statuses = <String>[];
      final client = MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        streamingModes.add(body['stream'] as bool);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': requestCount == 1 ? null : 'jawaban sudah pulih',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final agent = AgentService(
        baseUrl: 'http://127.0.0.1:20128/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: statuses.add,
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        maxRequestAttempts: 2,
        retryBaseDelay: Duration.zero,
        httpClient: client,
      );
      addTearDown(agent.dispose);

      expect(await agent.send('lanjutkan'), 'jawaban sudah pulih');
      expect(requestCount, 2);
      expect(streamingModes, [false, true]);
      expect(
        statuses,
        contains(contains('Respons provider kosong, meminta jawaban ulang')),
      );
    },
  );

  test(
    'respons tetap kosong menghasilkan error, bukan sukses kosong',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': null},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final agent = AgentService(
        baseUrl: 'http://127.0.0.1:20128/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        maxRequestAttempts: 2,
        retryBaseDelay: Duration.zero,
        httpClient: client,
      );
      addTearDown(agent.dispose);

      await expectLater(
        agent.send('lanjutkan'),
        throwsA(isA<AgentEmptyResponseException>()),
      );
    },
  );

  test(
    'body HTTP kosong juga dicoba ulang lalu dilaporkan sebagai error',
    () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        return http.Response(
          '',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final agent = AgentService(
        baseUrl: 'http://127.0.0.1:20128/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        maxRequestAttempts: 2,
        retryBaseDelay: Duration.zero,
        httpClient: client,
      );
      addTearDown(agent.dispose);

      await expectLater(
        agent.send('lanjutkan'),
        throwsA(isA<AgentEmptyResponseException>()),
      );
      expect(requestCount, 2);
    },
  );

  test(
    'payload Responses API output_text dinormalisasi menjadi jawaban',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'output': [
              {
                'type': 'reasoning',
                'summary': [
                  {'type': 'summary_text', 'text': 'internal'},
                ],
              },
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'jawaban dari output_text'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final agent = AgentService(
        baseUrl: 'http://127.0.0.1:20128/v1',
        apiKey: 'key',
        model: 'model',
        workspace: '.',
        requestPermission: (_, _) async => PermissionDecision.reject,
        onToolActivity: (_, _, _, _) {},
        onStatus: (_) {},
        allowWrite: false,
        allowTerminal: false,
        environment: const {},
        timeoutMs: 1000,
        headers: const {},
        httpClient: client,
      );
      addTearDown(agent.dispose);

      expect(await agent.send('lanjutkan'), 'jawaban dari output_text');
    },
  );

  test('menangkap reasoning dan token usage dari stream', () async {
    String? capturedReasoning;
    int? capturedTotal;
    final client = _StreamingClient([
      'data: {"choices":[{"delta":{"role":"assistant","reasoning_content":"pikir "}}]}\n\n',
      'data: {"choices":[{"delta":{"reasoning_content":"dulu"}}]}\n\n',
      'data: {"choices":[{"delta":{"content":"Halo"}}]}\n\n',
      'data: {"choices":[{"finish_reason":"stop","delta":{}}],'
          '"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n',
      'data: [DONE]\n\n',
    ]);
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      onInsight: ({reasoning, promptTokens, completionTokens, totalTokens}) {
        if (reasoning != null) capturedReasoning = reasoning;
        if (totalTokens != null) capturedTotal = totalTokens;
      },
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    // Reasoning must not leak into the answer, but is reported out-of-band.
    expect(await agent.send('sapa'), 'Halo');
    expect(capturedReasoning, 'pikir dulu');
    expect(capturedTotal, 15);
  });

  test('menangkap token usage dari respons JSON non-stream', () async {
    int? capturedTotal;
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'ok',
                'reasoning_content': 'karena begitu',
              },
            },
          ],
          'usage': {
            'prompt_tokens': 3,
            'completion_tokens': 4,
            'total_tokens': 7,
          },
        }),
        200,
      );
    });
    final agent = AgentService(
      baseUrl: 'https://example.test/v1',
      apiKey: 'key',
      model: 'model',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      onInsight: ({reasoning, promptTokens, completionTokens, totalTokens}) {
        if (totalTokens != null) capturedTotal = totalTokens;
      },
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('x'), 'ok');
    expect(capturedTotal, 7);
  });

  test('base URL Anthropic diarahkan ke /v1/messages native', () async {
    late Uri calledUrl;
    late Map<String, String> calledHeaders;
    late Map<String, dynamic> calledBody;
    var capturedTotal = 0;
    final client = MockClient((request) async {
      calledUrl = request.url;
      calledHeaders = request.headers;
      calledBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'halo dari claude'},
          ],
          'usage': {'input_tokens': 5, 'output_tokens': 4},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final agent = AgentService(
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'sk-ant-xyz',
      model: 'claude-opus-4-8',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      onInsight: ({reasoning, promptTokens, completionTokens, totalTokens}) {
        if (totalTokens != null) capturedTotal = totalTokens;
      },
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('hai'), 'halo dari claude');
    expect(calledUrl.toString(), 'https://api.anthropic.com/v1/messages');
    expect(calledHeaders['x-api-key'], 'sk-ant-xyz');
    expect(calledHeaders['anthropic-version'], '2023-06-01');
    // Kunci Bearer OpenAI tidak boleh ikut terkirim ke endpoint native.
    expect(calledHeaders.containsKey('authorization'), isFalse);
    expect(calledBody['model'], 'claude-opus-4-8');
    expect(calledBody['stream'], false);
    expect(capturedTotal, 9);
  });

  test('base URL Gemini native diarahkan ke generateContent', () async {
    late Uri calledUrl;
    late Map<String, String> calledHeaders;
    final client = MockClient((request) async {
      calledUrl = request.url;
      calledHeaders = request.headers;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'halo dari gemini'},
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final agent = AgentService(
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      apiKey: 'goog-secret',
      model: 'gemini-2.5-pro',
      workspace: '.',
      requestPermission: (_, _) async => PermissionDecision.reject,
      onToolActivity: (_, _, _, _) {},
      onStatus: (_) {},
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
      timeoutMs: 1000,
      headers: const {},
      httpClient: client,
    );
    addTearDown(agent.dispose);

    expect(await agent.send('hai'), 'halo dari gemini');
    expect(
      calledUrl.toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-2.5-pro:generateContent',
    );
    expect(calledHeaders['x-goog-api-key'], 'goog-secret');
    // Kunci tidak boleh bocor ke query string.
    expect(calledUrl.toString(), isNot(contains('goog-secret')));
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.chunks);

  final List<String> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<String>.fromIterable(chunks).transform(utf8.encoder),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

class _HangingClient extends http.BaseClient {
  final _response = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _response.future;

  @override
  void close() {
    if (!_response.isCompleted) {
      _response.completeError(http.ClientException('closed'));
    }
  }
}

class _FlakyStreamingClient extends http.BaseClient {
  _FlakyStreamingClient({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  int requestCount = 0;
  final streamingModes = <bool>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    final body = jsonDecode((request as http.Request).body);
    final streaming = body['stream'] as bool;
    streamingModes.add(streaming);
    if (streaming && requestCount <= failuresBeforeSuccess) {
      return http.StreamedResponse(
        Stream<List<int>>.error(
          http.ClientException(
            'Connection closed while receiving data',
            request.url,
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.fromFutures([
        Future.value(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'koneksi pulih'},
                },
              ],
            }),
          ),
        ),
        Future<List<int>>.error(
          http.ClientException(
            'Connection closed while receiving data',
            request.url,
          ),
        ),
      ]),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

class _LocalJsonThenStreamingClient extends http.BaseClient {
  final streamingModes = <bool>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode((request as http.Request).body);
    final streaming = body['stream'] as bool;
    streamingModes.add(streaming);
    if (!streaming) {
      return http.StreamedResponse(
        Stream<List<int>>.error(
          http.ClientException(
            'Connection closed while receiving data',
            request.url,
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          'data: {"choices":[{"delta":{"role":"assistant",'
          '"content":"koneksi pulih"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

class _TerminalThenClosedClient extends http.BaseClient {
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    final completeEvent = utf8.encode(
      'data: {"choices":[{"delta":{"role":"assistant",'
      '"content":"jawaban lengkap"},"finish_reason":"stop"}]}\n\n',
    );
    return http.StreamedResponse(
      Stream<List<int>>.fromFutures([
        Future.value(completeEvent),
        Future<List<int>>.error(
          http.ClientException(
            'Connection closed while receiving data',
            request.url,
          ),
        ),
      ]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
