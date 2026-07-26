import 'dart:async';
import 'dart:convert';
import 'dart:io';

class PersistentTerminalService {
  PersistentTerminalService({required this.onOutput});

  final void Function(String output) onOutput;
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  Completer<int>? _pending;
  String? _marker;

  bool get running => _process != null;

  Future<void> start({
    required String workspace,
    required Map<String, String> environment,
  }) async {
    if (_process != null) return;
    final shell = _resolveShell();
    final process = await Process.start(
      shell.executable,
      shell.arguments,
      workingDirectory: workspace,
      environment: environment,
    );
    _process = process;
    _stdout = process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderr = process.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(onOutput);
    unawaited(process.exitCode.then((code) => _handleExit(process, code)));
  }

  Future<int> execute(String command) async {
    final process = _process;
    if (process == null) throw StateError('Terminal belum dimulai.');
    if (_pending != null) throw StateError('Command lain masih berjalan.');
    final marker = '__YOUNZCODE_${DateTime.now().microsecondsSinceEpoch}__';
    final pending = Completer<int>();
    _marker = marker;
    _pending = pending;
    if (Platform.isWindows) {
      process.stdin.writeln(r'$global:LASTEXITCODE = $null');
      process.stdin.writeln(command);
      process.stdin.writeln(r'$__younzSucceeded = $?');
      process.stdin.writeln(r'$__younzNativeExitCode = $LASTEXITCODE');
      process.stdin.writeln(
        "Write-Output ('$marker' + \$(if (\$__younzSucceeded) { "
        '0 } else { '
        'if (\$null -ne \$__younzNativeExitCode -and '
        '\$__younzNativeExitCode -ne 0) { \$__younzNativeExitCode } '
        'else { 1 } }))',
      );
    } else {
      // POSIX shells expose the just-run command's status directly as $?,
      // which printf reads before it runs, so the marker carries that code.
      process.stdin.writeln(command);
      process.stdin.writeln('printf \'%s%s\\n\' "$marker" "\$?"');
    }
    await process.stdin.flush();
    return pending.future;
  }

  // The persistent REPL is PowerShell on Windows and bash (falling back to sh)
  // elsewhere; both stream stdin commands and echo an exit-code marker.
  static _ShellSpec _resolveShell() {
    if (Platform.isWindows) {
      return const _ShellSpec('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NoExit',
        '-Command',
        '-',
      ]);
    }
    for (final candidate in const ['/bin/bash', '/usr/bin/bash']) {
      if (File(candidate).existsSync()) {
        return _ShellSpec(candidate, const []);
      }
    }
    return const _ShellSpec('/bin/sh', []);
  }

  void _handleExit(Process process, int code) {
    if (!identical(_process, process)) return;
    _process = null;
    final stdout = _stdout;
    final stderr = _stderr;
    _stdout = null;
    _stderr = null;
    final pending = _pending;
    _pending = null;
    _marker = null;
    if (pending != null && !pending.isCompleted) pending.complete(code);
    unawaited(stdout?.cancel());
    unawaited(stderr?.cancel());
    onOutput('[Shell exited with code $code]');
  }

  void _handleLine(String line) {
    final marker = _marker;
    if (marker != null) {
      // The marker can land mid-line when the command's last output had no
      // trailing newline (e.g. Write-Host -NoNewline), so match anywhere rather
      // than only at the start, or the command would hang forever.
      final markerIndex = line.indexOf(marker);
      if (markerIndex >= 0) {
        final prefix = line.substring(0, markerIndex);
        if (prefix.isNotEmpty) onOutput(prefix);
        final code =
            int.tryParse(line.substring(markerIndex + marker.length).trim()) ??
            0;
        final pending = _pending;
        _marker = null;
        _pending = null;
        if (pending != null && !pending.isCompleted) pending.complete(code);
        return;
      }
    }
    if (line.isNotEmpty) onOutput(line);
  }

  Future<void> dispose() async {
    final process = _process;
    _process = null;
    final stdout = _stdout;
    final stderr = _stderr;
    _stdout = null;
    _stderr = null;
    final pending = _pending;
    _pending = null;
    _marker = null;
    if (process != null) {
      process.stdin.writeln('exit');
      await process.stdin.flush();
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        if (Platform.isWindows) {
          await Process.run('taskkill.exe', [
            '/PID',
            '${process.pid}',
            '/T',
            '/F',
          ]);
        } else {
          process.kill(ProcessSignal.sigkill);
        }
      }
    }
    await stdout?.cancel();
    await stderr?.cancel();
    if (pending != null && !pending.isCompleted) pending.complete(-1);
  }
}

class _ShellSpec {
  const _ShellSpec(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}
