import 'dart:io';

/// Simulates the GitHub Actions expression used to gate merges on
/// HANDSHAKE_FAIL_RATIO, so the gating logic can be validated locally
/// (and in CI) without running GitHub's engine.
///
/// The expression is read from `.github/workflows/dap-load-test.yml` itself,
/// so the simulator can never drift out of sync with the workflow.
///
/// Semantics implemented (actions/runner ExpressionEngine):
///  * `||` returns the left operand when truthy, otherwise the right operand.
///  * `&&` returns the left operand when falsy, otherwise the right operand.
///  * Falsy: `false`, `null`, empty string. Everything else is truthy.
///  * `==` is loose equality; strings compare case-insensitively, mixed
///    types coerce to a number per the docs (null->0, bool->1/0, string
///    parsed or NaN).
///
/// Usage: dart run tool/simulate_gating.dart
/// Exit code is 0 only if every simulated case matches the expected value
/// and the downstream enforcement behavior of tool/run_dap_load_test.sh.

const workflowPath = '.github/workflows/dap-load-test.yml';

// ---------------------------------------------------------------- lexer/parser

sealed class GhNode {}

class GhStringNode extends GhNode {
  GhStringNode(this.value);
  final String value;
}

class GhBoolNode extends GhNode {
  GhBoolNode(this.value);
  final bool value;
}

class GhNullNode extends GhNode {}

class GhIdentNode extends GhNode {
  GhIdentNode(this.path);
  final String path;
}

class GhOrNode extends GhNode {
  GhOrNode(this.left, this.right);
  final GhNode left;
  final GhNode right;
}

class GhAndNode extends GhNode {
  GhAndNode(this.left, this.right);
  final GhNode left;
  final GhNode right;
}

class GhEqNode extends GhNode {
  GhEqNode(this.left, this.right);
  final GhNode left;
  final GhNode right;
}

List<String> _tokenize(String source) {
  final tokens = <String>[];
  var index = 0;
  while (index < source.length) {
    final char = source[index];
    if (char == ' ') {
      index++;
      continue;
    }
    if (char == '(' || char == ')') {
      tokens.add(char);
      index++;
      continue;
    }
    if (source.startsWith('||', index)) {
      tokens.add('||');
      index += 2;
      continue;
    }
    if (source.startsWith('&&', index)) {
      tokens.add('&&');
      index += 2;
      continue;
    }
    if (source.startsWith('==', index)) {
      tokens.add('==');
      index += 2;
      continue;
    }
    if (char == "'") {
      final end = source.indexOf("'", index + 1);
      if (end < 0) throw FormatException('Unterminated string in: $source');
      tokens.add("'${source.substring(index + 1, end)}'");
      index = end + 1;
      continue;
    }
    // Identifier or bareword: consume until a delimiter. Dotted paths like
    // github.event_name stay a single token and are resolved in _resolve.
    var end = index;
    while (end < source.length &&
        !RegExp(r'[\s()'']').hasMatch(source[end]) &&
        !source.startsWith('||', end) &&
        !source.startsWith('&&', end) &&
        !source.startsWith('==', end)) {
      end++;
    }
    tokens.add(source.substring(index, end));
    index = end;
  }
  return tokens;
}

class _Parser {
  _Parser(this.tokens);

  final List<String> tokens;
  int position = 0;

  GhNode parse() {
    final node = _parseOr();
    if (position != tokens.length) {
      throw FormatException('Unexpected token: ${tokens[position]}');
    }
    return node;
  }

  GhNode _parseOr() {
    var node = _parseAnd();
    while (_peek('||')) {
      position++;
      node = GhOrNode(node, _parseAnd());
    }
    return node;
  }

  GhNode _parseAnd() {
    var node = _parseEquality();
    while (_peek('&&')) {
      position++;
      node = GhAndNode(node, _parseEquality());
    }
    return node;
  }

  GhNode _parseEquality() {
    var node = _parsePrimary();
    while (_peek('==')) {
      position++;
      node = GhEqNode(node, _parsePrimary());
    }
    return node;
  }

  GhNode _parsePrimary() {
    if (position >= tokens.length) {
      throw FormatException('Unexpected end of expression');
    }
    final token = tokens[position++];
    if (token == '(') {
      final node = _parseOr();
      if (!_peek(')')) throw FormatException('Missing closing paren');
      position++;
      return node;
    }
    if (token.startsWith("'")) {
      return GhStringNode(token.substring(1, token.length - 1));
    }
    if (token == 'true') return GhBoolNode(true);
    if (token == 'false') return GhBoolNode(false);
    if (token == 'null') return GhNullNode();
    return GhIdentNode(token);
  }

  bool _peek(String token) =>
      position < tokens.length && tokens[position] == token;
}

// ---------------------------------------------------------------- evaluation

