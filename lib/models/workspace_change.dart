enum WorkspaceChangeKind { modified, added, deleted }

class DiffHunk {
  const DiffHunk({
    required this.id,
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final String id;
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;

  String get unified =>
      ['@@ -$oldStart,$oldCount +$newStart,$newCount @@', ...lines].join('\n');
}

class WorkspaceFileChange {
  const WorkspaceFileChange({
    required this.path,
    required this.originalContent,
    required this.proposedContent,
    required this.originallyExisted,
    required this.hunks,
  });

  final String path;
  final String originalContent;
  final String proposedContent;
  final bool originallyExisted;
  final List<DiffHunk> hunks;

  WorkspaceChangeKind get kind => !originallyExisted
      ? WorkspaceChangeKind.added
      : proposedContent.isEmpty
      ? WorkspaceChangeKind.deleted
      : WorkspaceChangeKind.modified;

  String get status => switch (kind) {
    WorkspaceChangeKind.modified => 'M',
    WorkspaceChangeKind.added => 'A',
    WorkspaceChangeKind.deleted => 'D',
  };

  String get unifiedDiff => [
    '--- ${originallyExisted ? 'a/$path' : '/dev/null'}',
    '+++ ${proposedContent.isEmpty ? '/dev/null' : 'b/$path'}',
    ...hunks.map((hunk) => hunk.unified),
  ].join('\n');
}

class WorkspaceTurnChanges {
  const WorkspaceTurnChanges({
    required this.id,
    required this.prompt,
    required this.createdAt,
    required this.files,
    this.applied = false,
  });

  final String id;
  final String prompt;
  final DateTime createdAt;
  final List<WorkspaceFileChange> files;
  final bool applied;

  String get unifiedDiff => files.map((file) => file.unifiedDiff).join('\n\n');
}

class UnifiedDiff {
  static List<DiffHunk> build(String oldText, String newText, String filePath) {
    if (oldText == newText) return const [];
    final oldLines = _lines(oldText);
    final newLines = _lines(newText);
    final operations = _diff(oldLines, newLines);
    final changed = <int>[
      for (var index = 0; index < operations.length; index++)
        if (operations[index].prefix != ' ') index,
    ];
    if (changed.isEmpty) return const [];

    final ranges = <(int, int)>[];
    var start = (changed.first - 3).clamp(0, operations.length);
    var end = (changed.first + 4).clamp(0, operations.length);
    for (final index in changed.skip(1)) {
      final nextStart = (index - 3).clamp(0, operations.length);
      final nextEnd = (index + 4).clamp(0, operations.length);
      if (nextStart <= end) {
        end = nextEnd;
      } else {
        ranges.add((start, end));
        start = nextStart;
        end = nextEnd;
      }
    }
    ranges.add((start, end));

    var oldLine = 1;
    var newLine = 1;
    final positions = <(int, int)>[];
    for (final operation in operations) {
      positions.add((oldLine, newLine));
      if (operation.prefix != '+') oldLine++;
      if (operation.prefix != '-') newLine++;
    }

    return [
      for (var index = 0; index < ranges.length; index++)
        _hunk(filePath, index, ranges[index], positions, operations),
    ];
  }

  static String applyHunks(String original, List<DiffHunk> hunks) {
    final source = _lines(original);
    final output = <String>[];
    var sourceIndex = 0;
    for (final hunk in [
      ...hunks,
    ]..sort((a, b) => a.oldStart.compareTo(b.oldStart))) {
      final hunkStart = (hunk.oldStart - 1).clamp(0, source.length);
      output.addAll(source.sublist(sourceIndex, hunkStart));
      var cursor = hunkStart;
      for (final line in hunk.lines) {
        if (line.isEmpty) continue;
        final prefix = line[0];
        final content = line.substring(1);
        if (prefix == ' ') {
          output.add(content);
          cursor++;
        } else if (prefix == '-') {
          cursor++;
        } else if (prefix == '+') {
          output.add(content);
        }
      }
      sourceIndex = cursor;
    }
    output.addAll(source.sublist(sourceIndex));
    final result = output.join('\n');
    return result.isEmpty ||
            (!original.endsWith('\n') &&
                hunks.last.lines.lastOrNull?.startsWith('+') != true)
        ? result
        : '$result\n';
  }

  static DiffHunk _hunk(
    String path,
    int index,
    (int, int) range,
    List<(int, int)> positions,
    List<_DiffOperation> operations,
  ) {
    final selected = operations.sublist(range.$1, range.$2);
    return DiffHunk(
      id: '$path#$index',
      oldStart: positions[range.$1].$1,
      oldCount: selected.where((line) => line.prefix != '+').length,
      newStart: positions[range.$1].$2,
      newCount: selected.where((line) => line.prefix != '-').length,
      lines: selected.map((line) => '${line.prefix}${line.text}').toList(),
    );
  }

  static List<String> _lines(String value) {
    if (value.isEmpty) return const [];
    final lines = value.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  static List<_DiffOperation> _diff(
    List<String> oldLines,
    List<String> newLines,
  ) {
    final lengths = List.generate(
      oldLines.length + 1,
      (_) => List<int>.filled(newLines.length + 1, 0),
    );
    for (var oldIndex = oldLines.length - 1; oldIndex >= 0; oldIndex--) {
      for (var newIndex = newLines.length - 1; newIndex >= 0; newIndex--) {
        lengths[oldIndex][newIndex] = oldLines[oldIndex] == newLines[newIndex]
            ? lengths[oldIndex + 1][newIndex + 1] + 1
            : lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1]
            ? lengths[oldIndex + 1][newIndex]
            : lengths[oldIndex][newIndex + 1];
      }
    }
    final result = <_DiffOperation>[];
    var oldIndex = 0;
    var newIndex = 0;
    while (oldIndex < oldLines.length || newIndex < newLines.length) {
      if (oldIndex < oldLines.length &&
          newIndex < newLines.length &&
          oldLines[oldIndex] == newLines[newIndex]) {
        result.add(_DiffOperation(' ', oldLines[oldIndex]));
        oldIndex++;
        newIndex++;
      } else if (newIndex < newLines.length &&
          (oldIndex == oldLines.length ||
              lengths[oldIndex][newIndex + 1] >=
                  lengths[oldIndex + 1][newIndex])) {
        result.add(_DiffOperation('+', newLines[newIndex++]));
      } else {
        result.add(_DiffOperation('-', oldLines[oldIndex++]));
      }
    }
    return result;
  }
}

class _DiffOperation {
  const _DiffOperation(this.prefix, this.text);

  final String prefix;
  final String text;
}
