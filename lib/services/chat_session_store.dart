import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_session.dart';
import 'secret_scanner.dart';

class ChatSessionStore {
  static const _sessionsKey = 'chat_sessions_v1';
  Future<void> _pendingSave = Future.value();

  Future<List<ChatSession>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_sessionsKey);
    if (encoded == null || encoded.isEmpty) return [];
    final List<dynamic> values;
    try {
      values = jsonDecode(encoded) as List;
    } catch (_) {
      return [];
    }
    final sessions = <ChatSession>[];
    for (final value in values) {
      try {
        sessions.add(
          ChatSession.fromJson(Map<String, dynamic>.from(value as Map)),
        );
      } catch (_) {
        // Skip a single corrupt record rather than discarding the whole
        // history (which the next save() would then overwrite permanently).
      }
    }
    sessions.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return sessions;
  }

  Future<void> save(List<ChatSession> sessions) async {
    final ordered = [...sessions]
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    final snapshot = jsonEncode(
      ordered.take(50).map(_safeCheckpointJson).toList(growable: false),
    );
    final save = _pendingSave.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_sessionsKey, snapshot);
    });
    _pendingSave = save.catchError((_) {});
    await save;
  }

  Map<String, dynamic> _safeCheckpointJson(ChatSession session) => {
    'id': session.id,
    'workspace': session.workspace,
    'updatedAt': session.updatedAt.toIso8601String(),
    'entries': session.entries
        .map(
          (entry) => {
            'role': entry.role.name,
            'content': SecretScanner.redact(entry.content),
          },
        )
        .toList(growable: false),
    'agentMessages': session.entries
        .where(
          (entry) =>
              entry.role.name == 'user' || entry.role.name == 'assistant',
        )
        .map(
          (entry) => {
            'role': entry.role.name,
            'content': SecretScanner.redact(entry.content),
          },
        )
        .toList(growable: false),
  };
}
