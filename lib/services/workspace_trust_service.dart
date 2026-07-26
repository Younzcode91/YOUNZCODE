import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class WorkspaceTrustService {
  static const _key = 'trusted_workspaces';

  Future<bool> isTrusted(String workspace) async {
    if (workspace.isEmpty) return false;
    try {
      final canonical = _comparisonPath(
        await Directory(workspace).resolveSymbolicLinks(),
      );
      final preferences = await SharedPreferences.getInstance();
      return (preferences.getStringList(_key) ?? const [])
          .map(_comparisonPath)
          .contains(canonical);
    } on FileSystemException {
      return false;
    }
  }

  Future<void> setTrusted(String workspace, bool trusted) async {
    final canonical = _comparisonPath(
      await Directory(workspace).resolveSymbolicLinks(),
    );
    final preferences = await SharedPreferences.getInstance();
    final values = {
      ...(preferences.getStringList(_key) ?? const <String>[]).map(
        _comparisonPath,
      ),
    };
    trusted ? values.add(canonical) : values.remove(canonical);
    await preferences.setStringList(_key, values.toList());
  }

  /// Resolves [filePath] and returns it only when its current filesystem target
  /// is a regular file contained by the canonical workspace target.
  Future<String?> resolveContainedFile(
    String workspace,
    String filePath,
  ) async {
    if (workspace.isEmpty || filePath.isEmpty) return null;
    try {
      final root = await Directory(workspace).resolveSymbolicLinks();
      final candidate = await File(filePath).resolveSymbolicLinks();
      final comparedRoot = _comparisonPath(root);
      final comparedCandidate = _comparisonPath(candidate);
      if (comparedCandidate == comparedRoot ||
          !p.isWithin(comparedRoot, comparedCandidate)) {
        return null;
      }
      if (await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      return p.normalize(candidate);
    } on FileSystemException {
      return null;
    }
  }

  static String _comparisonPath(String value) {
    final normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
