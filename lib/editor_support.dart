import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

class EditorLanguage {
  const EditorLanguage({
    required this.id,
    required this.keywords,
    this.snippets = const {},
  });

  final String id;
  final Set<String> keywords;
  final Map<String, String> snippets;

  static EditorLanguage fromPath(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'dart' => const EditorLanguage(
        id: 'Dart',
        keywords: {
          'abstract',
          'as',
          'assert',
          'async',
          'await',
          'break',
          'case',
          'catch',
          'class',
          'const',
          'continue',
          'covariant',
          'default',
          'deferred',
          'do',
          'dynamic',
          'else',
          'enum',
          'export',
          'extends',
          'extension',
          'external',
          'factory',
          'false',
          'final',
          'finally',
          'for',
          'Function',
          'get',
          'hide',
          'if',
          'implements',
          'import',
          'in',
          'interface',
          'is',
          'late',
          'library',
          'mixin',
          'new',
          'null',
          'of',
          'on',
          'operator',
          'part',
          'required',
          'rethrow',
          'return',
          'sealed',
          'set',
          'show',
          'static',
          'super',
          'switch',
          'sync',
          'this',
          'throw',
          'true',
          'try',
          'typedef',
          'var',
          'void',
          'when',
          'while',
          'with',
          'yield',
        },
        snippets: {
          'main': 'void main() {\n  \n}',
          'class': 'class ClassName {\n  \n}',
          'stful':
              'class WidgetName extends StatefulWidget {\n  const WidgetName({super.key});\n}',
        },
      ),
      'js' || 'jsx' || 'ts' || 'tsx' => const EditorLanguage(
        id: 'JavaScript',
        keywords: {
          'async',
          'await',
          'break',
          'case',
          'catch',
          'class',
          'const',
          'continue',
          'debugger',
          'default',
          'delete',
          'do',
          'else',
          'export',
          'extends',
          'false',
          'finally',
          'for',
          'from',
          'function',
          'if',
          'import',
          'in',
          'instanceof',
          'let',
          'new',
          'null',
          'of',
          'return',
          'static',
          'super',
          'switch',
          'this',
          'throw',
          'true',
          'try',
          'typeof',
          'undefined',
          'var',
          'void',
          'while',
          'yield',
        },
        snippets: {
          'log': 'console.log();',
          'func': 'function name() {\n  \n}',
          'arrow': 'const name = () => {\n  \n};',
        },
      ),
      'py' => const EditorLanguage(
        id: 'Python',
        keywords: {
          'and',
          'as',
          'assert',
          'async',
          'await',
          'break',
          'class',
          'continue',
          'def',
          'del',
          'elif',
          'else',
          'except',
          'False',
          'finally',
          'for',
          'from',
          'global',
          'if',
          'import',
          'in',
          'is',
          'lambda',
          'None',
          'nonlocal',
          'not',
          'or',
          'pass',
          'raise',
          'return',
          'True',
          'try',
          'while',
          'with',
          'yield',
        },
        snippets: {
          'main': 'if __name__ == "__main__":\n    ',
          'def': 'def name():\n    pass',
          'class': 'class ClassName:\n    pass',
        },
      ),
      'json' => const EditorLanguage(
        id: 'JSON',
        keywords: {'true', 'false', 'null'},
      ),
      'html' || 'htm' => const EditorLanguage(
        id: 'HTML',
        keywords: {'doctype', 'html', 'head', 'body', 'script'},
      ),
      'css' || 'scss' => const EditorLanguage(
        id: 'CSS',
        keywords: {'media', 'import', 'supports', 'keyframes'},
      ),
      'yaml' || 'yml' => const EditorLanguage(id: 'YAML', keywords: {}),
      'md' => const EditorLanguage(id: 'Markdown', keywords: {}),
      _ => const EditorLanguage(id: 'Plain Text', keywords: {}),
    };
  }
}

class SyntaxEditingController extends TextEditingController {
  SyntaxEditingController({required this.language, super.text});

  final EditorLanguage language;

  List<String> completionsAtCursor() {
    final offset = selection.baseOffset.clamp(0, text.length);
    final before = text.substring(0, offset);
    final prefix =
        RegExp(r'[A-Za-z_$][\w$]*$').firstMatch(before)?.group(0) ?? '';
    if (prefix.isEmpty) return const [];
    final identifiers = RegExp(
      r'[A-Za-z_$][\w$]{2,}',
    ).allMatches(text).map((match) => match.group(0)!).toSet();
    final candidates =
        {
            ...language.keywords,
            ...language.snippets.keys,
            ...identifiers,
          }.where((item) => item != prefix && item.startsWith(prefix)).toList()
          ..sort((a, b) {
            final aKeyword = language.keywords.contains(a) ? 0 : 1;
            final bKeyword = language.keywords.contains(b) ? 0 : 1;
            return aKeyword != bKeyword ? aKeyword - bKeyword : a.compareTo(b);
          });
    return candidates.take(10).toList();
  }

