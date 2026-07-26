import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/workspace_change.dart';
import 'approval_mode.dart';
import 'mcp_client.dart';
import 'secret_scanner.dart';

enum PermissionDecision { reject, rejectAlways, allowOnce, allowAlways }

typedef PermissionRequest =
    Future<PermissionDecision> Function(String title, String detail);
typedef WorkspaceChangesChanged = void Function(WorkspaceTurnChanges? changes);

class WorkspaceCommandCancelledException implements Exception {
  const WorkspaceCommandCancelledException();

  @override
  String toString() => 'Perintah dibatalkan oleh pengguna.';
}

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

class WorkspaceTools {
  WorkspaceTools({
    required this.root,
    required this.requestPermission,
    required this.allowWrite,
    required this.allowTerminal,
    this.approvalMode = ApprovalMode.askForApproval,
    required this.environment,
    this.mcpClients = const [],
    this.commandTimeoutMs = 120000,
    this.onChangesChanged,
    this.stageEdits = false,
  });

  final String root;
  final PermissionRequest requestPermission;
  final bool allowWrite;
  final bool allowTerminal;
  final ApprovalMode approvalMode;
  final Map<String, String> environment;
  final List<McpClient> mcpClients;
  final int commandTimeoutMs;
  final WorkspaceChangesChanged? onChangesChanged;
  final bool stageEdits;
  final Map<String, ({McpClient client, String tool})> _mcpAliases = {};
  final Set<String> _alwaysAllowed = {};
  final Set<String> _alwaysRejected = {};
  final List<String> permissionAuditLog = [];
  Process? _activeProcess;
  bool _cancelRequested = false;
  final Map<String, _StagedFile> _stagedFiles = {};
  WorkspaceTurnChanges? _lastAppliedTurn;
  String _turnId = '';
  String _turnPrompt = '';

  void beginTurn(String prompt) {
    _turnId = DateTime.now().microsecondsSinceEpoch.toString();
    _turnPrompt = prompt;
    _stagedFiles.clear();
    onChangesChanged?.call(null);
  }

  WorkspaceTurnChanges? get pendingChanges => _buildChanges();
  WorkspaceTurnChanges? get lastAppliedTurn => _lastAppliedTurn;

