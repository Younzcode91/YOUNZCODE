import 'dart:io';

import '../models/workspace_change.dart';

typedef WorkspacePathResolver = Future<String> Function(String requestedPath);
typedef WorkspaceEditChanged = void Function(WorkspaceTurnChanges? changes);

class WorkspaceEditConflictException implements Exception {
  const WorkspaceEditConflictException({
    required this.operation,
    required this.filePath,
    required this.reason,
  });

  final String operation;
  final String filePath;
  final String reason;

  @override
  String toString() =>
      'Konflik edit workspace saat $operation untuk "$filePath": $reason';
}

/// Owns the transactional edit lifecycle independently from tool dispatch,
/// permissions, terminal execution, and MCP integration.
class WorkspaceEditSession {
  WorkspaceEditSession({required this.resolve, this.onChanged});

  final WorkspacePathResolver resolve;
  final WorkspaceEditChanged? onChanged;
  final Map<String, _StagedFile> _stagedFiles = {};
  WorkspaceTurnChanges? _lastAppliedTurn;
  String _turnId = '';
  String _turnPrompt = '';

  void beginTurn(String prompt) {
    _turnId = DateTime.now().microsecondsSinceEpoch.toString();
    _turnPrompt = prompt;
    _stagedFiles.clear();
    onChanged?.call(null);
  }

  WorkspaceTurnChanges? get pendingChanges => _buildChanges();
  WorkspaceTurnChanges? get lastAppliedTurn => _lastAppliedTurn;

  Future<String> contentFor(String resolvedPath) async {
    final staged = _stagedFiles[resolvedPath];
    return staged?.proposed ?? File(resolvedPath).readAsString();
  }

  Future<void> stageWrite({
    required String requestedPath,
    required String resolvedPath,
    required String content,
  }) async {
    final file = File(resolvedPath);
    final existing = _stagedFiles[resolvedPath];
    final existed = existing?.originallyExisted ?? await file.exists();
    final original =
        existing?.original ?? (existed ? await file.readAsString() : '');
    _stagedFiles[resolvedPath] = _StagedFile(
      requestedPath: requestedPath,
      original: original,
      proposed: content,
      originallyExisted: existed,
    );
    _notify();
  }

  void stageReplacement({
    required String requestedPath,
    required String resolvedPath,
    required String currentContent,
    required String proposedContent,
  }) {
    final staged = _stagedFiles[resolvedPath];
    _stagedFiles[resolvedPath] = _StagedFile(
      requestedPath: requestedPath,
      original: staged?.original ?? currentContent,
      proposed: proposedContent,
      originallyExisted: staged?.originallyExisted ?? true,
    );
    _notify();
  }

  Future<WorkspaceTurnChanges?> apply({Set<String>? hunkIds}) async {
    final changes = _buildChanges();
    if (changes == null) return null;
    final pending =
        <
          ({
            WorkspaceFileChange change,
            List<DiffHunk> acceptedHunks,
            File file,
            String content,
          })
        >[];
    for (final change in changes.files) {
      final acceptedHunks = hunkIds == null
          ? change.hunks
          : change.hunks.where((hunk) => hunkIds.contains(hunk.id)).toList();
      if (acceptedHunks.isEmpty) continue;
      final staged = _stagedFiles.values.firstWhere(
        (item) => item.requestedPath == change.path,
      );
      final file = File(await resolve(change.path));
      final content = acceptedHunks.length == change.hunks.length
          ? staged.proposed
          : UnifiedDiff.applyHunks(staged.original, acceptedHunks);
      pending.add((
        change: change,
        acceptedHunks: acceptedHunks,
        file: file,
        content: content,
      ));
    }
    if (pending.isEmpty) return null;

    for (final item in pending) {
      await _verifyDiskState(
        item.file,
        expectedExists: item.change.originallyExisted,
        expectedContent: item.change.originalContent,
        operation: 'menerapkan perubahan',
        requestedPath: item.change.path,
      );
    }
    for (final item in pending) {
      if (item.content.isEmpty && item.change.originallyExisted) {
        if (await item.file.exists()) await item.file.delete();
      } else {
        await _writeAtomically(item.file, item.content);
      }
    }
    final applied = WorkspaceTurnChanges(
      id: changes.id,
      prompt: changes.prompt,
      createdAt: changes.createdAt,
      files: pending.map((item) {
        final change = item.change;
        return WorkspaceFileChange(
          path: change.path,
          originalContent: change.originalContent,
          proposedContent: item.content,
          originallyExisted: change.originallyExisted,
          hunks: item.acceptedHunks,
        );
      }).toList(),
      applied: true,
    );
    _lastAppliedTurn = applied;
    _stagedFiles.clear();
    onChanged?.call(null);
    return applied;
  }

