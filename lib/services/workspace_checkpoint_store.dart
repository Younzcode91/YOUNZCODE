import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/workspace_change.dart';

class WorkspaceCheckpointConflict implements Exception {
  const WorkspaceCheckpointConflict(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Persists accepted agent turns outside the workspace, so review checkpoints
/// survive application restarts without adding bookkeeping files to projects.
class WorkspaceCheckpointStore {
  WorkspaceCheckpointStore({String? storageRoot})
    : _storageRoot = storageRoot ?? _defaultStorageRoot();

  final String _storageRoot;

  Future<List<WorkspaceTurnChanges>> load(String workspace) async {
    if (workspace.isEmpty) return const [];
    final file = File(_filePath(workspace));
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      final turns =
          decoded
              .whereType<Map>()
              .map(
                (item) => WorkspaceTurnChanges.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((turn) => turn.applied)
              .toList()
            ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
      return turns;
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }

  Future<void> save(String workspace, WorkspaceTurnChanges turn) async {
    if (workspace.isEmpty || !turn.applied) return;
    final existing = await load(workspace);
    final turns = [
      turn,
      ...existing.where((item) => item.id != turn.id),
    ].take(25).toList();
    await _write(workspace, turns);
  }

  Future<void> remove(String workspace, String turnId) async {
    final turns = await load(workspace);
    await _write(workspace, turns.where((turn) => turn.id != turnId).toList());
  }

  /// Restores a checkpoint only if every affected file still matches the
  /// content produced by that turn. This prevents an old checkpoint from
  /// silently overwriting edits made afterwards.
  Future<void> restore(String workspace, WorkspaceTurnChanges turn) async {
    final root = path.normalize(path.absolute(workspace));
    final pending = <({WorkspaceFileChange change, File file})>[];
    for (final change in turn.files) {
      final resolved = path.normalize(
        path.absolute(path.join(root, change.path)),
      );
      if (!path.isWithin(root, resolved)) {
        throw WorkspaceCheckpointConflict(
          'Checkpoint berisi path di luar workspace: ${change.path}',
        );
      }
      final file = File(resolved);
      final exists = await file.exists();
      final expectedExists =
          !change.originallyExisted || change.proposedContent.isNotEmpty;
      if (exists != expectedExists) {
        throw WorkspaceCheckpointConflict(
          '${change.path} sudah berubah sejak checkpoint dibuat.',
        );
      }
      if (exists && await file.readAsString() != change.proposedContent) {
        throw WorkspaceCheckpointConflict(
          '${change.path} sudah berubah sejak checkpoint dibuat.',
        );
      }
      pending.add((change: change, file: file));
    }
    for (final item in pending) {
      if (!item.change.originallyExisted) {
        if (await item.file.exists()) await item.file.delete();
      } else {
        await _writeFileAtomically(item.file, item.change.originalContent);
      }
    }
    await remove(workspace, turn.id);
  }

  Future<void> _write(
    String workspace,
    List<WorkspaceTurnChanges> turns,
  ) async {
    final file = File(_filePath(workspace));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
    try {
      await temporary.writeAsString(
        jsonEncode(turns.map((turn) => turn.toJson()).toList()),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _writeFileAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.checkpoint-$pid.tmp');
    try {
      await temporary.writeAsString(content, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  String _filePath(String workspace) =>
      path.join(_storageRoot, '${_stableHash(path.normalize(workspace))}.json');

  static String _defaultStorageRoot() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      return path.join(local, 'YOUNZCODE', 'checkpoints');
    }
    return path.join(Directory.systemTemp.path, 'YOUNZCODE', 'checkpoints');
  }

  static String _stableHash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value.toLowerCase())) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