  static const definitions = <Map<String, Object>>[
    {
      'type': 'function',
      'function': {
        'name': 'list_files',
        'description': 'Daftar file di workspace berdasarkan pola glob.',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Contoh: **/*.dart atau pubspec.yaml',
            },
          },
          'required': ['pattern'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_file',
        'description': 'Baca file teks di dalam workspace.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_text',
        'description': 'Cari regex dalam workspace dengan ripgrep.',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'glob': {'type': 'string'},
          },
          'required': ['pattern'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_file',
        'description': 'Buat atau timpa file. Memerlukan persetujuan.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'replace_text',
        'description': 'Ganti satu teks unik. Memerlukan persetujuan.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'old_text': {'type': 'string'},
            'new_text': {'type': 'string'},
          },
          'required': ['path', 'old_text', 'new_text'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'run_command',
        'description':
            'Jalankan PowerShell di workspace. Memerlukan persetujuan.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
          },
          'required': ['command'],
          'additionalProperties': false,
        },
      },
    },
  ];

  static List<Map<String, Object>> definitionsFor({
    required bool allowWrite,
    required bool allowTerminal,
  }) {
    return definitions.where((definition) {
      final function = definition['function']! as Map<String, Object>;
      final name = function['name']! as String;
      if (!allowWrite && {'write_file', 'replace_text'}.contains(name)) {
        return false;
      }
      if (!allowTerminal && name == 'run_command') return false;
      return true;
    }).toList();
  }

  Future<List<Map<String, Object>>> initializeAndDefinitions() async {
    final result = definitionsFor(
      allowWrite: allowWrite,
      allowTerminal: allowTerminal,
    );
    _mcpAliases.clear();
    for (final client in mcpClients) {
      try {
        await client.initialize(
          approveLaunch: (command, arguments) => _approve(
            'Jalankan server MCP',
            'Command: $command\nArguments: ${jsonEncode(arguments)}',
            pattern: 'mcp_launch:${jsonEncode([command, ...arguments])}',
            potentiallyUnsafe: true,
            requireExplicit: true,
          ),
        );
        for (final tool in client.tools) {
          var alias = _safeAlias('mcp_${client.config.name}_${tool.name}');
          var suffix = 2;
          while (_mcpAliases.containsKey(alias)) {
            alias =
                '${_safeAlias('mcp_${client.config.name}_${tool.name}')}_${suffix++}';
          }
          _mcpAliases[alias] = (client: client, tool: tool.name);
          result.add({
            'type': 'function',
            'function': <String, Object>{
              'name': alias,
              'description': '[MCP ${client.config.name}] ${tool.description}',
              'parameters': tool.inputSchema,
            },
          });
        }
      } catch (_) {
        // One unavailable MCP server must not disable built-in tools.
      }
    }
    return result;
  }

  Future<String> execute(String name, Map<String, dynamic> arguments) async {
    final mcp = _mcpAliases[name];
    if (mcp != null) {
      if (!await _approve(
        'Jalankan tool eksternal',
        '${mcp.client.config.name} / ${mcp.tool}\n\n$arguments',
        pattern: 'mcp:${mcp.client.config.name}/${mcp.tool}',
        potentiallyUnsafe: true,
      )) {
        return 'Ditolak oleh pengguna.';
      }
      return _truncate(await mcp.client.callTool(mcp.tool, arguments));
    }
    return switch (name) {
      'list_files' => _listFiles(_text(arguments, 'pattern')),
      'read_file' => _readFile(_text(arguments, 'path')),
      'search_text' => _searchText(
        _text(arguments, 'pattern'),
        arguments['glob'] as String?,
      ),
      'write_file' => _writeFile(
        _text(arguments, 'path'),
        _text(arguments, 'content', allowEmpty: true),
      ),
      'replace_text' => _replaceText(
        _text(arguments, 'path'),
        _text(arguments, 'old_text'),
        _text(arguments, 'new_text', allowEmpty: true),
      ),
      'run_command' => _runCommand(_text(arguments, 'command')),
      _ => throw StateError('Tool tidak dikenal: $name'),
    };
  }

  static String _safeAlias(String value) {
    final safe = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return safe.substring(0, safe.length.clamp(1, 64));
  }

  Future<void> dispose() async {
    await cancelActive();
    await Future.wait(mcpClients.map((client) => client.dispose()));
  }

  Future<void> cancelActive() async {
    _cancelRequested = true;
    final process = _activeProcess;
    if (process != null) await _terminateProcessTree(process);
    await Future.wait(mcpClients.map((client) => client.dispose()));
  }

  String _text(
    Map<String, dynamic> arguments,
    String key, {
    bool allowEmpty = false,
  }) {
    final value = arguments[key];
    if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
      throw FormatException('Parameter $key harus berupa teks.');
    }
    return value;
  }

  Future<String> _resolve(String requestedPath) async {
    final rootPath = path.normalize(path.absolute(root));
    final candidate = path.normalize(
      path.isAbsolute(requestedPath)
          ? requestedPath
          : path.join(rootPath, requestedPath),
    );
    if (approvalMode == ApprovalMode.fullAccess) return candidate;
    if (!path.equals(candidate, rootPath) &&
        !path.isWithin(rootPath, candidate)) {
      final directory = await FileSystemEntity.isDirectory(candidate)
          ? candidate
          : path.dirname(candidate);
      if (!await _approve(
        'Akses direktori eksternal',
        candidate,
        pattern: 'external_directory:${path.join(directory, '*')}',
        potentiallyUnsafe: true,
      )) {
        throw FileSystemException('Akses di luar workspace ditolak.');
      }
      return candidate;
    }

    final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
    final entityType = await FileSystemEntity.type(
      candidate,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.notFound) {
      final canonicalCandidate = await File(candidate).resolveSymbolicLinks();
      if (!path.equals(canonicalCandidate, canonicalRoot) &&
          !path.isWithin(canonicalRoot, canonicalCandidate)) {
        throw FileSystemException(
          'Junction atau symlink keluar workspace ditolak.',
        );
      }
      return candidate;
    }

    var existingParent = path.dirname(candidate);
    while (!await Directory(existingParent).exists()) {
      final parent = path.dirname(existingParent);
      if (parent == existingParent) {
        throw FileSystemException('Parent workspace tidak ditemukan.');
      }
      existingParent = parent;
    }
    final canonicalParent = await Directory(
      existingParent,
    ).resolveSymbolicLinks();
    if (!path.equals(canonicalParent, canonicalRoot) &&
        !path.isWithin(canonicalRoot, canonicalParent)) {
      throw FileSystemException(
        'Junction atau symlink keluar workspace ditolak.',
      );
    }
    return candidate;
  }

  bool _isSensitive(String requestedPath) {
    final normalized = requestedPath.replaceAll('\\', '/').toLowerCase();
    final name = normalized.split('/').last;
    return name == '.env' ||
        name.startsWith('.env.') ||
        {'.npmrc', '.pypirc', 'id_rsa', 'id_ed25519'}.contains(name) ||
        normalized.contains('/.ssh/');
  }

  Future<String> _listFiles(String pattern) async {
    final result = await Process.run('rg', [
      '--files',
      '--glob',
      pattern,
      '--glob',
      '!.git/**',
      '--glob',
      '!build/**',
      '--glob',
      '!.env',
      '--glob',
      '!.env.*',
      '--glob',
      '!.ssh/**',
      '--glob',
      '!**/id_rsa',
      '--glob',
      '!**/id_ed25519',
    ], workingDirectory: root);
    if (result.exitCode == 1) return 'Tidak ada file yang cocok.';
    if (result.exitCode != 0) {
      throw ProcessException('rg', const [], '${result.stderr}');
    }
    return _truncate('${result.stdout}');
  }

