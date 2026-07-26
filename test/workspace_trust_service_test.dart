import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/workspace_trust_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('contained file resolution rejects prefix siblings', () async {
    SharedPreferences.setMockInitialValues({});
    final parent = await Directory.systemTemp.createTemp('trust-boundary-');
    final workspace = await Directory('${parent.path}-workspace').create();
    final sibling = await Directory('${workspace.path}-other').create();
    final inside = await File(
      '${workspace.path}${Platform.pathSeparator}inside.txt',
    ).writeAsString('inside');
    final outside = await File(
      '${sibling.path}${Platform.pathSeparator}outside.txt',
    ).writeAsString('outside');
    addTearDown(() async {
      await parent.delete(recursive: true);
      await workspace.delete(recursive: true);
      await sibling.delete(recursive: true);
    });

    final service = WorkspaceTrustService();
    expect(
      await service.resolveContainedFile(workspace.path, inside.path),
      isNotNull,
    );
    expect(
      await service.resolveContainedFile(workspace.path, outside.path),
      isNull,
    );
  });

  test('missing persisted workspace is not trusted', () async {
    SharedPreferences.setMockInitialValues({
      'trusted_workspaces': ['C:/missing-workspace'],
    });

    expect(
      await WorkspaceTrustService().isTrusted('C:/missing-workspace'),
      isFalse,
    );
  });

  test('contained file resolution rejects symlink escapes', () async {
    final workspace = await Directory.systemTemp.createTemp('trust-link-root-');
    final outside = await Directory.systemTemp.createTemp(
      'trust-link-outside-',
    );
    final secret = await File(
      '${outside.path}${Platform.pathSeparator}secret.txt',
    ).writeAsString('outside');
    final link = Link(
      '${workspace.path}${Platform.pathSeparator}linked-secret.txt',
    );
    try {
      await link.create(secret.path);
    } on FileSystemException {
      await workspace.delete(recursive: true);
      await outside.delete(recursive: true);
      return;
    }
    addTearDown(() async {
      await workspace.delete(recursive: true);
      await outside.delete(recursive: true);
    });

    expect(
      await WorkspaceTrustService().resolveContainedFile(
        workspace.path,
        link.path,
      ),
      isNull,
    );
  });
}
