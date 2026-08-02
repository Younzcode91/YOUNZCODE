import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/code_intelligence_service.dart';

void main() {
  test('mengindeks simbol, definisi, referensi, dan istilah terkait', () async {
    final root = await Directory.systemTemp.createTemp('younz-index-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}auth_service.dart',
    ).writeAsString('''
class AuthService {
  Future<void> saveToken(String token) async {}
}

void useAuth(AuthService service) {
  service.saveToken('secret');
}
''');
    final service = CodeIntelligenceService(root.path);

    final definition = await service.definition('AuthService');
    expect(definition?.path, 'auth_service.dart');
    expect(definition?.line, 1);
    expect(await service.references('saveToken'), hasLength(2));
    final semanticResults = await service.search('simpan credential');
    expect(semanticResults, isNotEmpty);
    expect(
      semanticResults.any((result) => result.preview.contains('saveToken')),
      isTrue,
    );
  });

  test('mengabaikan secrets dan direktori hasil build', () async {
    final root = await Directory.systemTemp.createTemp('younz-index-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}.env',
    ).writeAsString('SECRET_TOKEN=hidden');
    final build = Directory('${root.path}${Platform.pathSeparator}build')
      ..createSync();
    await File(
      '${build.path}${Platform.pathSeparator}generated.dart',
    ).writeAsString('class HiddenGenerated {}');
    final service = CodeIntelligenceService(root.path);

    expect(await service.search('SECRET_TOKEN'), isEmpty);
    expect(await service.definition('HiddenGenerated'), isNull);
  });
}