  Future<String> _readFile(String requestedPath) async {
    if (_isSensitive(requestedPath) &&
        !await _approve(
          'Baca file sensitif',
          requestedPath,
          pattern: 'read:$requestedPath',
          potentiallyUnsafe: true,
        )) {
      return 'Ditolak oleh pengguna.';
    }
    final resolved = await _resolve(requestedPath);
    final staged = _stagedFiles[resolved];
    return _truncate(
      _redact(staged?.proposed ?? await File(resolved).readAsString()),
    );
  }

  Future<String> _searchText(String pattern, String? glob) async {
    final arguments = ['--line-number', '--color', 'never'];
    if (glob != null && glob.isNotEmpty) arguments.addAll(['--glob', glob]);
    arguments.addAll([
      '--glob',
      '!.git/**',
      '--glob',
      '!build/**',
      '--glob',
      '!.env',
      '--glob',
      '!.env.*',
      '--glob',
      '!.ssh/**',
      '--glob',
      '!**/id_rsa',
      '--glob',
      '!**/id_ed25519',
      '--',
      pattern,
    ]);
    final result = await Process.run('rg', arguments, workingDirectory: root);
    if (result.exitCode == 1) return 'Tidak ditemukan kecocokan.';
    if (result.exitCode != 0) {
      throw ProcessException('rg', arguments, '${result.stderr}');
    }
    return _truncate('${result.stdout}');
  }

  Future<String> _writeFile(String requestedPath, String content) async {
    if (!allowWrite) throw StateError('Izin menulis file dinonaktifkan.');
    if (_isSensitive(requestedPath) &&
        !await _approve(
          'Tulis file sensitif',
          requestedPath,
          pattern: 'edit-sensitive:$requestedPath',
          potentiallyUnsafe: true,
        )) {
      return 'Ditolak oleh pengguna.';
    }
    final resolved = await _resolve(requestedPath);
    final file = File(resolved);
    final action = await file.exists() ? 'Timpa file' : 'Buat file';
    if (!await _approve(
      action,
      '$requestedPath\n\n${content.length} karakter akan ditulis.',
      pattern: 'edit:*',
    )) {
      return 'Ditolak oleh pengguna.';
    }
    if (!stageEdits) {
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return '$requestedPath berhasil ditulis.';
    }
    final existing = _stagedFiles[resolved];
    final existed = existing?.originallyExisted ?? await file.exists();
    final original =
        existing?.original ?? (existed ? await file.readAsString() : '');
    _stagedFiles[resolved] = _StagedFile(
      requestedPath: requestedPath,
      original: original,
      proposed: content,
      originallyExisted: existed,
    );
    _notifyChanges();
    return '$requestedPath disiapkan untuk review; belum ditulis ke disk.';
  }

