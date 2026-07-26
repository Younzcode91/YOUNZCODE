import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/chat_entry.dart';
import 'package:kode_agent_desktop/models/chat_session.dart';
import 'package:kode_agent_desktop/services/chat_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

void main() {
  test('sesi chat disimpan dan dimuat dari yang terbaru', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatSessionStore();
    final older = ChatSession(
      id: 'older',
      workspace: 'C:/project',
      updatedAt: DateTime(2026, 1, 1),
      entries: const [ChatEntry(role: ChatRole.user, content: 'Chat lama')],
    );
    final newer = ChatSession(
      id: 'newer',
      workspace: 'C:/project',
      updatedAt: DateTime(2026, 1, 2),
      entries: const [
        ChatEntry(role: ChatRole.user, content: 'Chat terbaru'),
        ChatEntry(role: ChatRole.assistant, content: 'Jawaban'),
      ],
    );

    await store.save([older, newer]);
    final loaded = await store.load();

    expect(loaded.map((session) => session.id), ['newer', 'older']);
    expect(loaded.first.entries.last.content, 'Jawaban');
    expect(loaded.first.title, 'Chat terbaru');
  });

  test('storage membatasi riwayat menjadi 50 sesi', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatSessionStore();
    await store.save([
      for (var index = 0; index < 55; index++)
        ChatSession(
          id: '$index',
          workspace: 'C:/project',
          updatedAt: DateTime(2026, 1, 1).add(Duration(minutes: index)),
          entries: [ChatEntry(role: ChatRole.user, content: 'Chat $index')],
        ),
    ]);

    final loaded = await store.load();
    expect(loaded.length, 50);
    expect(loaded.first.id, '54');
  });

  test('checkpoint pesan internal agent tersimpan dan dipulihkan', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatSessionStore();
    await store.save([
      ChatSession(
        id: 'checkpoint',
        workspace: 'C:/project',
        updatedAt: DateTime(2026, 7, 23),
        entries: const [
          ChatEntry(role: ChatRole.user, content: 'Dockerisasi aplikasi'),
        ],
        agentMessages: const [
          {'role': 'system', 'content': 'system'},
          {'role': 'user', 'content': 'Dockerisasi aplikasi'},
          {
            'role': 'tool',
            'tool_call_id': 'call-1',
            'content': 'Dockerfile berhasil ditulis.',
          },
        ],
      ),
    ]);

    final loaded = await store.load();
    expect(loaded.single.agentMessages, hasLength(1));
    expect(loaded.single.agentMessages.single['role'], 'user');
  });

  test(
    'checkpoint tidak menyimpan source, tool payload, atau secret mentah',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ChatSessionStore();
      const secret = 'sk-abcdefghijklmnopqrstuvwxyz123456';
      const source = 'ATTACHED_SOURCE_DO_NOT_PERSIST';
      await store.save([
        ChatSession(
          id: 'safe-checkpoint',
          workspace: 'C:/project',
          updatedAt: DateTime(2026, 7, 25),
          entries: const [
            ChatEntry(role: ChatRole.user, content: 'Inspect the attachment'),
            ChatEntry(role: ChatRole.assistant, content: 'The key is $secret'),
          ],
          agentMessages: const [
            {'role': 'system', 'content': 'raw system payload'},
            {
              'role': 'user',
              'content': 'ATTACHED FILE CONTEXT:\n$source\n$secret',
            },
            {'role': 'tool', 'content': 'tool result $source'},
          ],
        ),
      ]);

      final preferences = await SharedPreferences.getInstance();
      final persisted = preferences.getString('chat_sessions_v1')!;
      expect(persisted, isNot(contains(source)));
      expect(persisted, isNot(contains(secret)));
      expect(persisted, isNot(contains('raw system payload')));
      expect(persisted, isNot(contains('tool result')));
      expect(jsonDecode(persisted), isA<List<dynamic>>());
    },
  );

  test('overlapping saves preserve invocation order and snapshots', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatSessionStore();
    final sessions = <ChatSession>[
      ChatSession(
        id: 'first',
        workspace: 'C:/project',
        updatedAt: DateTime(2026, 7, 25),
        entries: const [ChatEntry(role: ChatRole.user, content: 'first')],
      ),
    ];

    final firstSave = store.save(sessions);
    sessions[0] = ChatSession(
      id: 'second',
      workspace: 'C:/project',
      updatedAt: DateTime(2026, 7, 26),
      entries: const [ChatEntry(role: ChatRole.user, content: 'second')],
    );
    final secondSave = store.save(sessions);
    await Future.wait([firstSave, secondSave]);

    final loaded = await store.load();
    expect(loaded.single.id, 'second');
  });

  test('satu record rusak dilewati tanpa menghapus seluruh riwayat', () async {
    final good = {
      'id': 'good',
      'workspace': 'C:/project',
      'updatedAt': DateTime(2026, 7, 25).toIso8601String(),
      'entries': [
        {'role': 'user', 'content': 'masih ada'},
      ],
    };
    // Missing required 'id' makes ChatSession.fromJson throw for this record.
    final corrupt = {
      'workspace': 'C:/project',
      'updatedAt': DateTime(2026, 7, 24).toIso8601String(),
      'entries': const [],
    };
    SharedPreferences.setMockInitialValues({
      'chat_sessions_v1': jsonEncode([corrupt, good]),
    });

    final loaded = await ChatSessionStore().load();
    expect(loaded.map((session) => session.id), ['good']);
    expect(loaded.single.entries.single.content, 'masih ada');
  });
}
