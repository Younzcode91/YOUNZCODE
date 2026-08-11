import 'dart:io';

/// Resolves how to launch [executable] with [arguments] so every launch site
/// can use `runInShell: false`: shell metacharacters inside file names or
/// arguments must never be interpreted by a shell.
///
/// * Real executables (and POSIX shebang scripts) are launched directly.
/// * On Windows, batch wrappers (`.bat`/`.cmd`, which CreateProcess cannot
///   run) are launched through `cmd.exe` with each token passed as its own
///   argv element. cmd keeps `&`, `|`, `<`, `>`, and spaces inside quoted
///   tokens literal, so an argument like `a & b.py` stays a single argument.
///
/// Remaining cmd limitations for batch wrappers only: `^` is consumed as
/// cmd's escape character and `%VAR%` expands. Both are inherent to how cmd
/// parses a batch invocation and never allow command chaining for file names
/// containing `&`, `|`, `<`, `>`, or spaces.
///
/// [searchPath] overrides the Windows PATH (used by tests); on POSIX the
/// executable is returned unchanged.
({String executable, List<String> arguments}) resolveProcessLaunch(
  String executable,
  List<String> arguments, {
  String? searchPath,
}) {
  if (!Platform.isWindows) {
    // POSIX launches scripts through their shebang line; no shell needed.
    return (executable: executable, arguments: arguments);
  }
  final lower = executable.toLowerCase();
  if (lower.endsWith('.exe') || lower.endsWith('.com')) {
    return (executable: executable, arguments: arguments);
  }
  if (lower.endsWith('.bat') || lower.endsWith('.cmd')) {
    return (
      executable: 'cmd.exe',
      arguments: ['/d', '/c', executable, ...arguments],
    );
  }
  final resolved = _resolveOnPath(executable, searchPath);
  if (resolved == null) {
    // Not found on PATH; let CreateProcess surface the real error.
    return (executable: executable, arguments: arguments);
  }
  final resolvedLower = resolved.toLowerCase();
  if (resolvedLower.endsWith('.bat') || resolvedLower.endsWith('.cmd')) {
    return (
      executable: 'cmd.exe',
      arguments: ['/d', '/c', resolved, ...arguments],
    );
  }
  return (executable: resolved, arguments: arguments);
}

String? _resolveOnPath(String name, String? pathOverride) {
  final pathEnv =
      pathOverride ??
      Platform.environment['Path'] ??
      Platform.environment['PATH'] ??
      '';
  for (final dir in pathEnv.split(';')) {
    final trimmed = dir.trim();
    if (trimmed.isEmpty) continue;
    final base = trimmed.endsWith('\\') || trimmed.endsWith('/')
        ? trimmed
        : '$trimmed\\';
    final bare = '$base$name';
    // An extensionless PE file (e.g. some SDK shims) can run directly; a
    // shebang script (like Flutter's Git-Bash wrappers) cannot.
    if (_isPeFile(bare)) return bare;
    for (final extension in const ['.exe', '.com', '.cmd', '.bat']) {
      final candidate = '$base$name$extension';
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

bool _isPeFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return false;
    final raf = file.openSync();
    try {
      final bytes = raf.readSync(2);
      return bytes.length == 2 && bytes[0] == 0x4D && bytes[1] == 0x5A;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}
