import 'dart:io';

import 'package:kode_agent_desktop/services/process_launch.dart';

/// Launches a repo CLI tool for tests, preferring the precompiled binary in
/// build/tools/ (produced by `tool/build_tools.sh`) and falling back to
/// `dart run` when it is absent. Compiled AOT binaries start in ~80ms vs
/// ~5-7s for `dart run` (pub build hooks + JIT compile), which keeps the
/// CLI-heavy suites fast.
///
/// Usage:
///   final (executable, arguments) = toolLaunch('tool/sign_update.dart', args);
///   final result = await Process.run(
///     executable, arguments,
///     workingDirectory: _packageRoot(), runInShell: false,
///   );
(String executable, List<String> arguments) toolLaunch(
  String toolPath,
  List<String> args,
) {
  final sep = Platform.pathSeparator;
  final name = toolPath
      .split(RegExp(r'[\\/]'))
      .last
      .replaceAll(RegExp(r'\.dart$'), '');
  final binary = File(
    '${_packageRoot()}$sep${'build'}'
    '$sep${'tools'}$sep$name${Platform.isWindows ? '.exe' : ''}',
  );
  if (binary.existsSync()) {
    return (binary.path, args);
  }
  final resolved = resolveProcessLaunch('dart', ['run', toolPath, ...args]);
  return (resolved.executable, resolved.arguments);
}

/// Walks up from the CWD until the package root (pubspec.yaml) is found.
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
