import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

enum AgentTaskStatus {
  queued,
  preparing,
  running,
  completed,
  failed,
  cancelled,
}

class AgentTask {
  const AgentTask({
    required this.id,
    required this.prompt,
    this.status = AgentTaskStatus.queued,
    this.branch = '',
    this.worktree = '',
    this.result = '',
    this.error = '',
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String prompt;
  final AgentTaskStatus status;
  final String branch;
  final String worktree;
  final String result;
  final String error;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  AgentTask copyWith({
    AgentTaskStatus? status,
    String? branch,
    String? worktree,
    String? result,
    String? error,
    DateTime? startedAt,
    DateTime? finishedAt,
  }) => AgentTask(
    id: id,
    prompt: prompt,
    status: status ?? this.status,
    branch: branch ?? this.branch,
    worktree: worktree ?? this.worktree,
    result: result ?? this.result,
    error: error ?? this.error,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
  );
}

typedef GitProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

class GitWorktreeManager {
  GitWorktreeManager({
    String? storageRoot,
    GitProcessRunner? processRunner,
    DateTime Function()? clock,
  }) : _storageRoot =
           storageRoot ??
           path.join(Directory.systemTemp.path, 'YOUNZCODE', 'worktrees'),
       _processRunner = processRunner ?? _runProcess,
       _clock = clock ?? DateTime.now;

  final String _storageRoot;
  final GitProcessRunner _processRunner;
  final DateTime Function() _clock;

  Future<({String branch, String worktree})> prepare(
    String workspace,
    String prompt,
    int index,
  ) async {
    final rootResult = await _git(workspace, ['rev-parse', '--show-toplevel']);
    final repositoryRoot = '${rootResult.stdout}'.trim();
    if (repositoryRoot.isEmpty) {
      throw StateError('Workspace bukan repository Git.');
    }
    final stamp = _clock().microsecondsSinceEpoch;
    final slug = _slug(prompt);
    final branch = 'codex/agent-$slug-$stamp-$index';
    final repositoryId = _stableHash(path.normalize(repositoryRoot));
    final worktree = path.join(_storageRoot, repositoryId, '$stamp-$index');
    await Directory(path.dirname(worktree)).create(recursive: true);
    await _git(repositoryRoot, [
      'worktree',
      'add',
      '-b',
      branch,
      worktree,
      'HEAD',
    ]);
    return (branch: branch, worktree: worktree);
  }

  Future<void> remove(String workspace, String worktree) async {
    final resolvedWorkspace = path.normalize(path.absolute(workspace));
    final resolvedWorktree = path.normalize(path.absolute(worktree));
    final resolvedStorage = path.normalize(path.absolute(_storageRoot));
    if (!path.isWithin(resolvedStorage, resolvedWorktree) ||
        resolvedWorktree == resolvedWorkspace) {
      throw StateError('Worktree berada di luar storage YOUNZCODE.');
    }
    await _git(workspace, ['worktree', 'remove', '--force', resolvedWorktree]);
  }

  Future<ProcessResult> _git(
    String workingDirectory,
    List<String> arguments,
  ) async {
    final result = await _processRunner(
      'git',
      arguments,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return result;
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => Process.run(executable, arguments, workingDirectory: workingDirectory);

  static String _slug(String prompt) {
    final value = prompt
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (value.isEmpty) return 'task';
    return value.substring(0, value.length.clamp(1, 28));
  }

  static String _stableHash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value.toLowerCase())) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }
}

typedef IsolatedAgentRunner =
    Future<String> Function(AgentTask task, String worktree);
typedef AgentTaskChanged = void Function(AgentTask task);

class MultiAgentOrchestrator {
  MultiAgentOrchestrator({
    required this.workspace,
    required this.runner,
    GitWorktreeManager? worktreeManager,
    this.maxParallel = 3,
    this.onTaskChanged,
  }) : worktreeManager = worktreeManager ?? GitWorktreeManager();

  final String workspace;
  final IsolatedAgentRunner runner;
  final GitWorktreeManager worktreeManager;
  final int maxParallel;
  final AgentTaskChanged? onTaskChanged;

  Future<List<AgentTask>> run(List<String> prompts) async {
    if (prompts.isEmpty) return const [];
    final tasks = [
      for (var index = 0; index < prompts.length; index++)
        AgentTask(
          id: '${DateTime.now().microsecondsSinceEpoch}-$index',
          prompt: prompts[index].trim(),
        ),
    ];
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < tasks.length) {
        final index = cursor++;
        tasks[index] = await _runTask(tasks[index], index);
      }
    }

    final workers = maxParallel.clamp(1, tasks.length);
    await Future.wait([for (var index = 0; index < workers; index++) worker()]);
    return List.unmodifiable(tasks);
  }

  Future<AgentTask> _runTask(AgentTask task, int index) async {
    var current = task.copyWith(
      status: AgentTaskStatus.preparing,
      startedAt: DateTime.now(),
    );
    onTaskChanged?.call(current);
    try {
      final prepared = await worktreeManager.prepare(
        workspace,
        task.prompt,
        index,
      );
      current = current.copyWith(
        status: AgentTaskStatus.running,
        branch: prepared.branch,
        worktree: prepared.worktree,
      );
      onTaskChanged?.call(current);
      final result = await runner(current, prepared.worktree);
      current = current.copyWith(
        status: AgentTaskStatus.completed,
        result: result,
        finishedAt: DateTime.now(),
      );
    } catch (error) {
      current = current.copyWith(
        status: AgentTaskStatus.failed,
        error: '$error',
        finishedAt: DateTime.now(),
      );
    }
    onTaskChanged?.call(current);
    return current;
  }
}
