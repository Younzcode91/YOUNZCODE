import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/debug_adapter_service.dart';

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
  print('Debug server listening at:1');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
    final adapter = DebugAdapterService();
    addTearDown(adapter.dispose);

    await expectLater(
      adapter.start(
        launch: DebugAdapterLaunch(
          executable: Platform.resolvedExecutable,
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

  test('DAP Dart berhenti tepat pada breakpoint', () async {
    final workspace = await Directory.systemTemp.createTemp('younzcode-dap-');
    addTearDown(() => workspace.delete(recursive: true));
    final source = File('${workspace.path}${Platform.pathSeparator}main.dart');
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
    final event = await stopped.timeout(const Duration(seconds: 20));
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
  });

  test('DAP Python berhenti tepat pada breakpoint', () async {
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
    final stopped = adapter.events.firstWhere(
      (event) => event.name == 'stopped',
    );

    await adapter.start(
      launch: launch,
      workspace: workspace.path,
      sourcePath: source.path,
      breakpoints: {2},
    );
    await stopped.timeout(const Duration(seconds: 20));
    final stack = await adapter.request('stackTrace', {
      'threadId': adapter.threadId,
      'startFrame': 0,
      'levels': 1,
    });
    expect(((stack['stackFrames'] as List).first as Map)['line'], 2);
  });

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
