import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'process_launch.dart';

class QualityCheck {
  const QualityCheck({
    required this.label,
    required this.executable,
    required this.arguments,
  });

  final String label;
  final String executable;
  final List<String> arguments;
}

class QualityCheckResult {
  const QualityCheckResult({
    required this.check,
    required this.exitCode,
    required this.output,
    required this.duration,
    this.timedOut = false,
  });

  final QualityCheck check;
  final int exitCode;
  final String output;
  final Duration duration;
  final bool timedOut;

  bool get passed => exitCode == 0 && !timedOut;
}

class QualityGateResult {
  const QualityGateResult({required this.checks});

  final List<QualityCheckResult> checks;

  bool get passed => checks.every((check) => check.passed);
  bool get skipped => checks.isEmpty;
}

typedef QualityCheckRunner =
    Future<QualityCheckResult> Function(
      String workspace,
      QualityCheck check,
      Duration timeout,
    );

class QualityGateService {
  QualityGateService({QualityCheckRunner? runner})
    : _runner = runner ?? _runCheck;

  final QualityCheckRunner _runner;

  Future<List<QualityCheck>> plan(
    String workspace,
    Iterable<String> changedPaths,
  ) async {
    final changed = changedPaths
        .map((item) => item.replaceAll('\\', '/'))
        .toSet();
    final checks = <QualityCheck>[];
    final hasPubspec = await File(
      path.join(workspace, 'pubspec.yaml'),
    ).exists();
    if (hasPubspec && changed.any((item) => item.endsWith('.dart'))) {
      checks.add(
        const QualityCheck(
          label: 'Dart analyze',
          executable: 'dart',
          arguments: ['analyze'],
        ),
      );
      final tests = <String>{};
      for (final changedPath in changed) {
        if (changedPath.startsWith('test/') &&
            changedPath.endsWith('_test.dart') &&
            await File(path.join(workspace, changedPath)).exists()) {
          tests.add(changedPath);
          continue;
        }
        if (!changedPath.startsWith('lib/') || !changedPath.endsWith('.dart')) {
          continue;
        }
        final basename = path.basenameWithoutExtension(changedPath);
        final direct = 'test/${basename}_test.dart';
        if (await File(path.join(workspace, direct)).exists()) {
          tests.add(direct);
        }
      }
      if (tests.isNotEmpty) {
        final sortedTests = tests.toList()..sort();
        checks.add(
          QualityCheck(
            label: 'Relevant Flutter tests',
            executable: 'flutter',
            arguments: ['test', ...sortedTests, '--concurrency=1'],
          ),
        );
      }
    }

    final pythonFiles = changed
        .where((item) => item.endsWith('.py'))
        .where((item) => File(path.join(workspace, item)).existsSync())
        .toList();
    if (pythonFiles.isNotEmpty) {
      checks.add(
        QualityCheck(
          label: 'Python syntax',
          executable: 'python',
          arguments: ['-m', 'py_compile', ...pythonFiles],
        ),
      );
    }

    for (final file in changed.where(
      (item) =>
          item.endsWith('.js') ||
          item.endsWith('.mjs') ||
          item.endsWith('.cjs'),
    )) {
      if (!await File(path.join(workspace, file)).exists()) continue;
      checks.add(
        QualityCheck(
          label: 'Node syntax: $file',
          executable: 'node',
          arguments: ['--check', file],
        ),
      );
    }

    if (await File(path.join(workspace, 'go.mod')).exists() &&
        changed.any((item) => item.endsWith('.go'))) {
      checks.add(
        const QualityCheck(
          label: 'Go tests',
          executable: 'go',
          arguments: ['test', './...'],
        ),
      );
    }
    if (await File(path.join(workspace, 'Cargo.toml')).exists() &&
        changed.any((item) => item.endsWith('.rs'))) {
      checks.add(
        const QualityCheck(
          label: 'Rust tests',
          executable: 'cargo',
          arguments: ['test', '--quiet'],
        ),
      );
    }
    return checks;
  }

  Future<QualityGateResult> run(
    String workspace,
    Iterable<String> changedPaths, {
    Duration timeoutPerCheck = const Duration(minutes: 2),
    void Function(String status)? onStatus,
  }) async {
    final checks = await plan(workspace, changedPaths);
    final results = <QualityCheckResult>[];
    for (final check in checks) {
      onStatus?.call(check.label);
      late final QualityCheckResult result;
      try {
        result = await _runner(workspace, check, timeoutPerCheck);
      } catch (error) {
        result = QualityCheckResult(
          check: check,
          exitCode: -1,
          output: '$error',
          duration: Duration.zero,
        );
      }
      results.add(result);
      if (!result.passed) break;
    }
    return QualityGateResult(checks: results);
  }

  static Future<QualityCheckResult> _runCheck(
    String workspace,
    QualityCheck check,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    // runInShell: false keeps shell metacharacters in file names (e.g. `&` or
    // spaces) out of the command line; batch wrappers are re-routed through
    // cmd.exe without interpreting the arguments.
    final launch = resolveProcessLaunch(check.executable, check.arguments);
    final process = await Process.start(
      launch.executable,
      launch.arguments,
      workingDirectory: workspace,
      runInShell: false,
    );
    final stdoutFuture = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderrFuture = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () async {
        timedOut = true;
        await _terminate(process);
        return -1;
      },
    );
    final output = '${await stdoutFuture}${await stderrFuture}';
    stopwatch.stop();
    return QualityCheckResult(
      check: check,
      exitCode: exitCode,
      output: output.length <= 30000
          ? output.trim()
          : '${output.substring(0, 30000).trim()}\n... output truncated ...',
      duration: stopwatch.elapsed,
      timedOut: timedOut,
    );
  }

  static Future<void> _terminate(Process process) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill.exe', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
        return;
      } catch (_) {
        // Fall through to direct process termination.
      }
    }
    process.kill(ProcessSignal.sigkill);
  }
}