  void applyCompletion(String completion) {
    final offset = selection.baseOffset.clamp(0, text.length);
    final before = text.substring(0, offset);
    final match = RegExp(r'[A-Za-z_$][\w$]*$').firstMatch(before);
    final start = match?.start ?? offset;
    final replacement = language.snippets[completion] ?? completion;
    final updated = text.replaceRange(start, offset, replacement);
    final cursor = start + replacement.length;
    value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final light = Theme.of(context).brightness == Brightness.light;
    final spans = <TextSpan>[];
    final token = RegExp(
      r'''("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|\b\d+(?:\.\d+)?\b|\b[A-Za-z_$][\w$]*\b)''',
      multiLine: true,
    );
    var cursor = 0;
    for (final match in token.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final value = match.group(0)!;
      Color? color;
      FontWeight? weight;
      if (value.startsWith('//') ||
          value.startsWith('/*') ||
          (language.id == 'Python' && value.startsWith('#'))) {
        color = light ? const Color(0xFF5D6853) : const Color(0xFF758267);
      } else if (value.startsWith('"') || value.startsWith("'")) {
        color = light ? const Color(0xFF895B00) : const Color(0xFFE6B673);
      } else if (RegExp(r'^\d').hasMatch(value)) {
        color = light ? const Color(0xFF4E6815) : const Color(0xFFB7D986);
      } else if (language.keywords.contains(value)) {
        color = light ? const Color(0xFF006A62) : const Color(0xFF79D6CD);
        weight = FontWeight.w600;
      }
      spans.add(
        TextSpan(
          text: value,
          style: TextStyle(color: color, fontWeight: weight),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: base, children: spans);
  }
}

class EditorDiagnostic {
  const EditorDiagnostic({
    required this.line,
    required this.message,
    this.error = true,
  });
  final int line;
  final String message;
  final bool error;
}

class LanguageTooling {
  static Future<List<EditorDiagnostic>> analyze(String filePath) async {
    final extension = filePath.split('.').last.toLowerCase();
    try {
      if (extension == 'dart') {
        final result = await Process.run('dart', [
          'analyze',
          '--format',
          'machine',
          filePath,
        ]);
        return '${result.stdout}${result.stderr}'
            .split(RegExp(r'\r?\n'))
            .map((line) => line.split('|'))
            .where((parts) => parts.length >= 8)
            // machine format: severity|type|code|path|line|column|length|message
            .map(
              (parts) => EditorDiagnostic(
                line: int.tryParse(parts[4]) ?? 1,
                message: parts.sublist(7).join('|'),
                error: parts[0] == 'ERROR',
              ),
            )
            .toList();
      }
      if (extension == 'py') {
        final result = await Process.run('python', [
          '-m',
          'py_compile',
          filePath,
        ]);
        if (result.exitCode == 0) return const [];
        final output = '${result.stderr}';
        final line =
            int.tryParse(
              RegExp(r'line (\d+)').firstMatch(output)?.group(1) ?? '',
            ) ??
            1;
        return [EditorDiagnostic(line: line, message: output.trim())];
      }
      if ({'js', 'mjs', 'cjs'}.contains(extension)) {
        final result = await Process.run('node', ['--check', filePath]);
        if (result.exitCode == 0) return const [];
        return [EditorDiagnostic(line: 1, message: '${result.stderr}'.trim())];
      }
    } on ProcessException {
      return const [];
    }
    return const [];
  }

  static ({String executable, List<String> arguments})? debugCommand(
    String filePath,
  ) {
    final extension = filePath.split('.').last.toLowerCase();
    return switch (extension) {
      'dart' => (
        executable: 'dart',
        arguments: ['run', '--enable-asserts', filePath],
      ),
      'py' => (executable: 'python', arguments: ['-u', filePath]),
      'js' ||
      'mjs' ||
      'cjs' => (executable: 'node', arguments: ['--inspect-brk=0', filePath]),
      _ => null,
    };
  }
}

class CodeMinimapPainter extends CustomPainter {
  CodeMinimapPainter(
    this.text,
    this.breakpoints, {
    required this.normalColor,
    required this.accentColor,
    required this.breakpointColor,
  });
  final String text;
  final Set<int> breakpoints;
  final Color normalColor;
  final Color accentColor;
  final Color breakpointColor;

  @override
  void paint(Canvas canvas, Size size) {
    final lines = text.split('\n');
    final scale = mathMin(2.0, size.height / mathMax(1, lines.length));
    final normal = Paint()..color = normalColor;
    final accent = Paint()..color = accentColor;
    final breakpoint = Paint()..color = breakpointColor;
    for (var index = 0; index < lines.length; index++) {
      final value = lines[index].trimLeft();
      final width = (value.length * 0.8).clamp(2.0, size.width - 5);
      final y = index * scale;
      canvas.drawRect(
        Rect.fromLTWH(2, y, width, mathMax(0.7, scale * 0.55)),
        value.startsWith('//') || value.startsWith('#') ? normal : accent,
      );
      if (breakpoints.contains(index + 1)) {
        canvas.drawCircle(Offset(size.width - 2.5, y + 1), 2, breakpoint);
      }
    }
  }

  static double mathMin(num a, num b) => a < b ? a.toDouble() : b.toDouble();
  static double mathMax(num a, num b) => a > b ? a.toDouble() : b.toDouble();

  @override
  bool shouldRepaint(covariant CodeMinimapPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.breakpoints != breakpoints ||
      oldDelegate.normalColor != normalColor ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.breakpointColor != breakpointColor;
}
