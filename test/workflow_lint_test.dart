import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'tool_runner.dart';

/// Runs tool/check_workflows.dart against [dir] and returns the process
/// result. The precompiled binary is used when present (build_tools.sh).
Future<ProcessResult> _check(String dir) async {
  final (executable, arguments) = toolLaunch('tool/check_workflows.dart', [
    '--dir',
    dir,
  ]);
  return Process.run(
    executable,
    arguments,
    workingDirectory: _packageRoot(),
    runInShell: false,
  ).timeout(const Duration(seconds: 90));
}

String _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

Future<Directory> _workflowDir() async {
  final root = await Directory.systemTemp.createTemp('younzcode-wf-lint-');
  addTearDown(() => root.delete(recursive: true));
  return Directory('${root.path}${Platform.pathSeparator}workflows')
    ..createSync(recursive: true);
}

void main() {
  test('semua workflow repo valid', () async {
    final result = await _check('.github/workflows');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('valid'));
  });

  test('YAML rusak (heredoc keluar dari block scalar) ditolak', () async {
    final dir = await _workflowDir();
    // Reproduksi bug yang membuat release.yml tidak terdaftar: baris python
    // di kolom 0 mengakhiri block scalar `run: |` lebih awal.
    File('${dir.path}${Platform.pathSeparator}broken.yml').writeAsStringSync(
      'name: Bad\n'
      'on:\n'
      '  push:\n'
      '\n'
      'jobs:\n'
      '  x:\n'
      '    runs-on: ubuntu-latest\n'
      '    steps:\n'
      '      - run: |\n'
      '          echo hi\n'
      'import json, os\n',
    );
    final result = await _check(dir.path);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('broken.yml'));
    expect(result.stderr, contains('YAML tidak valid'));
  });

  test('kehilangan kunci on atau jobs ditolak', () async {
    final dir = await _workflowDir();
    File('${dir.path}${Platform.pathSeparator}no_on.yml').writeAsStringSync(
      'name: No triggers\n'
      'jobs:\n'
      '  x:\n'
      '    runs-on: ubuntu-latest\n'
      '    steps:\n'
      '      - run: echo hi\n',
    );
    File('${dir.path}${Platform.pathSeparator}no_jobs.yml').writeAsStringSync(
      'name: No jobs\n'
      'on:\n'
      '  push:\n',
    );
    final result = await _check(dir.path);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('no_on.yml'));
    expect(result.stderr, contains('"on"'));
    expect(result.stderr, contains('no_jobs.yml'));
    expect(result.stderr, contains('"jobs"'));
  });

  test('file valid dalam direktori campuran tetap lolos', () async {
    final dir = await _workflowDir();
    File('${dir.path}${Platform.pathSeparator}ok.yml').writeAsStringSync(
      'name: Good\n'
      'on:\n'
      '  workflow_dispatch:\n'
      '\n'
      'jobs:\n'
      '  x:\n'
      '    runs-on: ubuntu-latest\n'
      '    steps:\n'
      '      - run: echo hi\n',
    );
    File(
      '${dir.path}${Platform.pathSeparator}note.txt',
    ).writeAsStringSync('bukan yaml');
    final result = await _check(dir.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('ok.yml'));
    expect(result.stdout, contains('valid'));
  });
}
