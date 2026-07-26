import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/workspace_change.dart';
import 'package:kode_agent_desktop/services/approval_mode.dart';
import 'package:kode_agent_desktop/services/workspace_tools.dart';

void main() {
  test('unified diff dapat menerapkan satu hunk terpilih', () {
    final original =
        '${List.generate(12, (index) => 'line ${index + 1}').join('\n')}\n';
    final proposed = original
        .replaceFirst('line 2', 'line two')
        .replaceFirst('line 11', 'line eleven');
    final hunks = UnifiedDiff.build(original, proposed, 'sample.txt');

    expect(hunks, hasLength(2));
    final partiallyApplied = UnifiedDiff.applyHunks(original, [hunks.first]);
    expect(partiallyApplied, contains('line two'));
    expect(partiallyApplied, contains('line 11'));
    expect(partiallyApplied, isNot(contains('line eleven')));
  });

  test('workspace edit ditahan sampai accept dan dapat direvert', () async {
    final root = await Directory.systemTemp.createTemp('younzcode-review-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}hello.txt');
    await file.writeAsString('before\n');
    WorkspaceTurnChanges? pending;
    final tools = WorkspaceTools(
      root: root.path,
      requestPermission: (_, _) async => PermissionDecision.allowOnce,
      allowWrite: true,
      allowTerminal: false,
      approvalMode: ApprovalMode.fullAccess,
      environment: const {},
      onChangesChanged: (changes) => pending = changes,
      stageEdits: true,
    );

    tools.beginTurn('ubah hello');
    await tools.execute('write_file', {
      'path': 'hello.txt',
      'content': 'after\n',
    });

    expect(await file.readAsString(), 'before\n');
    expect(pending?.files.single.status, 'M');
    await tools.applyChanges();
    expect(await file.readAsString(), 'after\n');
    await tools.revertLastTurn();
    expect(await file.readAsString(), 'before\n');
  });
}