  void reject() {
    _stagedFiles.clear();
    onChanged?.call(null);
  }

  Future<void> revertLastTurn() async {
    final turn = _lastAppliedTurn;
    if (turn == null) return;
    final pending = <({WorkspaceFileChange change, File file})>[];
    for (final change in turn.files) {
      pending.add((change: change, file: File(await resolve(change.path))));
    }
    for (final item in pending) {
      final change = item.change;
      await _verifyDiskState(
        item.file,
        expectedExists:
            !change.originallyExisted || change.proposedContent.isNotEmpty,
        expectedContent: change.proposedContent,
        operation: 'mengembalikan perubahan',
        requestedPath: change.path,
      );
    }
    for (final item in pending) {
      final change = item.change;
      if (!change.originallyExisted) {
        if (await item.file.exists()) await item.file.delete();
      } else {
        await _writeAtomically(item.file, change.originalContent);
      }
    }
    _lastAppliedTurn = null;
  }

  WorkspaceTurnChanges? _buildChanges() {
    final files = <WorkspaceFileChange>[];
    for (final staged in _stagedFiles.values) {
      final hunks = UnifiedDiff.build(
        staged.original,
        staged.proposed,
        staged.requestedPath,
      );
      if (hunks.isEmpty) continue;
      files.add(
        WorkspaceFileChange(
          path: staged.requestedPath,
          originalContent: staged.original,
          proposedContent: staged.proposed,
          originallyExisted: staged.originallyExisted,
          hunks: hunks,
        ),
      );
    }
    if (files.isEmpty) return null;
    return WorkspaceTurnChanges(
      id: _turnId,
      prompt: _turnPrompt,
      createdAt: DateTime.now(),
      files: files,
    );
  }

  Future<void> _verifyDiskState(
    File file, {
    required bool expectedExists,
    required String expectedContent,
    required String operation,
    required String requestedPath,
  }) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (!expectedExists) {
      if (type != FileSystemEntityType.notFound) {
        throw WorkspaceEditConflictException(
          operation: operation,
          filePath: requestedPath,
          reason: 'file seharusnya belum ada, tetapi sudah dibuat di disk.',
        );
      }
      return;
    }
    if (!await file.exists()) {
      throw WorkspaceEditConflictException(
        operation: operation,
        filePath: requestedPath,
        reason: 'file yang diharapkan sudah tidak ada di disk.',
      );
    }
    try {
      if (await file.readAsString() != expectedContent) {
        throw WorkspaceEditConflictException(
          operation: operation,
          filePath: requestedPath,
          reason: 'isi file telah berubah di disk.',
        );
      }
    } on FileSystemException {
      throw WorkspaceEditConflictException(
        operation: operation,
        filePath: requestedPath,
        reason: 'file berubah atau tidak dapat dibaca saat diperiksa.',
      );
    }
  }

  Future<void> _writeAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.kode-agent-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _notify() => onChanged?.call(_buildChanges());
}

class _StagedFile {
  const _StagedFile({
    required this.requestedPath,
    required this.original,
    required this.proposed,
    required this.originallyExisted,
  });

  final String requestedPath;
  final String original;
  final String proposed;
  final bool originallyExisted;
}
