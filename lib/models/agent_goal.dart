enum AgentGoalStatus { active, completed, blocked, paused, stopped }

class AgentGoal {
  const AgentGoal({
    required this.objective,
    required this.status,
    required this.turnCount,
    required this.updatedAt,
    this.lastDetail = '',
  });

  factory AgentGoal.start(String objective) => AgentGoal(
    objective: objective.trim(),
    status: AgentGoalStatus.active,
    turnCount: 0,
    updatedAt: DateTime.now(),
  );

  factory AgentGoal.fromJson(Map<String, dynamic> json) {
    final objective = (json['objective'] as String? ?? '').trim();
    if (objective.isEmpty) {
      throw const FormatException('Goal objective is empty.');
    }
    final rawStatus = json['status'] as String? ?? '';
    final statuses = AgentGoalStatus.values.where(
      (candidate) => candidate.name == rawStatus,
    );
    return AgentGoal(
      objective: objective,
      status: statuses.isEmpty ? AgentGoalStatus.paused : statuses.first,
      turnCount: (json['turnCount'] as num?)?.toInt() ?? 0,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      lastDetail: json['lastDetail'] as String? ?? '',
    );
  }

  final String objective;
  final AgentGoalStatus status;
  final int turnCount;
  final DateTime updatedAt;
  final String lastDetail;

  bool get canResume =>
      status == AgentGoalStatus.active ||
      status == AgentGoalStatus.paused ||
      status == AgentGoalStatus.blocked ||
      status == AgentGoalStatus.stopped;

  AgentGoal copyWith({
    AgentGoalStatus? status,
    int? turnCount,
    DateTime? updatedAt,
    String? lastDetail,
  }) => AgentGoal(
    objective: objective,
    status: status ?? this.status,
    turnCount: turnCount ?? this.turnCount,
    updatedAt: updatedAt ?? this.updatedAt,
    lastDetail: lastDetail ?? this.lastDetail,
  );

  Map<String, dynamic> toJson() => {
    'objective': objective,
    'status': status.name,
    'turnCount': turnCount,
    'updatedAt': updatedAt.toIso8601String(),
    if (lastDetail.isNotEmpty) 'lastDetail': lastDetail,
  };
}
