import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/persistent_terminal_service.dart';

void main() {
  test('file teks workspace dapat dibaca, diedit, dan disimpan', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-editor-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final file = File('${workspace.path}${Platform.pathSeparator}sample.dart');
    await file.writeAsString('void main() {}');

    final bytes = await file.readAsBytes();
    expect(bytes.contains(0), isFalse);
    expect(utf8.decode(bytes), 'void main() {}');

    await file.writeAsString('void main() { print("ok"); }');
    expect(await file.readAsString(), 'void main() { print("ok"); }');
  });

  test('PowerShell berjalan dengan working directory workspace', () async {
    if (!Platform.isWindows) return;
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-terminal-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-Location).Path',
    ], workingDirectory: workspace.path);

    expect(result.exitCode, 0);
    expect(
      '${result.stdout}'.trim().toLowerCase(),
      workspace.path.toLowerCase(),
    );
  });

  test('terminal reports PowerShell and native command failures', () async {
    if (!Platform.isWindows) return;
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-terminal-status-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final terminal = PersistentTerminalService(onOutput: (_) {});
    addTearDown(terminal.dispose);
    await terminal.start(workspace: workspace.path, environment: const {});

    expect(await terminal.execute("Write-Error 'failed'"), 1);
    expect(await terminal.execute('cmd.exe /c exit 7'), 7);
    expect(await terminal.execute('Get-Item . | Out-Null'), 0);
    expect(
      await terminal.execute('cmd.exe /c exit 7; Get-Item . | Out-Null'),
      0,
    );
    expect(await terminal.execute('1 / 0'), 1);
  });

  test('perintah dengan output tanpa newline tetap selesai', () async {
    if (!Platform.isWindows) return;
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-terminal-nonl-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final output = <String>[];
    final terminal = PersistentTerminalService(onOutput: output.add);
    addTearDown(terminal.dispose);
    await terminal.start(workspace: workspace.path, environment: const {});

    // stdout without a trailing newline used to swallow the completion marker
    // and hang the terminal forever; .timeout guards the regression.
    final code = await terminal
        .execute("[Console]::Out.Write('partial')")
        .timeout(const Duration(seconds: 10));
    expect(code, 0);
    expect(output.join(), contains('partial'));
  });

  test('terminal can restart after an unexpected process exit', () async {
    if (!Platform.isWindows) return;
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-terminal-restart-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final output = <String>[];
    final terminal = PersistentTerminalService(onOutput: output.add);
    addTearDown(terminal.dispose);
    await terminal.start(workspace: workspace.path, environment: const {});

    expect(await terminal.execute('exit 23'), 23);
    expect(terminal.running, isFalse);

    await terminal.start(workspace: workspace.path, environment: const {});
    expect(await terminal.execute("Write-Output 'restarted'"), 0);
    expect(output, contains('restarted'));
  });
}
