import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/editor_support.dart';

void main() {
  test('mendeteksi bahasa dari ekstensi file', () {
    expect(EditorLanguage.fromPath('lib/main.dart').id, 'Dart');
    expect(EditorLanguage.fromPath('tool/build.py').id, 'Python');
    expect(EditorLanguage.fromPath('web/app.ts').id, 'JavaScript');
    expect(EditorLanguage.fromPath('LICENSE').id, 'Plain Text');
  });

  test(
    'autocomplete menggabungkan keyword, snippet, dan identifier dokumen',
    () {
      final controller = SyntaxEditingController(
        language: EditorLanguage.fromPath('main.dart'),
        text: 'class ProjectService {}\ncl',
      )..selection = const TextSelection.collapsed(offset: 26);
      addTearDown(controller.dispose);

      expect(controller.completionsAtCursor(), contains('class'));
      controller.applyCompletion('class');
      expect(
        controller.text,
        'class ProjectService {}\nclass ClassName {\n  \n}',
      );
    },
  );

  test('memilih runtime debug sesuai bahasa', () {
    expect(LanguageTooling.debugCommand('main.dart')?.executable, 'dart');
    expect(LanguageTooling.debugCommand('script.py')?.executable, 'python');
    expect(LanguageTooling.debugCommand('app.js')?.executable, 'node');
    expect(LanguageTooling.debugCommand('README.md'), isNull);
  });
}
