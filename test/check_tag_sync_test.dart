import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'tool_runner.dart';

/// Builds a throwaway git repo with the release workflows committed. The tag
/// v1.0.0 and both branches land on the same tip by default; the flags make a
/// specific ref lag behind so the sync check must catch it.
Future<_Repo> _repo({
  bool workflowsAtTag = true,
  bool manifestStale = false,
  bool mainStale = false,
  bool tagStale = false,
}) async {
  final root = await Directory.systemTemp.createTemp('younzcode-tag-sync-');
  addTearDown(() => root.delete(recursive: true));
  final repo = _Repo(root.path);

  Future<void> git(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: root.path,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} gagal: ${result.stderr}');
    }
  }

  await git(['init', '-b', 'main']);
  await git(['config', 'user.email', 'test@example.com']);
  await git(['config', 'user.name', 'Test']);
  await git(['config', 'commit.gpgsign', 'false']);

  Future<void> commit(String message) async {
    await git(['add', '-A']);
    await git(['commit', '-m', message]);
  }

  Directory('${repo.path}/.github/workflows').createSync(recursive: true);
  for (final wf in [
    '.github/workflows/release.yml',
    '.github/workflows/release-gate.yml',
    '.github/workflows/workflow-lint.yml',
  ]) {
    File('${repo.path}/$wf').writeAsStringSync(
      'name: ok\n'
      'on:\n'
      '  push:\n'
      '\n'
      'jobs:\n'
      '  x:\n'
      '    runs-on: ubuntu-latest\n'
      '    steps:\n'
      '      - run: echo hi\n',
    );
  }
  await commit('commit A with workflows');
  final a = (await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: root.path)).stdout.toString().trim();

  // A second commit so branches can genuinely lag the tag.
  File('${repo.path}/README.txt').writeAsStringSync('release prep');
  await commit('commit B (release prep)');
  final b = (await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: root.path)).stdout.toString().trim();

  // By default the tag and both branches sit on B (in sync).
  await git(['tag', 'v1.0.0']);
  await git(['update-ref', 'refs/remotes/origin/main', b]);
  await git(['update-ref', 'refs/remotes/origin/feature/manifest-branch', b]);

  if (workflowsAtTag == false) {
    // Drop the workflows after B: the tag tree then lacks them while both
    // branches still point at B (in-sync refs, broken artifact).
    await git(['rm', '-r', '.github']);
    await commit('commit C without workflows');
    final c = (await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root.path)).stdout.toString().trim();
    await git(['update-ref', 'refs/remotes/origin/main', c]);
    await git(['update-ref', 'refs/remotes/origin/feature/manifest-branch', c]);
    await git(['tag', '-f', 'v1.0.0', c]);
  }
  if (manifestStale) {
    await git(['update-ref', 'refs/remotes/origin/feature/manifest-branch', a]);
  }
  if (mainStale) {
    await git(['update-ref', 'refs/remotes/origin/main', a]);
  }
  if (tagStale) {
    await git(['tag', '-f', 'v1.0.0', a]);
  }
  repo.tagCommit = b;
  return repo;
}

Future<ProcessResult> _check(_Repo repo, List<String> args) async {
  final (executable, arguments) = toolLaunch('tool/check_tag_sync.dart', args);
  return Process.run(
    executable,
    arguments,
    workingDirectory: repo.path,
    runInShell: false,
  ).timeout(const Duration(seconds: 90));
}

void main() {
  test(
    'tag, main, dan cabang manifest sinkron + workflow di tag: PASS',
    () async {
      final repo = await _repo();
      final result = await _check(repo, [
        '--tag',
        'v1.0.0',
        '--branch',
        'feature/manifest-branch',
        '--main',
        'main',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('SYNC: PASS'));
    },
  );

  test('tag tertinggal dari main: FAIL', () async {
    final repo = await _repo();
    // Move main forward past the tag (tag points at a stale commit).
    File('${repo.path}/extra.txt').writeAsStringSync('newer');
    await Process.run('git', ['add', '-A'], workingDirectory: repo.path);
    await Process.run('git', [
      'commit',
      '-m',
      'after tag',
      '--no-gpg-sign',
    ], workingDirectory: repo.path);
    final newer = (await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: repo.path)).stdout.toString().trim();
    await Process.run('git', [
      'update-ref',
      'refs/remotes/origin/main',
      newer,
    ], workingDirectory: repo.path);
    await Process.run('git', [
      'update-ref',
      'refs/remotes/origin/feature/manifest-branch',
      newer,
    ], workingDirectory: repo.path);

    final result = await _check(repo, [
      '--tag',
      'v1.0.0',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('v1.0.0'));
    expect(result.stderr, contains('main'));
  });

  test('cabang manifest tertinggal (tidak memuat tag): FAIL', () async {
    final repo = await _repo(manifestStale: true);
    final result = await _check(repo, [
      '--tag',
      'v1.0.0',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('manifest'));
  });

  test('cabang manifest di depan tag (memuat tag): PASS', () async {
    final repo = await _repo();
    // The pipeline publishes the signed manifest onto the manifest branch
    // after building from the tag, legitimately moving it ahead of the tag.
    File('${repo.path}/updates.json').writeAsStringSync('{"releases": []}');
    final result = await Process.run('git', [
      'add',
      '-A',
    ], workingDirectory: repo.path);
    expect(result.exitCode, 0);
    final commit = await Process.run('git', [
      'commit',
      '-m',
      'release v1.0.0: manifest ditandatangani',
      '--no-gpg-sign',
    ], workingDirectory: repo.path);
    expect(commit.exitCode, 0);
    await Process.run('git', [
      'update-ref',
      'refs/remotes/origin/feature/manifest-branch',
      'HEAD',
    ], workingDirectory: repo.path);

    final check = await _check(repo, [
      '--tag',
      'v1.0.0',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
    expect(check.stdout, contains('SYNC: PASS'));
  });

  test('main tertinggal: FAIL', () async {
    final repo = await _repo(mainStale: true);
    final result = await _check(repo, [
      '--tag',
      'v1.0.0',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('main'));
  });

  test('tag tanpa workflow rilis: FAIL', () async {
    final repo = await _repo(workflowsAtTag: false);
    final result = await _check(repo, [
      '--tag',
      'v1.0.0',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('.github/workflows/release.yml'));
  });

  test('tag tidak ada: FAIL', () async {
    final repo = await _repo();
    final result = await _check(repo, [
      '--tag',
      'v9.9.9',
      '--branch',
      'feature/manifest-branch',
      '--main',
      'main',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('v9.9.9'));
  });
}

class _Repo {
  _Repo(this.path);
  final String path;
  late String tagCommit;
}
