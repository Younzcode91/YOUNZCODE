import 'chat_entry.dart';
import 'agent_goal.dart';

class ChatSession {
  const ChatSession({
    required this.id,
    required this.workspace,
    required this.updatedAt,
    required this.entries,
    this.agentMessages = const [],
    this.goal,
  });

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
    id: json['id'] as String,
    workspace: json['workspace'] as String? ?? '',
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    entries: (json['entries'] as List? ?? const [])
        .map(
          (entry) =>
              ChatEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList(),
    agentMessages: (json['agentMessages'] as List? ?? const [])
        .whereType<Map>()
        .map((message) => Map<String, dynamic>.from(message))
        .toList(),
    goal: _parseGoal(json['goal']),
  );

  final String id;
  final String workspace;
  final DateTime updatedAt;
  final List<ChatEntry> entries;
  final List<Map<String, dynamic>> agentMessages;
  final AgentGoal? goal;

  String get title {
    final firstUser = entries.where((entry) => entry.role == ChatRole.user);
    if (firstUser.isEmpty) return 'Chat baru';
    final value = firstUser.first.content
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return value.length <= 42 ? value : '${value.substring(0, 42)}...';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'workspace': workspace,
    'updatedAt': updatedAt.toIso8601String(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
    if (agentMessages.isNotEmpty) 'agentMessages': agentMessages,
    if (goal != null) 'goal': goal!.toJson(),
  };
}

AgentGoal? _parseGoal(Object? value) {
  if (value is! Map) return null;
  try {
    return AgentGoal.fromJson(Map<String, dynamic>.from(value));
  } catch (_) {
    return null;
  }
}
