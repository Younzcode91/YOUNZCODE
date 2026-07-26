import 'dart:io';

class GitStatus {
  const GitStatus({
    required this.isRepository,
    this.branch = '',
    this.files = const {},
  });

  final bool isRepository;
  final String branch;
  final Map<String, String> files;

  bool get dirty => files.isNotEmpty;
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
    final files = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.length < 4) continue;
      final code = line.substring(0, 2).trim();
      final file = line.substring(3).split(' -> ').last.replaceAll('"', '');
      files[file.replaceAll('\\', '/')] = code.contains('?')
          ? 'A'
          : code.contains('D')
          ? 'D'
          : 'M';
    }
    return GitStatus(isRepository: true, branch: branch, files: files);
  }

  Future<String> diff(String workspace) async {
    final unstaged = await Process.run('git', [
      'diff',
      '--no-ext-diff',
    ], workingDirectory: workspace);
    final staged = await Process.run('git', [
      'diff',
      '--cached',
      '--no-ext-diff',
    ], workingDirectory: workspace);
    return '${staged.stdout}${unstaged.stdout}'.trim();
  }

  Future<String> history(String workspace) async {
    final result = await Process.run('git', [
      'log',
      '--oneline',
      '--decorate',
      '-30',
    ], workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw ProcessException('git', const [], '${result.stderr}');
    }
    return '${result.stdout}'.trim();
  }

  Future<void> createBranch(String workspace, String name) async {
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(name)) {
      throw const FormatException('Nama branch tidak valid.');
    }
    final result = await Process.run('git', [
      'switch',
      '-c',
      name,
    ], workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw ProcessException('git', const [], '${result.stderr}');
    }
  }
}
