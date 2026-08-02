part of '../main.dart';

extension _GoalWorkflow on _AgentHomePageState {
  Future<void> _runGoalCommand(String argument) async {
    final value = argument.trim();
    final action = value.toLowerCase();
    if (value.isEmpty || action == 'status') {
      final goal = _goal;
      if (goal == null) {
        _addLocalResponse(
          'Belum ada goal. Gunakan "/goal tujuan yang ingin diselesaikan".\n'
          'Kontrol: "/goal status", "/goal resume", "/goal stop", dan '
          '"/goal clear".',
        );
        return;
      }
      _addLocalResponse(
        'Goal ${goal.status.name.toUpperCase()} · ${goal.turnCount} turn\n'
        '${goal.objective}'
        '${goal.lastDetail.isEmpty ? '' : '\n\n${goal.lastDetail}'}',
      );
      return;
    }
    if (action == 'resume') {
      await _resumeGoal();
      return;
    }
    if (action == 'stop' || action == 'pause') {
      await _pauseGoal(stopped: action == 'stop');
      return;
    }
    if (action == 'clear') {
      await _clearGoal();
      return;
    }
    await _startGoal(value);
  }

  Future<bool> _prepareGoalRun() async {
    if (_busy) {
      _showMessage('Tunggu operasi agent saat ini selesai.');
      return false;
    }
    if (_workspace.isEmpty || !Directory(_workspace).existsSync()) {
      _showMessage('Pilih folder workspace yang valid terlebih dahulu.');
      return false;
    }
    if (_apiKey.isEmpty) {
      await _openSettings();
      if (_apiKey.isEmpty) return false;
    }
    return mounted && await _confirmMainBranchWork();
  }

  Future<void> _startGoal(String objective) async {
    if (!await _prepareGoalRun()) return;
    final goal = AgentGoal.start(objective);
    _updateState(() => _goal = goal);
    final prompt = await _buildPromptWithContext(
      _goalCoordinator.initialPrompt(goal.objective),
    );
    await _runAgentOperation(
      (agent) => agent.send(prompt),
      userEntry: ChatEntry(
        role: ChatRole.user,
        content: '/goal ${goal.objective}',
      ),
      driveGoal: true,
    );
  }

  Future<void> _resumeGoal() async {
    final goal = _goal;
    if (goal == null) {
      _addLocalResponse(
        'Belum ada goal untuk dilanjutkan. Gunakan "/goal <tujuan>".',
        error: true,
      );
      return;
    }
    if (goal.status == AgentGoalStatus.completed) {
      _addLocalResponse(
        'Goal ini sudah selesai. Gunakan "/goal <tujuan baru>" atau '
        '"/goal clear".',
      );
      return;
    }
    if (!await _prepareGoalRun()) return;
    final resumed = goal.copyWith(
      status: AgentGoalStatus.active,
      updatedAt: DateTime.now(),
      lastDetail: 'Dilanjutkan oleh pengguna.',
    );
    _updateState(() => _goal = resumed);
    await _persistActiveChat();
    await _runAgentOperation(
      (agent) => agent.send(_goalCoordinator.resumePrompt(resumed)),
      driveGoal: true,
    );
  }

  Future<void> _pauseGoal({bool stopped = false}) async {
    final goal = _goal;
    if (goal == null) {
      _addLocalResponse('Belum ada goal aktif.', error: true);
      return;
    }
    if (_busy) {
      await _cancelAgent();
      return;
    }
    _updateState(() {
      _goal = goal.copyWith(
        status: stopped ? AgentGoalStatus.stopped : AgentGoalStatus.paused,
        updatedAt: DateTime.now(),
        lastDetail: stopped
            ? 'Dihentikan oleh pengguna.'
            : 'Dijeda oleh pengguna.',
      );
    });
    await _persistActiveChat();
  }

  Future<void> _clearGoal() async {
    if (_busy) {
      _showMessage('Hentikan agent sebelum menghapus goal.');
      return;
    }
    if (_goal == null) {
      _addLocalResponse('Tidak ada goal yang perlu dihapus.');
      return;
    }
    _updateState(() => _goal = null);
    await _persistActiveChat();
    _addLocalResponse('Goal dihapus dari chat ini.');
  }

  AgentGoal? _goalRestoredFromSession(AgentGoal? goal) {
    if (goal == null || goal.status != AgentGoalStatus.active) return goal;
    return goal.copyWith(
      status: AgentGoalStatus.paused,
      updatedAt: DateTime.now(),
      lastDetail:
          'Aplikasi atau chat dibuka kembali. Gunakan "/goal resume" untuk '
          'melanjutkan dengan aman.',
    );
  }
}
