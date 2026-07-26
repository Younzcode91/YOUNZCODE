enum ChatRole { user, assistant, tool, error }

enum _ResponseLineKind { blank, heading, numbered, bullet, text, code }

String formatAgentResponse(String content) {
  final lines = <({String text, _ResponseLineKind kind})>[];
  var fencedCode = false;
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (RegExp(r"^(`{3,}|'{3,})[a-zA-Z0-9_-]*$").hasMatch(trimmed)) {
      fencedCode = !fencedCode;
      continue;
    }
    if (fencedCode) {
      lines.add((text: line, kind: _ResponseLineKind.code));
      continue;
    }
    if (trimmed.isEmpty) {
      lines.add((text: '', kind: _ResponseLineKind.blank));
      continue;
    }
    final heading = RegExp(r'^#{1,6}\s+(.+)$').firstMatch(trimmed);
    if (heading != null) {
      final title = _replaceInlineQuotes(heading.group(1)!.trim());
      lines.add((text: title, kind: _ResponseLineKind.heading));
      continue;
    }
    final bullet = RegExp(r'^\s*[-*+]\s+(.+)$').firstMatch(line);
    if (bullet != null) {
      lines.add((
        text: '• ${_replaceInlineQuotes(bullet.group(1)!.trim())}',
        kind: _ResponseLineKind.bullet,
      ));
      continue;
    }
    lines.add((
      text: _replaceInlineQuotes(line),
      kind: RegExp(r'^\d+[.)]\s+\S').hasMatch(trimmed)
          ? _ResponseLineKind.numbered
          : _ResponseLineKind.text,
    ));
  }

  final output = <String>[];
  _ResponseLineKind? previousKind;
  void addBlankLine() {
    if (output.isNotEmpty && output.last.isNotEmpty) output.add('');
  }

  for (final line in lines) {
    if (line.kind == _ResponseLineKind.blank) {
      addBlankLine();
      previousKind = line.kind;
      continue;
    }
    if (line.kind == _ResponseLineKind.heading) {
      addBlankLine();
      output.add(line.text);
      addBlankLine();
    } else if (line.kind == _ResponseLineKind.numbered) {
      addBlankLine();
      output.add(line.text);
    } else if (line.kind == _ResponseLineKind.bullet) {
      if (previousKind == _ResponseLineKind.text ||
          previousKind == _ResponseLineKind.code) {
        addBlankLine();
      }
      output.add(line.text);
    } else {
      if (previousKind == _ResponseLineKind.bullet) addBlankLine();
      output.add(line.text);
    }
    previousKind = line.kind;
  }
  return output.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String _replaceInlineQuotes(String value) => value
    .replaceAllMapped(
      RegExp(r'\*\*([^*\n]+)\*\*'),
      (match) => '"${match.group(1)}"',
    )
    .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (match) => '"${match.group(1)}"')
    .replaceAllMapped(
      RegExp(r"(^|\s)'([^'\n]+)'(?=[\s.,;:!?)]|$)"),
      (match) => '${match.group(1)}"${match.group(2)}"',
    );

class ChatEntry {
  const ChatEntry({required this.role, required this.content});

  factory ChatEntry.fromJson(Map<String, dynamic> json) => ChatEntry(
    role: ChatRole.values.firstWhere(
      (role) => role.name == json['role'],
      orElse: () => ChatRole.error,
    ),
    content: json['content'] as String? ?? '',
  );

  final ChatRole role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role.name, 'content': content};
}
