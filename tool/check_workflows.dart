import 'dart:io';

import 'package:yaml/yaml.dart';

/// Validates that every GitHub Actions workflow file parses as YAML and has
/// the top-level `on` (triggers) and `jobs` keys GitHub requires.
///
/// GitHub silently refuses to register a workflow whose YAML does not parse —
/// the run never appears, and broken tag-triggered workflows like release.yml
/// can ship a release with no pipeline. This check exists so the failure is
/// caught before a `v*` tag is pushed (pre-push hook in tool/hooks/pre-push)
/// and in CI (workflow-lint.yml) instead of after.
///
/// Usage:
///   dart run tool/check_workflows.dart [--dir .github/workflows]
Future<void> main(List<String> args) async {
  var directory = '.github/workflows';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dir':
        if (i + 1 >= args.length) {
          stderr.writeln('--dir membutuhkan path direktori.');
          exitCode = 64;
          return;
        }
        directory = args[++i];
      default:
        stderr.writeln('Argumen tidak dikenal: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final dir = Directory(directory);
  if (!dir.existsSync()) {
    stderr.writeln('Direktori tidak ditemukan: $directory');
    exitCode = 2;
    return;
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where(
            (file) => file.path.endsWith('.yml') || file.path.endsWith('.yaml'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('Tidak ada file workflow di $directory');
    exitCode = 2;
    return;
  }

  var failed = 0;
  for (final file in files) {
    final error = _validate(file);
    if (error == null) {
      stdout.writeln('OK   ${file.path}');
    } else {
      failed++;
      stderr.writeln('FAIL ${file.path}: $error');
    }
  }

  if (failed == 0) {
    stdout.writeln('Semua ${files.length} workflow valid.');
  } else {
    stderr.writeln('$failed dari ${files.length} workflow tidak valid.');
    exitCode = 1;
  }
}

/// Returns a human-readable error when [file] is not a valid workflow, or
/// null when it parses and has the required top-level keys.
String? _validate(File file) {
  final String content;
  try {
    content = file.readAsStringSync();
  } catch (error) {
    return 'tidak dapat dibaca: $error';
  }
  if (content.trim().isEmpty) {
    return 'file kosong';
  }

  final Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException catch (error) {
    return 'YAML tidak valid: ${error.message}';
  }
  if (doc is! YamlMap) {
    return 'dokumen YAML bukan mapping di level teratas';
  }
  if (!doc.containsKey('on')) {
    return 'kehilangan kunci "on" (triggers)';
  }
  if (!doc.containsKey('jobs')) {
    return 'kehilangan kunci "jobs"';
  }
  return null;
}
