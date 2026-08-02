import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/quality_gate_service.dart';

void main() {
  test('merencanakan analyze dan relevant test untuk proyek Flutter', () async {
    final root = await Directory.systemTemp.createTemp('younz-quality-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}pubspec.yaml',
    ).writeAsString('name: sample');
    final testDirectory = Directory('${root.path}${Platform.pathSeparator}test')
      ..createSync();
    await File(
      '${testDirectory.path}${Platform.pathSeparator}service_test.dart',
    ).writeAsString('void main() {}');

    final plan = await QualityGateService().plan(root.path, [
      'lib/service.dart',
    ]);

    expect(plan.map((check) => check.label), [
      'Dart analyze',
      'Relevant Flutter tests',
    ]);
    expect(plan.last.arguments, contains('test/service_test.dart'));
  });

  test('berhenti pada quality check pertama yang gagal', () async {
    final root = await Directory.systemTemp.createTemp('younz-quality-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}pubspec.yaml',
    ).writeAsString('name: sample');
    var runs = 0;
    final service = QualityGateService(
      runner: (workspace, check, timeout) async {
        runs++;
        return QualityCheckResult(
          check: check,
          exitCode: 1,
          output: 'failed',
          duration: Duration.zero,
        );
      },
    );

    final result = await service.run(root.path, ['lib/service.dart']);

    expect(result.passed, isFalse);
    expect(runs, 1);
  });
}
