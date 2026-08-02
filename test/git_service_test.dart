import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/git_service.dart';

void main() {
  test('stage, unstage, commit, branch, dan status bekerja', () async {
    final root = await Directory.systemTemp.createTemp('younz-git-');
    addTearDown(() => root.delete(recursive: true));
    await _git(root.path, ['init']);
    await _git(root.path, ['config', 'user.email', 'test@example.com']);
    await _git(root.path, ['config', 'user.name', 'YOUNZ Test']);
    final file = File('${root.path}${Platform.pathSeparator}sample.txt');
    await file.writeAsString('one\n');
    await _git(root.path, ['add', 'sample.txt']);
    await _git(root.path, ['commit', '-m', 'initial']);
    final service = const GitService();

    await file.writeAsString('two\n');
    var status = await service.status(root.path);
    expect(status.entries.single.unstaged, isTrue);

    await service.stage(root.path, ['sample.txt']);
    status = await service.status(root.path);
    expect(status.entries.single.staged, isTrue);

    await service.unstage(root.path, ['sample.txt']);
    status = await service.status(root.path);
    expect(status.entries.single.unstaged, isTrue);

    await service.stage(root.path, ['sample.txt']);
    await service.commit(root.path, 'change sample');
    expect((await service.status(root.path)).dirty, isFalse);

    await service.createBranch(root.path, 'codex/test-branch');
    expect((await service.status(root.path)).branch, 'codex/test-branch');
    expect(await service.branches(root.path), contains('codex/test-branch'));
  });
}

Future<void> _git(String workspace, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workspace,
  );
  if (result.exitCode != 0) {
    throw ProcessException('git', arguments, '${result.stderr}');
  }
}
