import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// Burns CPU across [workers] isolate workers until told to stop.
///
/// Used by `tool/run_dap_load_test.sh` to simulate a busy machine while the
/// DAP test suite runs, so debugpy / js-debug cold starts are exercised under
/// contention — the exact condition that produced the historical
/// "Debug adapter stopped" flake.
///
/// Shutdown is cooperative to stay portable across Git Bash / MSYS where
/// `kill` on a process may not reach the real VM: the main isolate polls a
/// sentinel file (created by the caller) and force-kills its workers when it
/// appears, then exits. SIGINT/SIGTERM is also handled on POSIX.
///
/// Usage:
///   dart run tool/cpu_stress.dart [workers] [--sentinel <path>] [--duration <seconds>]
void main(List<String> arguments) {
  var requested = int.tryParse(arguments.isEmpty ? '' : arguments.first);
  String? sentinel;
  var durationSeconds = 0;

  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--sentinel' && index + 1 < arguments.length) {
      sentinel = arguments[++index];
    } else if (argument == '--duration' && index + 1 < arguments.length) {
      durationSeconds = int.tryParse(arguments[++index]) ?? 0;
    } else {
      requested ??= int.tryParse(argument);
    }
  }

  final cores = Platform.numberOfProcessors;
  final count = (requested ?? cores - 1).clamp(1, 64);
  final workers = <Isolate>[];
  for (var i = 0; i < count; i++) {
    Isolate.spawn(_burn, i).then(workers.add);
  }

  final deadline = durationSeconds > 0
      ? DateTime.now().add(Duration(seconds: durationSeconds))
      : null;
  stdout.writeln(
    'CPU stress: $count worker isolate(s) burning on $cores core(s).',
  );
  stdout.writeln(
    sentinel != null
        ? 'Stop when sentinel "$sentinel" appears.'
        : 'Stop via Ctrl+C or after ${deadline != null ? durationSeconds : 'unlimited'}s.',
  );

  ProcessSignal.sigint.watch().listen((_) => exit(0));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => exit(0));
  }

  Timer.periodic(const Duration(milliseconds: 500), (_) {
    final stop =
        (sentinel != null && File(sentinel).existsSync()) ||
        (deadline != null && !DateTime.now().isBefore(deadline));
    if (!stop) return;
    for (final worker in workers) {
      worker.kill(priority: Isolate.immediate);
    }
    exit(0);
  });

  // Keep the main isolate's event loop alive; workers are killed by the
  // periodic timer above or by the process being terminated.
  unawaited(Completer<void>().future);
}

void _burn(int seed) {
  // 32-bit LCG: no allocations, no I/O, just arithmetic so the core stays hot.
  var value = seed * 2654435761;
  while (true) {
    value = value * 1103515245 + 12345;
    if (value == 0x7fffffff) value = 1;
  }
}
