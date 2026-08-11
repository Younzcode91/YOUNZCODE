import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/addon.dart';
import 'package:kode_agent_desktop/services/mcp_client.dart';
import 'package:kode_agent_desktop/services/workspace_tools.dart';
import 'package:kode_agent_desktop/services/approval_mode.dart';

void main() {
  test('tool baca file sensitif meminta approval', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}.env',
    ).writeAsString('SECRET=x');
    var permissionAsked = false;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async {
        permissionAsked = true;
        return PermissionDecision.allowOnce;
      },
      allowWrite: true,
      allowTerminal: false,
      environment: const {},
    );

    expect(await tools.execute('read_file', {'path': '.env'}), 'SECRET=x');
    expect(permissionAsked, isTrue);
  });

  test('approve for me menyetujui edit workspace tanpa prompt', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    addTearDown(() => root.delete(recursive: true));
    var permissionAsked = false;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async {
        permissionAsked = true;
        return PermissionDecision.reject;
      },
      allowWrite: true,
      allowTerminal: false,
      approvalMode: ApprovalMode.approveForMe,
      environment: const {},
    );

    await tools.execute('write_file', {'path': 'new.txt', 'content': 'ok'});
    expect(
      await File('${root.path}${Platform.pathSeparator}new.txt').readAsString(),
      'ok',
    );
    expect(permissionAsked, isFalse);
  });

  test('full access dapat membaca file di luar workspace', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    final external = await Directory.systemTemp.createTemp(
      'younzcode-external-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => external.delete(recursive: true));
    final file = File('${external.path}${Platform.pathSeparator}outside.txt');
    await file.writeAsString('external');
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async => PermissionDecision.reject,
      allowWrite: true,
      allowTerminal: true,
      approvalMode: ApprovalMode.fullAccess,
      environment: const {},
    );

    expect(await tools.execute('read_file', {'path': file.path}), 'external');
  });

  test(
    'allowExternalPaths false menolak akses luar walau persetujuan otomatis',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      final external = await Directory.systemTemp.createTemp(
        'younzcode-external-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => external.delete(recursive: true));
      final file = File('${external.path}${Platform.pathSeparator}outside.txt');
      await file.writeAsString('external');
      // Mimic the multi-agent worker callback: everything non-sensitif is
      // auto-approved, so any allowed-by-default behavior would let the agent
      // escape its worktree.
      var permissionAsked = false;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          permissionAsked = true;
          return PermissionDecision.allowOnce;
        },
        allowWrite: true,
        allowTerminal: false,
        approvalMode: ApprovalMode.approveForMe,
        environment: const {},
        allowExternalPaths: false,
      );

      await expectLater(
        tools.execute('read_file', {'path': file.path}),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        tools.execute('write_file', {'path': file.path, 'content': 'pwned'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'external');
      expect(permissionAsked, isFalse);

      // Autonomy inside the worktree is unaffected.
      await tools.execute('write_file', {'path': 'new.txt', 'content': 'ok'});
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}new.txt',
        ).readAsString(),
        'ok',
      );
    },
  );

  test('allow always mengingat pola edit selama agent hidup', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    addTearDown(() => root.delete(recursive: true));
    var approvalCount = 0;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async {
        approvalCount++;
        return PermissionDecision.allowAlways;
      },
      allowWrite: true,
      allowTerminal: false,
      environment: const {},
    );

    await tools.execute('write_file', {'path': 'one.txt', 'content': '1'});
    await tools.execute('write_file', {'path': 'two.txt', 'content': '2'});
    expect(approvalCount, 1);
  });

  group('staged edit conflict protection', () {
    test('apply preserves an existing file modified after staging', () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}file.txt');
      await file.writeAsString('baseline');
      final tools = _stagedTools(root);

      await tools.execute('write_file', {
        'path': 'file.txt',
        'content': 'staged',
      });
      await file.writeAsString('user edit');

      await expectLater(
        tools.applyChanges(),
        throwsA(
          isA<WorkspaceEditConflictException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('file.txt'), contains('telah berubah')),
          ),
        ),
      );
      expect(await file.readAsString(), 'user edit');
      expect(tools.pendingChanges, isNotNull);
    });

    test('apply preserves an existing file deleted after staging', () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}file.txt');
      await file.writeAsString('baseline');
      final tools = _stagedTools(root);

      await tools.execute('write_file', {
        'path': 'file.txt',
        'content': 'staged',
      });
      await file.delete();

      await expectLater(
        tools.applyChanges(),
        throwsA(isA<WorkspaceEditConflictException>()),
      );
      expect(await file.exists(), isFalse);
    });

    test(
      'apply preserves a new file independently created after staging',
      () async {
        final root = await Directory.systemTemp.createTemp('younzcode-tools-');
        addTearDown(() => root.delete(recursive: true));
        final file = File('${root.path}${Platform.pathSeparator}new.txt');
        final tools = _stagedTools(root);

        await tools.execute('write_file', {
          'path': 'new.txt',
          'content': 'staged',
        });
        await file.writeAsString('user file');

        await expectLater(
          tools.applyChanges(),
          throwsA(
            isA<WorkspaceEditConflictException>().having(
              (error) => error.toString(),
              'message',
              contains('sudah dibuat'),
            ),
          ),
        );
        expect(await file.readAsString(), 'user file');
      },
    );

    test('revert preserves a file modified after apply', () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}file.txt');
      await file.writeAsString('baseline');
      final tools = _stagedTools(root);

      await tools.execute('write_file', {
        'path': 'file.txt',
        'content': 'applied',
      });
      await tools.applyChanges();
      await file.writeAsString('user edit');

      await expectLater(
        tools.revertLastTurn(),
        throwsA(isA<WorkspaceEditConflictException>()),
      );
      expect(await file.readAsString(), 'user edit');
      expect(tools.lastAppliedTurn, isNotNull);
    });

    test('partial hunk apply records exact content for revert', () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}file.txt');
      final original =
          '${List.generate(12, (index) => 'line ${index + 1}').join('\n')}\n';
      final proposed = original
          .replaceFirst('line 1\n', 'changed 1\n')
          .replaceFirst('line 12\n', 'changed 12\n');
      await file.writeAsString(original);
      final tools = _stagedTools(root);

      await tools.execute('write_file', {
        'path': 'file.txt',
        'content': proposed,
      });
      final changes = tools.pendingChanges!;
      expect(changes.files.single.hunks, hasLength(2));
      final firstHunk = changes.files.single.hunks.first;

      final applied = await tools.applyChanges(hunkIds: {firstHunk.id});
      expect(await file.readAsString(), applied!.files.single.proposedContent);
      expect(await file.readAsString(), contains('changed 1'));
      expect(await file.readAsString(), contains('line 12'));

      await tools.revertLastTurn();
      expect(await file.readAsString(), original);
    });
  });

  test(
    'MCP launch meminta approval exact command dan mempertahankan built-ins',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final marker = File('${root.path}${Platform.pathSeparator}started.txt');
      final server = File('${root.path}${Platform.pathSeparator}server.dart');
      await server.writeAsString(
        "import 'dart:io'; void main(List<String> args) { File(args.single).writeAsStringSync('started'); }",
      );
      late String approvalDetail;
      final client = McpClient(
        McpServerConfig(
          name: 'denied-server',
          transport: McpTransport.stdio,
          command: 'dart',
          arguments: ['run', server.path, marker.path],
        ),
        workspace: root.path,
      );
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, detail) async {
          approvalDetail = detail;
          return PermissionDecision.reject;
        },
        allowWrite: false,
        allowTerminal: false,
        approvalMode: ApprovalMode.fullAccess,
        environment: const {},
        mcpClients: [client],
      );
      addTearDown(tools.dispose);

      final definitions = await tools.initializeAndDefinitions();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(marker.existsSync(), isFalse);
      expect(approvalDetail, contains('Command: dart'));
      expect(
        approvalDetail,
        contains(jsonEncode(['dart', 'run', server.path, marker.path])),
      );
      final names = definitions
          .map(
            (definition) =>
                (definition['function']! as Map<String, Object>)['name'],
          )
          .toSet();
      expect(names, containsAll(['list_files', 'read_file', 'search_text']));
      expect(names.where((name) => '$name'.startsWith('mcp_')), isEmpty);
    },
  );

  test('baca varian .env.* tetap meminta approval', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}.env.production',
    ).writeAsString('DB_PASSWORD=Sup3rSecretValue');
    var permissionAsked = false;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async {
        permissionAsked = true;
        return PermissionDecision.reject;
      },
      allowWrite: false,
      allowTerminal: false,
      environment: const {},
    );

    expect(
      await tools.execute('read_file', {'path': '.env.production'}),
      'Ditolak oleh pengguna.',
    );
    expect(permissionAsked, isTrue);
  });

  test('tulis file sensitif meminta approval walau approveForMe', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-tools-');
    addTearDown(() => root.delete(recursive: true));
    var permissionAsked = false;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async {
        permissionAsked = true;
        return PermissionDecision.reject;
      },
      allowWrite: true,
      allowTerminal: false,
      approvalMode: ApprovalMode.approveForMe,
      environment: const {},
    );

    expect(
      await tools.execute('write_file', {'path': '.env', 'content': 'X=1'}),
      'Ditolak oleh pengguna.',
    );
    expect(permissionAsked, isTrue);
    expect(
      File('${root.path}${Platform.pathSeparator}.env').existsSync(),
      isFalse,
    );
  });

  test(
    'perintah alias PowerShell dianggap tidak aman di approveForMe',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      var permissionAsked = false;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          permissionAsked = true;
          return PermissionDecision.reject;
        },
        allowWrite: false,
        allowTerminal: true,
        approvalMode: ApprovalMode.approveForMe,
        environment: const {},
      );

      // irm/iex are engine aliases the old heuristic missed; approveForMe must
      // still prompt (and here be rejected) instead of auto-running them.
      expect(
        await tools.execute('run_command', {
          'command': 'irm http://127.0.0.1/x | iex',
        }),
        'Ditolak oleh pengguna.',
      );
      expect(permissionAsked, isTrue);
    },
  );

  test(
    'allow always tidak menutup perintah lain yang disambung dengan ;',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      var approvalCount = 0;
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async {
          approvalCount++;
          return PermissionDecision.allowAlways;
        },
        allowWrite: false,
        allowTerminal: true,
        environment: const {},
      );

      await tools.execute('run_command', {'command': 'Write-Output hi'});
      // Same base command reuses the remembered pattern: no new prompt.
      await tools.execute('run_command', {'command': 'Write-Output hi'});
      expect(approvalCount, 1);

      // A chained command must NOT ride on the allow-always of its prefix.
      await tools.execute('run_command', {
        'command': 'Write-Output hi; Write-Output pwned',
      });
      expect(approvalCount, 2);
    },
    skip: !Platform.isWindows,
  );

  test(
    'run_command menghentikan process tree ketika timeout',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async => PermissionDecision.allowOnce,
        allowWrite: false,
        allowTerminal: true,
        approvalMode: ApprovalMode.fullAccess,
        environment: const {},
        commandTimeoutMs: 150,
      );
      addTearDown(tools.dispose);

      await expectLater(
        tools.execute('run_command', {'command': 'Start-Sleep -Seconds 30'}),
        throwsA(isA<TimeoutException>()),
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'cancelActive menghentikan perintah yang sedang berjalan',
    () async {
      final root = await Directory.systemTemp.createTemp('younzcode-tools-');
      addTearDown(() => root.delete(recursive: true));
      final tools = WorkspaceTools(
        root: root.path,
        requestPermission: (_, _) async => PermissionDecision.allowOnce,
        allowWrite: false,
        allowTerminal: true,
        approvalMode: ApprovalMode.fullAccess,
        environment: const {},
        commandTimeoutMs: 30000,
      );
      addTearDown(tools.dispose);

      final pending = tools.execute('run_command', {
        'command': 'Start-Sleep -Seconds 30',
      });
      final cancelled = expectLater(
        pending,
        throwsA(isA<WorkspaceCommandCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tools.cancelActive();

      await cancelled;
    },
    skip: !Platform.isWindows,
  );
}

WorkspaceTools _stagedTools(Directory root) {
  final tools = WorkspaceTools(
    root: root.path,
    requestPermission: (_, _) async => PermissionDecision.allowOnce,
    allowWrite: true,
    allowTerminal: false,
    environment: const {},
    stageEdits: true,
  );
  tools.beginTurn('test');
  return tools;
}
