import 'dart:io';

/// Verifies that a release tag is a proper release artifact: `main` points at
/// the tag's commit, the manifest-serving branch contains the tag, and the
/// tag's tree carries the release workflows.
///
/// A release tag is the artifact the release pipeline builds from, and
/// `updates.json` is published from it onto the manifest branch (the branch
/// `updateManifestUrl` in update_service.dart serves). If `main` drifted from
/// the tag, or the manifest branch is behind/unrelated to the tag, the
/// published manifest and the built installer can silently diverge.
///
/// The manifest branch is allowed to be AHEAD of the tag: the pipeline
/// publishes the signed manifest onto it after building from the tag, which
/// legitimately moves it forward. What must never happen is the manifest
/// branch being behind the tag (it would not contain this release) or on an
/// unrelated line. `main` must equal the tag strictly - the tag is the
/// release source of truth.
///
/// Usage:
///   dart run tool/check_tag_sync.dart \
///     [--tag v1.3.7] [--branch (manifest-branch)] [--main (branch)]
///
/// Defaults: tag from GITHUB_REF_NAME (or --tag), main = "main", manifest
/// branch from --branch / MANIFEST_BRANCH env / the repo default branch
/// (origin/HEAD). Refs are read from the local clone; fetch first in CI
/// (git fetch origin --tags main (manifest-branch)).
Future<void> main(List<String> args) async {
  String? tag;
  String? mainBranch;
  String? manifestBranch;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--tag':
        tag = args[++i];
      case '--main':
        mainBranch = args[++i];
      case '--branch':
        manifestBranch = args[++i];
      default:
        stderr.writeln('Argumen tidak dikenal: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  tag ??= Platform.environment['GITHUB_REF_NAME'];
  if (tag == null || tag.isEmpty) {
    stderr.writeln('Tag rilis tidak diberikan (--tag atau GITHUB_REF_NAME).');
    exitCode = 64;
    return;
  }
  mainBranch ??= 'main';
  manifestBranch ??= Platform.environment['MANIFEST_BRANCH'];
  manifestBranch ??= await _defaultBranch();

  final tagCommit = await _resolve('refs/tags/$tag');
  if (tagCommit == null) {
    stderr.writeln('FAIL - tag $tag tidak ditemukan di clone ini.');
    exitCode = 1;
    return;
  }
  final mainCommit = await _resolve('refs/remotes/origin/$mainBranch');
  if (mainCommit == null) {
    stderr.writeln('FAIL - cabang origin/$mainBranch tidak ditemukan.');
    exitCode = 1;
    return;
  }
  final manifestCommit = await _resolve('refs/remotes/origin/$manifestBranch');
  if (manifestCommit == null) {
    stderr.writeln('FAIL - cabang origin/$manifestBranch tidak ditemukan.');
    exitCode = 1;
    return;
  }

  final problems = <String>[];
  if (tagCommit != mainCommit) {
    problems.add(
      'tag $tag menunjuk ${_short(tagCommit)}, tapi main menunjuk '
      '${_short(mainCommit)}',
    );
  }
  // The manifest branch must contain the tag (equal or ahead). A branch that
  // is behind or unrelated does not serve this release's manifest.
  if (!await _isAncestor(tagCommit, manifestCommit)) {
    problems.add(
      'cabang manifest $manifestBranch (${_short(manifestCommit)}) tidak '
      'memuat tag $tag (${_short(tagCommit)})',
    );
  }

  // The tag itself must carry the release workflows — a tag pushed without
  // them would run no pipeline (or an outdated one) for its own release.
  const requiredWorkflows = [
    '.github/workflows/release.yml',
    '.github/workflows/release-gate.yml',
    '.github/workflows/workflow-lint.yml',
  ];
  for (final path in requiredWorkflows) {
    final exists = await _tagHasFile(tag, path);
    if (!exists) problems.add('tag $tag tidak memuat $path');
  }

  stdout
    ..writeln('Tag $tag          : ${_short(tagCommit)}')
    ..writeln('main              : ${_short(mainCommit)}')
    ..writeln('Manifest ($manifestBranch): ${_short(manifestCommit)}');

  if (problems.isEmpty) {
    stdout.writeln(
      'SYNC: PASS - tag == main dan cabang manifest memuat tag; '
      'workflow rilis ada di tag.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln('SYNC: FAIL - $problem');
  }
  exitCode = 1;
}

/// Resolves [ref] to a commit object id, or null when the ref is missing.
Future<String?> _resolve(String ref) async {
  final result = await Process.run('git', [
    'rev-parse',
    '--verify',
    '--quiet',
    '$ref^{commit}',
  ], runInShell: false);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trim();
}

/// Whether [path] exists in the tree of [tag].
Future<bool> _tagHasFile(String tag, String path) async {
  final result = await Process.run('git', [
    'cat-file',
    '-e',
    '$tag:$path',
  ], runInShell: false);
  return result.exitCode == 0;
}

/// Whether [ancestor] is an ancestor of (or equal to) [descendant].
Future<bool> _isAncestor(String ancestor, String descendant) async {
  final result = await Process.run('git', [
    'merge-base',
    '--is-ancestor',
    ancestor,
    descendant,
  ], runInShell: false);
  return result.exitCode == 0;
}

/// The repo default branch (origin/HEAD symref target), or null when unknown.
Future<String?> _defaultBranch() async {
  final result = await Process.run('git', [
    'symbolic-ref',
    '--quiet',
    'refs/remotes/origin/HEAD',
  ], runInShell: false);
  if (result.exitCode != 0) return null;
  final ref = (result.stdout as String).trim();
  const prefix = 'refs/remotes/origin/';
  return ref.startsWith(prefix) ? ref.substring(prefix.length) : null;
}

String _short(String commit) => commit.substring(0, 10);
