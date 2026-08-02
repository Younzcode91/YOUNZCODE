import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/workspace_change.dart';
import 'package:kode_agent_desktop/services/workspace_checkpoint_store.dart';

void main() {
  test(
    'checkpoint persisten dapat dimuat dan dipulihkan dengan aman',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'younz-checkpoint-root-',
      );
      final storage = await Directory.systemTemp.createTemp(
        'younz-checkpoint-storage-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => storage.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}sample.txt');
      await file.writeAsString('after\n');
      final hunks = UnifiedDiff.build('before\n', 'after\n', 'sample.txt');
      final turn = WorkspaceTurnChanges(
        id: 'turn-1',
        prompt: 'ubah sample',
        createdAt: DateTime(2026, 7, 27),
        applied: true,
        files: [
          WorkspaceFileChange(
            path: 'sample.txt',
            originalContent: 'before\n',
            proposedContent: 'after\n',
            originallyExisted: true,
            hunks: hunks,
          ),
        ],
      );
      final store = WorkspaceCheckpointStore(storageRoot: storage.path);

      await store.save(root.path, turn);
      expect((await store.load(root.path)).single.prompt, 'ubah sample');

      await store.restore(root.path, turn);
      expect(await file.readAsString(), 'before\n');
      expect(await store.load(root.path), isEmpty);
    },
  );

  test('checkpoint menolak menimpa file yang berubah setelah turn', () async {
    final root = await Directory.systemTemp.createTemp(
      'younz-checkpoint-root-',
    );
    final storage = await Directory.systemTemp.createTemp(
      'younz-checkpoint-storage-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => storage.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}sample.txt');
    await file.writeAsString('edited later\n');
    final turn = WorkspaceTurnChanges(
      id: 'turn-2',
      prompt: 'ubah sample',
      createdAt: DateTime(2026, 7, 27),
      applied: true,
      files: [
        WorkspaceFileChange(
          path: 'sample.txt',
          originalContent: 'before\n',
          proposedContent: 'after\n',
          originallyExisted: true,
          hunks: UnifiedDiff.build('before\n', 'after\n', 'sample.txt'),
        ),
      ],
    );
    final store = WorkspaceCheckpointStore(storageRoot: storage.path);

    await expectLater(
      store.restore(root.path, turn),
      throwsA(isA<WorkspaceCheckpointConflict>()),
    );
    expect(await file.readAsString(), 'edited later\n');
  });
}
