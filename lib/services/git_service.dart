import 'dart:io';

import 'package:path/path.dart' as path;

class GitFileStatus {
  const GitFileStatus({
    required this.path,
    required this.indexStatus,
    required this.workTreeStatus,
  });

  final String path;
  final String indexStatus;
  final String workTreeStatus;

  bool get untracked => indexStatus == '?' && workTreeStatus == '?';
  bool get staged => !{' ', '?'}.contains(indexStatus);
  bool get unstaged => !{' ', '?'}.contains(workTreeStatus) || untracked;
  bool get conflicted => const {
    'DD',
    'AU',
    'UD',
    'UA',
    'DU',
    'AA',
    'UU',
  }.contains('$indexStatus$workTreeStatus');

  String get displayStatus {
    if (conflicted) return '!';
    if (untracked || indexStatus == 'A') return 'A';
    if (indexStatus == 'D' || workTreeStatus == 'D') return 'D';
    if (indexStatus == 'R' || workTreeStatus == 'R') return 'R';
    return 'M';
  }
}

class GitWorktree {
  const GitWorktree({
    required this.path,
    required this.head,
    required this.branch,
    this.bare = false,
    this.detached = false,
  });

  final String path;
  final String head;
  final String branch;
  final bool bare;
  final bool detached;
}

class GitStatus {
  const GitStatus({
    required this.isRepository,
    this.branch = '',
    this.entries = const [],
  });

  final bool isRepository;
  final String branch;
  final List<GitFileStatus> entries;

  Map<String, String> get files => {
    for (final entry in entries) entry.path: entry.displayStatus,
  };
  List<GitFileStatus> get conflicts =>
      entries.where((entry) => entry.conflicted).toList();
  bool get dirty => entries.isNotEmpty;
  bool get hasStaged => entries.any((entry) => entry.staged);
  bool get mainBranch => {'main', 'master'}.contains(branch.toLowerCase());
}

class GitService {
  const GitService();

  Future<GitStatus> status(String workspace) async {
    if (workspace.isEmpty) return const GitStatus(isRepository: false);
    final result = await Process.run('git', [
      'status',
      '--porcelain=v1',
      '--branch',
      '--untracked-files=all',
    ], workingDirectory: workspace);
    if (result.exitCode != 0) return const GitStatus(isRepository: false);
    final lines = '${result.stdout}'
        .split(RegExp(r'\r?\n'))
        .where((line) => line.isNotEmpty)
        .toList();
    final branchLine = lines.isEmpty ? '' : lines.first;
    final branch = branchLine
        .replaceFirst('## ', '')
        .split(RegExp(r'\.\.\.|\s'))
        .first;
    final entries = <GitFileStatus>[];
    for (final line in lines.skip(1)) {
      if (line.length < 4) continue;
      final rawPath = line.substring(3).split(' -> ').last;
      entries.add(
        GitFileStatus(
          path: _decodeGitPath(rawPath),
          indexStatus: line[0],
          workTreeStatus: line[1],
        ),
      );
    }
    return GitStatus(isRepository: true, branch: branch, entries: entries);
  }

  Future<String> diff(String workspace, {String? filePath}) async {
    final pathArguments = filePath == null
        ? const <String>[]
        : ['--', filePath];
    final unstaged = await _run(workspace, [
      'diff',
      '--no-ext-diff',
      ...pathArguments,
    ]);
    final staged = await _run(workspace, [
      'diff',
      '--cached',
      '--no-ext-diff',
      ...pathArguments,
    ]);
    return '${staged.stdout}${unstaged.stdout}'.trim();
  }

  Future<String> history(String workspace) async {
    final result = await _run(workspace, [
      'log',
      '--oneline',
      '--decorate',
      '-30',
    ]);
    return '${result.stdout}'.trim();
  }

