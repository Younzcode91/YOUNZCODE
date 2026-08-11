import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/debug_adapter_service.dart';

/// Prints a greppable handshake-timing line for the load-test harness
/// (tool/run_dap_load_test.sh), which reports cold-start margins per adapter.
void _printHandshake(DebugAdapterService adapter) {
  final timing = adapter.handshakeTiming;
  if (timing == null) return;
  // ignore: avoid_print
  print(
    'HANDSHAKE ${timing['adapterId']} '
    'initializedMs=${timing['initializedMs']} '
    'launchMs=${timing['launchMs']} '
    'totalMs=${timing['totalMs']} '
    'timeoutMs=${timing['timeoutMs']}',
  );
}

void main() {
  test('memilih debug adapter sesuai bahasa', () {
    final dart = DebugAdapterLaunch.forFile(
      'C:\\project\\main.dart',
      'C:\\project',
    );
    expect(dart?.executable, 'dart');
    expect(dart?.arguments, ['debug_adapter']);
    expect(dart?.launchArguments['program'], 'C:\\project\\main.dart');

    final python = DebugAdapterLaunch.forFile(
      'C:\\project\\app.py',
      'C:\\project',
    );
    expect(python?.executable, 'python');
    expect(python?.arguments, ['-m', 'debugpy.adapter']);

    final javascript = DebugAdapterLaunch.forFile('app.js', 'C:\\project');
    expect(javascript?.executable, anyOf('node', endsWith('node.exe')));
    expect(javascript?.socketServer, isTrue);
    expect(
      javascript?.launchArguments['runtimeExecutable'],
      javascript?.executable,
    );
    expect(javascript?.launchArguments['__workspaceFolder'], 'C:\\project');
  });

  test('startup failure cleans a partially started adapter', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'younzcode-dap-start-failure-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final script = File(
      '${workspace.path}${Platform.pathSeparator}adapter.dart',
    );
    await script.writeAsString('''
import 'dart:async';

Future<void> main() async {
  // Short delay mirrors real adapters, which never print the listening line
  // before the Dart side has attached its stdout listener.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('Debug server listening at:1');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
    final adapter = DebugAdapterService();
    addTearDown(adapter.dispose);

    await expectLater(
      adapter.start(
        launch: DebugAdapterLaunch(
          // `dart` from PATH: under `flutter test`, Platform.resolvedExecutable
          // is flutter_tester, which cannot run a plain Dart script.
          executable: 'dart',
          arguments: ['run', script.path],
          launchArguments: const {'type': 'test'},
          socketServer: true,
        ),
        workspace: workspace.path,
        sourcePath: script.path,
        breakpoints: const {},
      ),
      throwsA(isA<Exception>()),
    );
    expect(adapter.running, isFalse);
    expect(() => adapter.request('threads'), throwsA(isA<StateError>()));
  });

  test('adapter path with & and spaces launches without a shell', () async {
    final base = await Directory.systemTemp.createTemp('younzcode-dap-& spec-');
    addTearDown(() => base.delete(recursive: true));
    final scriptDir = Directory(
      '${base.path}${Platform.pathSeparator}adapter & dir',
    );
    await scriptDir.create();
    final script = File(
      '${scriptDir.path}${Platform.pathSeparator}fake & adapter.dart',
    );
    // Note: \$script is escaped — ''' strings interpolate in the TEST, and
    // this literal must reach the generated child source, where the child's
    // own runtime interpolates it with its script path.
    await script.writeAsString('''
import 'dart:io';

Future<void> main() async {
  // Prove the script path arrived literally: write it to a sibling marker.
  final script = Platform.script.toFilePath();
  File('\$script.marker').writeAsStringSync(script);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('Debug server listening at:1');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
    final adapter = DebugAdapterService();
    addTearDown(adapter.dispose);

    // SocketException (connect-refused on port 1) proves the adapter ran and
    // reached the listening line. Under the old runInShell: true on Windows,
    // cmd would split on `&` and the launch would fail as a ProcessException
    // or the listening line would never arrive (TimeoutException).
    await expectLater(
      adapter.start(
        launch: DebugAdapterLaunch(
          executable: 'dart',
          arguments: ['run', script.path],
          launchArguments: const {'type': 'test'},
          socketServer: true,
        ),
        workspace: base.path,
        sourcePath: script.path,
        breakpoints: const {},
      ),
      throwsA(isA<SocketException>()),
    );

    // The child really ran the literal path: marker contains the exact script
    // path including the & and the spaces.
    final marker = File('${script.path}.marker');
    expect(await marker.readAsString(), script.path);
    expect(adapter.running, isFalse);
  });

  test(
    'watchdog surfaces stderr and pending requests when the adapter dies',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'younzcode-dap-watchdog-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final script = File(
        '${workspace.path}${Platform.pathSeparator}adapter.dart',
      );
      await script.writeAsString('''
import 'dart:io';

Future<void> main() async {
  // Let the initialize request reach the service's pending map, then
  // write a stderr diagnostic and die mid-handshake.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  stderr.writeln('FATAL: debugpy adapter failed to initialize');
  exit(5);
}
''');
      final adapter = DebugAdapterService();
      addTearDown(adapter.dispose);
      final diagnostics = <DebugAdapterEvent>[];
      final diagnosticsSubscription = adapter.events.listen(diagnostics.add);
      addTearDown(diagnosticsSubscription.cancel);
      final diagnosticsEvent = adapter.events.firstWhere(
        (event) => event.name == 'diagnostics',
      );

      await expectLater(
        adapter.start(
          launch: DebugAdapterLaunch(
            executable: 'dart',
            arguments: ['run', script.path],
            launchArguments: const {'type': 'test'},
          ),
          workspace: workspace.path,
          sourcePath: script.path,
          breakpoints: const {},
        ),
        throwsA(isA<StateError>()),
      );

      final event = await diagnosticsEvent.timeout(const Duration(seconds: 10));
      final body = event.body;
      expect(body['reason'], contains('exited (code 5)'));
      expect(body['exitCode'], 5);
      expect(
        (body['stderr'] as List).cast<String>().join('\n'),
        contains('FATAL: debugpy adapter failed to initialize'),
      );
      final commands = (body['pending'] as List)
          .cast<Map>()
          .map((item) => item['command'])
          .toSet();
      expect(commands, contains('initialize'));
      expect(adapter.running, isFalse);
    },
  );

  test(
    'DAP Dart berhenti tepat pada breakpoint',
    () async {
      final workspace = await Directory.systemTemp.createTemp('younzcode-dap-');
      addTearDown(() => workspace.delete(recursive: true));
      final source = File(
        '${workspace.path}${Platform.pathSeparator}main.dart',
      );
      await source.writeAsString('''
void main() {
  final value = 21;
  print(value * 2);
}
''');
      final launch = DebugAdapterLaunch.forFile(source.path, workspace.path)!;
      final adapter = DebugAdapterService();
      addTearDown(adapter.dispose);
      final diagnostics = <DebugAdapterEvent>[];
      final diagnosticsSubscription = adapter.events.listen(diagnostics.add);
      addTearDown(diagnosticsSubscription.cancel);
      final stopped = adapter.events.firstWhere(
        (event) => event.name == 'stopped',
      );

      await adapter.start(
        launch: launch,
        workspace: workspace.path,
        sourcePath: source.path,
        breakpoints: {3},
      );
      _printHandshake(adapter);
      final event = await stopped.timeout(const Duration(seconds: 30));
      expect(event.body['reason'], anyOf('breakpoint', 'pause'));

      late Map<String, dynamic> stack;
      try {
        stack = await adapter.request('stackTrace', {
          'threadId': adapter.threadId,
          'startFrame': 0,
          'levels': 1,
        });
      } catch (error) {
        fail(
          '$error. Events: '
          '${diagnostics.map((event) => '${event.name}: ${event.body}').join(' | ')}',
        );
      }
      final frames = stack['stackFrames'] as List;
      expect((frames.first as Map)['line'], 3);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'DAP Python berhenti tepat pada breakpoint',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'younzcode-py-dap-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final source = File('${workspace.path}${Platform.pathSeparator}main.py');
      await source.writeAsString('''value = 21
result = value * 2
print(result)
''');
      final launch = DebugAdapterLaunch.forFile(source.path, workspace.path)!;
      final adapter = DebugAdapterService();
      addTearDown(adapter.dispose);
      final diagnostics = <DebugAdapterEvent>[];
      final diagnosticsSubscription = adapter.events.listen(diagnostics.add);
      addTearDown(diagnosticsSubscription.cancel);
      final stopped = adapter.events.firstWhere(
        (event) => event.name == 'stopped',
      );

      await adapter.start(
        launch: launch,
        workspace: workspace.path,
        sourcePath: source.path,
        breakpoints: {2},
      );
      _printHandshake(adapter);
      try {
        await stopped.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        fail(
          'Python DAP did not stop. Events: '
          '${diagnostics.map((event) => '${event.name}: ${event.body}').join(' | ')}',
        );
      }
      final stack = await adapter.request('stackTrace', {
        'threadId': adapter.threadId,
        'startFrame': 0,
        'levels': 1,
      });
      expect(((stack['stackFrames'] as List).first as Map)['line'], 2);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'DAP Node.js berhenti tepat pada breakpoint',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'younzcode-js-dap-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final source = File('${workspace.path}${Platform.pathSeparator}main.js');
      await source.writeAsString('''const value = 21;
const result = value * 2;
console.log(result);
''');
      final launch = DebugAdapterLaunch.forFile(source.path, workspace.path)!;
      final adapter = DebugAdapterService();
      addTearDown(adapter.dispose);
      final diagnostics = <DebugAdapterEvent>[];
      final diagnosticsSubscription = adapter.events.listen(diagnostics.add);
      addTearDown(diagnosticsSubscription.cancel);
      final stopped = adapter.events.firstWhere(
        (event) => event.name == 'stopped',
      );

      await adapter.start(
        launch: launch,
        workspace: workspace.path,
        sourcePath: source.path,
        breakpoints: {2},
      );
      _printHandshake(adapter);
      try {
        await stopped.timeout(const Duration(seconds: 45));
      } on TimeoutException {
        fail(
          'Node DAP did not stop. Events: '
          '${diagnostics.map((event) => '${event.name}: ${event.body}').join(' | ')}',
        );
      }
      final stack = await adapter.request('stackTrace', {
        'threadId': adapter.threadId,
        'startFrame': 0,
        'levels': 1,
      });
      expect(((stack['stackFrames'] as List).first as Map)['line'], 2);
    },
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