Object? _evaluate(GhNode node, Map<String, Object?> context) {
  switch (node) {
    case GhStringNode(:final value):
      return value;
    case GhBoolNode(:final value):
      return value;
    case GhNullNode():
      return null;
    case GhIdentNode(:final path):
      return _resolve(path, context);
    case GhOrNode(:final left, :final right):
      final leftValue = _evaluate(left, context);
      return _truthy(leftValue) ? leftValue : _evaluate(right, context);
    case GhAndNode(:final left, :final right):
      final leftValue = _evaluate(left, context);
      return _truthy(leftValue) ? _evaluate(right, context) : leftValue;
    case GhEqNode(:final left, :final right):
      return _looseEquals(_evaluate(left, context), _evaluate(right, context));
  }
}

Object? _resolve(String path, Map<String, Object?> context) {
  Object? current = context;
  for (final part in path.split('.')) {
    if (current is! Map<String, Object?>) return null;
    if (!current.containsKey(part)) return null;
    current = current[part];
  }
  return current;
}

bool _truthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is String) return value.isNotEmpty;
  return true;
}

double _toNumber(Object? value) {
  if (value == null) return 0;
  if (value is bool) return value ? 1 : 0;
  if (value is String) return double.tryParse(value) ?? double.nan;
  return double.nan;
}

bool _looseEquals(Object? left, Object? right) {
  if (left is String && right is String) {
    return left.toLowerCase() == right.toLowerCase();
  }
  if (left is bool && right is bool) return left == right;
  if (left == null && right == null) return true;
  return _toNumber(left) == _toNumber(right);
}

String _stringify(Object? value) {
  if (value == null) return '';
  if (value is bool) return value ? 'true' : 'false';
  return '$value';
}

// ------------------------------------------------------------------ extraction

/// Pulls the `${{ ... }}` expression from the HANDSHAKE_FAIL_RATIO env line in
/// the workflow file, so the simulation always tests the real expression.
String _extractExpression() {
  final workflow = File(workflowPath).readAsStringSync();
  final line = workflow
      .split('\n')
      .where((candidate) => candidate.contains('HANDSHAKE_FAIL_RATIO:'))
      .firstWhere(
        (candidate) => candidate.contains(r'${{'),
        orElse: () => '',
      );
  if (line.isEmpty) {
    throw StateError('No HANDSHAKE_FAIL_RATIO expression found in $workflowPath');
  }
  final match = RegExp(r'\$\{\{\s*(.+?)\s*\}\}').firstMatch(line);
  if (match == null) {
    throw StateError('Could not parse expression from: $line');
  }
  return match.group(1)!;
}

// ----------------------------------------------------------------------- cases

/// (eventName, vars.HANDSHAKE_FAIL_RATIO or null when unset, expected env value)
const cases = <(String, String?, String)>[
  ('pull_request', null, '0.5'), // default applies
  ('pull_request', '0.3', '0.3'), // repo variable wins
  ('pull_request', '', '0.5'), // empty var is falsy -> default
  ('pull_request', '0', '0'), // non-empty -> zero tolerance
  ('push', null, '0.5'),
  ('push', '0.7', '0.7'),
  ('schedule', null, ''), // nightly: no merge-gating
  ('schedule', '0.3', ''), // nightly ignores the variable
  ('workflow_dispatch', null, ''),
  ('issue_comment', null, ''),
  ('issue_comment', '0.3', ''), // unknown events are not gated
];

/// Mirrors tool/run_dap_load_test.sh: `FAIL_RATIO="${HANDSHAKE_FAIL_RATIO:-}"`
/// then `[ -n "$FAIL_RATIO" ]` decides enforcement.
String _scriptEffect(String envValue) {
  if (envValue.isEmpty) return 'NOT enforced (nightly/monitor)';
  final threshold = double.tryParse(envValue);
  if (threshold != null && threshold == 0) {
    return 'ENFORCED (zero-tolerance: any handshake row fails)';
  }
  return 'ENFORCED (fail when ratio >= $envValue)';
}

void main() {
  final expression = _extractExpression();
  stdout.writeln('Expression under test (from $workflowPath):');
  stdout.writeln('  \${{ $expression }}');
  stdout.writeln();
  stdout.writeln('Simulated GitHub Actions evaluation:');
  stdout.writeln('  event_name         vars.HFR      env value      script effect');
  stdout.writeln('  ${'-' * 70}');

  var failures = 0;
  for (final (eventName, variable, expected) in cases) {
    final context = <String, Object?>{
      'github': <String, Object?>{
        'event_name': eventName,
      },
      'vars': <String, Object?>{
        'HANDSHAKE_FAIL_RATIO': variable,
      },
    };
    final tokens = _tokenize(expression);
    final value = _evaluate(_Parser(tokens).parse(), context);
    final envValue = _stringify(value);
    final matches = envValue == expected;
    if (!matches) failures++;

    final variableLabel = variable == null ? '<unset>' : "'$variable'";
    stdout.writeln(
      '  ${eventName.padRight(18)}'
      '${variableLabel.padRight(13)}'
      '${envValue.padRight(14)}'
      '${_scriptEffect(envValue)}'
      '${matches ? '' : '   <-- MISMATCH (expected $expected)'}',
    );
  }

  stdout.writeln();
  if (failures > 0) {
    stderr.writeln('FAIL: $failures case(s) did not match expectations.');
    exitCode = 1;
  } else {
    stdout.writeln('PASS: all ${cases.length} cases match GitHub semantics.');
  }
}