  Future<List<String>> branches(String workspace) async {
    final result = await _run(workspace, [
      'branch',
      '--format=%(refname:short)',
    ]);
    return '${result.stdout}'
        .split(RegExp(r'\r?\n'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Future<List<GitWorktree>> worktrees(String workspace) async {
    final result = await _run(workspace, ['worktree', 'list', '--porcelain']);
    final records = '${result.stdout}'.trim().split(RegExp(r'\r?\n\r?\n'));
    return [
      for (final record in records)
        if (record.trim().isNotEmpty) _parseWorktree(record),
    ];
  }

  Future<void> stage(String workspace, Iterable<String> paths) async {
    final selected = paths.where((item) => item.isNotEmpty).toList();
    if (selected.isEmpty) return;
    await _run(workspace, ['add', '--', ...selected]);
  }

  Future<void> unstage(String workspace, Iterable<String> paths) async {
    final selected = paths.where((item) => item.isNotEmpty).toList();
    if (selected.isEmpty) return;
    final result = await Process.run('git', [
      'restore',
      '--staged',
      '--',
      ...selected,
    ], workingDirectory: workspace);
    if (result.exitCode == 0) return;
    await _run(workspace, ['reset', 'HEAD', '--', ...selected]);
  }

  Future<void> discard(String workspace, GitFileStatus entry) async {
    if (entry.untracked) {
      final root = path.normalize(path.absolute(workspace));
      final target = path.normalize(path.absolute(path.join(root, entry.path)));
      if (!path.isWithin(root, target) || await Directory(target).exists()) {
        throw StateError(
          'Hanya file untracked di dalam workspace yang dapat dihapus.',
        );
      }
      final file = File(target);
      if (await file.exists()) await file.delete();
      return;
    }
    if (entry.staged) {
      await unstage(workspace, [entry.path]);
    }
    await _run(workspace, ['restore', '--worktree', '--', entry.path]);
  }

  Future<void> commit(String workspace, String message) async {
    final normalized = message.trim();
    if (normalized.isEmpty || normalized.length > 300) {
      throw const FormatException('Pesan commit harus berisi 1-300 karakter.');
    }
    await _run(workspace, ['commit', '-m', normalized]);
  }

  Future<void> createBranch(String workspace, String name) async {
    _validateBranch(name);
    await _run(workspace, ['switch', '-c', name]);
  }

  Future<void> switchBranch(String workspace, String name) async {
    _validateBranch(name);
    await _run(workspace, ['switch', name]);
  }

  Future<void> mergeBranch(String workspace, String name) async {
    _validateBranch(name);
    await _run(workspace, ['merge', '--no-ff', name]);
  }

  Future<void> abortMerge(String workspace) async {
    await _run(workspace, ['merge', '--abort']);
  }

  Future<void> pushCurrent(String workspace) async {
    final current = await status(workspace);
    if (!current.isRepository || current.branch.isEmpty) {
      throw StateError('Branch aktif tidak ditemukan.');
    }
    await _run(workspace, ['push', '-u', 'origin', current.branch]);
  }

  Future<void> removeWorktree(
    String workspace,
    GitWorktree worktree, {
    bool force = false,
  }) async {
    final workspaceRoot = path.normalize(path.absolute(workspace));
    final target = path.normalize(path.absolute(worktree.path));
    if (target == workspaceRoot) {
      throw StateError('Worktree utama tidak dapat dihapus.');
    }
    await _run(workspace, ['worktree', 'remove', if (force) '--force', target]);
  }

  Future<ProcessResult> _run(String workspace, List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: workspace,
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

  static void _validateBranch(String name) {
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(name) ||
        name.startsWith('/') ||
        name.endsWith('/') ||
        name.contains('..')) {
      throw const FormatException('Nama branch tidak valid.');
    }
  }

  static String _decodeGitPath(String value) {
    final trimmed = value.trim();
    if (!(trimmed.startsWith('"') && trimmed.endsWith('"'))) {
      return trimmed.replaceAll('\\', '/');
    }
    return trimmed
        .substring(1, trimmed.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', '/');
  }

  static GitWorktree _parseWorktree(String record) {
    var worktreePath = '';
    var head = '';
    var branch = '';
    var bare = false;
    var detached = false;
    for (final line in record.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('worktree ')) worktreePath = line.substring(9);
      if (line.startsWith('HEAD ')) head = line.substring(5);
      if (line.startsWith('branch ')) {
        branch = line.substring(7).replaceFirst('refs/heads/', '');
      }
      if (line == 'bare') bare = true;
      if (line == 'detached') detached = true;
    }
    return GitWorktree(
      path: worktreePath,
      head: head,
      branch: branch,
      bare: bare,
      detached: detached,
    );
  }
}
