import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/multi_agent_service.dart';

void main() {
  test('menjalankan task paralel pada branch dan worktree berbeda', () async {
    final commands = <List<String>>[];
    final running = <String>{};
    var peak = 0;
    final manager = GitWorktreeManager(
      storageRoot: r'C:\temp\younz-worktrees',
      clock: () => DateTime.fromMicrosecondsSinceEpoch(1000),
      processRunner: (executable, arguments, {workingDirectory}) async {
        commands.add(arguments);
        if (arguments.first == 'rev-parse') {
          return ProcessResult(1, 0, r'C:\repo', '');
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    final changes = <AgentTask>[];
    final orchestrator = MultiAgentOrchestrator(
      workspace: r'C:\repo',
      worktreeManager: manager,
      maxParallel: 2,
      onTaskChanged: changes.add,
      runner: (task, worktree) async {
        running.add(task.id);
        peak = running.length > peak ? running.length : peak;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        running.remove(task.id);
        return 'done ${task.prompt}';
      },
    );

    final tasks = await orchestrator.run(['buat API', 'buat UI', 'buat tes']);

    expect(tasks, hasLength(3));
    expect(
      tasks.every((task) => task.status == AgentTaskStatus.completed),
      true,
    );
    expect(tasks.map((task) => task.branch).toSet(), hasLength(3));
    expect(tasks.map((task) => task.worktree).toSet(), hasLength(3));
    expect(peak, 2);
    expect(
      commands.where((command) => command.take(2).join(' ') == 'worktree add'),
      hasLength(3),
    );
    expect(
      changes.any((task) => task.status == AgentTaskStatus.running),
      isTrue,
    );
  });

  test('kegagalan satu task tidak menghentikan task lain', () async {
    final manager = GitWorktreeManager(
      storageRoot: r'C:\temp\younz-worktrees',
      processRunner: (executable, arguments, {workingDirectory}) async {
        if (arguments.first == 'rev-parse') {
          return ProcessResult(1, 0, r'C:\repo', '');
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    final orchestrator = MultiAgentOrchestrator(
      workspace: r'C:\repo',
      worktreeManager: manager,
      runner: (task, _) async {
        if (task.prompt == 'gagal') throw StateError('boom');
        return 'ok';
      },
    );

    final tasks = await orchestrator.run(['gagal', 'berhasil']);

    expect(tasks.first.status, AgentTaskStatus.failed);
    expect(tasks.last.status, AgentTaskStatus.completed);
  });
}