  Future<String> _replaceText(
    String requestedPath,
    String oldText,
    String newText,
  ) async {
    if (!allowWrite) throw StateError('Izin menulis file dinonaktifkan.');
    if (_isSensitive(requestedPath) &&
        !await _approve(
          'Ubah file sensitif',
          requestedPath,
          pattern: 'edit-sensitive:$requestedPath',
          potentiallyUnsafe: true,
        )) {
      return 'Ditolak oleh pengguna.';
    }
    final resolved = await _resolve(requestedPath);
    final file = File(resolved);
    final staged = _stagedFiles[resolved];
    final content = staged?.proposed ?? await file.readAsString();
    final matches = oldText.allMatches(content).length;
    if (matches != 1) {
      throw StateError('old_text harus unik; ditemukan $matches kecocokan.');
    }
    if (!await _approve(
      'Ubah file',
      '$requestedPath\n\n${oldText.length} karakter diganti dengan '
          '${newText.length} karakter.',
      pattern: 'edit:*',
    )) {
      return 'Ditolak oleh pengguna.';
    }
    if (!stageEdits) {
      await file.writeAsString(content.replaceFirst(oldText, newText));
      return '$requestedPath berhasil diubah.';
    }
    _stagedFiles[resolved] = _StagedFile(
      requestedPath: requestedPath,
      original: staged?.original ?? content,
      proposed: content.replaceFirst(oldText, newText),
      originallyExisted: staged?.originallyExisted ?? true,
    );
    _notifyChanges();
    return '$requestedPath disiapkan untuk review; belum ditulis ke disk.';
  }

  Future<WorkspaceTurnChanges?> applyChanges({Set<String>? hunkIds}) async {
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
      final file = File(await _resolve(change.path));
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

    // Validate the complete turn first so one conflict cannot partially apply it.
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
    onChangesChanged?.call(null);
    return applied;
  }

  void rejectChanges() {
    _stagedFiles.clear();
    onChangesChanged?.call(null);
  }

  Future<void> revertLastTurn() async {
    final turn = _lastAppliedTurn;
    if (turn == null) return;
    final pending = <({WorkspaceFileChange change, File file})>[];
    for (final change in turn.files) {
      pending.add((change: change, file: File(await _resolve(change.path))));
    }
    // Validate the complete turn first so one conflict cannot partially revert it.
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
      final file = item.file;
      if (!change.originallyExisted) {
        if (await file.exists()) await file.delete();
      } else {
        await _writeAtomically(file, change.originalContent);
      }
    }
    _lastAppliedTurn = null;
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

  void _notifyChanges() => onChangesChanged?.call(_buildChanges());

  Future<String> _runCommand(String command) async {
    if (!allowTerminal) throw StateError('Eksekusi terminal dinonaktifkan.');
    if (!await _approve(
      'Jalankan perintah',
      command,
      pattern: 'bash:${_commandPattern(command)}',
      potentiallyUnsafe: _isPotentiallyUnsafeCommand(command),
    )) {
      return 'Ditolak oleh pengguna.';
    }
    _cancelRequested = false;
    final shell = _shellInvocation(command);
    final process = await Process.start(
      shell.executable,
      shell.arguments,
      workingDirectory: root,
      environment: environment,
    );
    _activeProcess = process;
    final stdout = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderr = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    final commandTimeout = Duration(
      milliseconds: commandTimeoutMs > 0 ? commandTimeoutMs : 120000,
    );
    try {
      await process.exitCode.timeout(
        commandTimeout,
        onTimeout: () async {
          await _terminateProcessTree(process);
          throw TimeoutException(
            'Perintah melewati batas ${commandTimeout.inSeconds} detik '
            'dan dihentikan.',
            commandTimeout,
          );
        },
      );
      if (_cancelRequested) throw const WorkspaceCommandCancelledException();
      final output = '${await stdout}${await stderr}'.trim();
      return _truncate(
        output.isEmpty ? 'Perintah selesai tanpa output.' : output,
      );
    } finally {
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
  }

  // Runs a one-shot command through the platform shell: PowerShell on Windows,
  // otherwise bash (falling back to sh) with `-lc` so the string is parsed the
  // same way a user's shell would parse it.
  static ({String executable, List<String> arguments}) _shellInvocation(
    String command,
  ) {
    if (Platform.isWindows) {
      return (
        executable: 'powershell.exe',
        arguments: ['-NoProfile', '-NonInteractive', '-Command', command],
      );
    }
    for (final candidate in const ['/bin/bash', '/usr/bin/bash']) {
      if (File(candidate).existsSync()) {
        return (executable: candidate, arguments: ['-lc', command]);
      }
    }
    return (executable: '/bin/sh', arguments: ['-c', command]);
  }

  Future<void> _terminateProcessTree(Process process) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill.exe', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
        return;
      } catch (_) {
        // Fall through to the direct process kill.
      }
    }
    process.kill(ProcessSignal.sigkill);
  }

  Future<bool> _approve(
    String title,
    String detail, {
    required String pattern,
    bool potentiallyUnsafe = false,
    bool requireExplicit = false,
  }) async {
    if (_alwaysRejected.contains(pattern)) return false;
    if (!requireExplicit && approvalMode == ApprovalMode.fullAccess) {
      return Future.value(true);
    }
    if (!requireExplicit &&
        approvalMode == ApprovalMode.approveForMe &&
        !potentiallyUnsafe) {
      return Future.value(true);
    }
    if (_alwaysAllowed.contains(pattern)) return true;
    final decision = await requestPermission(
      title,
      '$detail\n\nPattern: $pattern',
    );
    permissionAuditLog.add(
      '${DateTime.now().toIso8601String()} $pattern ${decision.name}',
    );
    if (decision == PermissionDecision.allowAlways) {
      _alwaysAllowed.add(pattern);
    }
    if (decision == PermissionDecision.rejectAlways) {
      _alwaysRejected.add(pattern);
    }
    return decision == PermissionDecision.allowOnce ||
        decision == PermissionDecision.allowAlways;
  }

  Future<bool> approveDoomLoop(String tool, Map<String, dynamic> arguments) {
    return _approve(
      'Tool berulang terdeteksi',
      'Tool yang sama dipanggil 3 kali dengan input identik.\n\n'
          '$tool\n$arguments',
      pattern: 'doom_loop:$tool',
      potentiallyUnsafe: true,
    );
  }

  String _commandPattern(String command) {
    final trimmed = command.trim();
    // A chained / piped / substituted command must not collapse to the coarse
    // two-token pattern of its leading command; otherwise one "Allow always"
    // on a benign prefix (e.g. `git status`) would silently approve any
    // trailing command smuggled in via `;`, `&&`, `|`, or `$(...)`.
    if (RegExp(r'''[;|&`\n\r]|\$\(''').hasMatch(trimmed)) return trimmed;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.isEmpty) return '*';
    return '${parts.take(parts.length > 1 ? 2 : 1).join(' ')} *';
  }

  bool _isPotentiallyUnsafeCommand(String command) {
    final value = command.toLowerCase();
    // Includes PowerShell built-in aliases (rm/ri/rmi -> Remove-Item,
    // iex -> Invoke-Expression, irm/iwr -> Invoke-*Request, saps ->
    // Start-Process) and file-clobbering cmdlets, since -NoProfile does not
    // disable engine aliases.
    return RegExp(
      r'(^|[\s;&|(])(remove-item|rm|ri|rmi|del|erase|rd|rmdir|format|diskpart|shutdown|restart-computer|stop-computer|invoke-webrequest|invoke-restmethod|invoke-expression|iex|irm|iwr|curl|wget|ssh|scp|ftp|start-process|saps|set-content|add-content|out-file|set-executionpolicy|reg|runas)([\s;&|)]|$)|(--force|-force|--no-preserve-root|>|>>)',
    ).hasMatch(value);
  }

  String _truncate(String value) => value.length <= 30000
      ? _redact(value)
      : '${_redact(value.substring(0, 30000))}\n... output dipotong ...';

  // Route all tool output and file reads through the shared scanner so command
  // results and file contents get the same (stronger) redaction as attachments
  // and persisted chat, instead of a weaker three-pattern subset.
  String _redact(String value) => SecretScanner.redact(value);
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
