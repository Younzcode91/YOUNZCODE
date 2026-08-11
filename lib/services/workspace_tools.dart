import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/workspace_change.dart';
import 'approval_mode.dart';
import 'browser_agent_service.dart';
import 'mcp_client.dart';
import 'secret_scanner.dart';
import 'tool_permission_store.dart';
import 'workspace_edit_session.dart';

export 'workspace_edit_session.dart' show WorkspaceEditConflictException;

enum PermissionDecision { reject, rejectAlways, allowOnce, allowAlways }

typedef PermissionRequest =
    Future<PermissionDecision> Function(String title, String detail);
typedef WorkspaceChangesChanged = void Function(WorkspaceTurnChanges? changes);
typedef ToolPermissionChanged =
    void Function(String pattern, ToolPermissionPolicy policy);

class WorkspaceCommandCancelledException implements Exception {
  const WorkspaceCommandCancelledException();

  @override
  String toString() => 'Perintah dibatalkan oleh pengguna.';
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
    this.browser,
    this.allowExternalPaths = true,
    Map<String, ToolPermissionPolicy> toolPermissionPolicies = const {},
    this.onToolPermissionChanged,
  }) : toolPermissionPolicies = Map.of(toolPermissionPolicies) {
    _edits = WorkspaceEditSession(
      resolve: _resolve,
      onChanged: onChangesChanged,
    );
  }

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
  final BrowserAutomation? browser;

  /// When false, any path outside [root] is rejected outright instead of
  /// being offered for approval. Used to keep isolated multi-agent workers
  /// strictly inside their own worktree even when the permission callback
  /// would auto-approve external access.
  final bool allowExternalPaths;
  final Map<String, ToolPermissionPolicy> toolPermissionPolicies;
  final ToolPermissionChanged? onToolPermissionChanged;
  final Map<String, ({McpClient client, String tool})> _mcpAliases = {};
  final Set<String> _alwaysAllowed = {};
  final Set<String> _alwaysRejected = {};
  final List<String> permissionAuditLog = [];
  Process? _activeProcess;
  bool _cancelRequested = false;
  late final WorkspaceEditSession _edits;

  void beginTurn(String prompt) => _edits.beginTurn(prompt);

  WorkspaceTurnChanges? get pendingChanges => _edits.pendingChanges;
  WorkspaceTurnChanges? get lastAppliedTurn => _edits.lastAppliedTurn;

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

  static const browserDefinitions = <Map<String, Object>>[
    {
      'type': 'function',
      'function': {
        'name': 'browser_open',
        'description':
            'Buka URL HTTPS publik atau preview proyek localhost di browser '
            'agent yang terlihat di aplikasi.',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string'},
          },
          'required': ['url'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_read',
        'description':
            'Baca teks dan elemen interaktif halaman. Panggil ini sebelum '
            'browser_click, browser_type, atau browser_upload.',
        'parameters': {
          'type': 'object',
          'properties': {
            'max_characters': {
              'type': 'integer',
              'minimum': 1000,
              'maximum': 30000,
            },
          },
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_click',
        'description':
            'Klik elemen berdasarkan ref dari browser_read. Aksi berisiko '
            'seperti delete, submit, publish, login, atau pembayaran selalu '
            'memerlukan persetujuan eksplisit.',
        'parameters': {
          'type': 'object',
          'properties': {
            'ref': {'type': 'string'},
          },
          'required': ['ref'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_type',
        'description':
            'Ketik teks ke input atau editor halaman berdasarkan ref.',
        'parameters': {
          'type': 'object',
          'properties': {
            'ref': {'type': 'string'},
            'text': {'type': 'string'},
            'clear': {'type': 'boolean'},
            'submit': {'type': 'boolean'},
          },
          'required': ['ref', 'text'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_upload',
        'description':
            'Pilih satu atau beberapa file dari workspace untuk input file '
            'halaman. Selalu memerlukan persetujuan eksplisit.',
        'parameters': {
          'type': 'object',
          'properties': {
            'ref': {'type': 'string'},
            'paths': {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 1,
              'maxItems': 20,
            },
          },
          'required': ['ref', 'paths'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_screenshot',
        'description':
            'Simpan screenshot browser sebagai PNG ke folder screenshots '
            'di workspace.',
        'parameters': {
          'type': 'object',
          'properties': {
            'full_page': {'type': 'boolean'},
          },
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_back',
        'description': 'Kembali ke halaman browser sebelumnya.',
        'parameters': {
          'type': 'object',
          'properties': <String, Object>{},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_forward',
        'description': 'Maju ke halaman browser berikutnya.',
        'parameters': {
          'type': 'object',
          'properties': <String, Object>{},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_reload',
        'description': 'Muat ulang halaman browser saat ini.',
        'parameters': {
          'type': 'object',
          'properties': <String, Object>{},
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
    if (browser != null) result.addAll(browserDefinitions);
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
      'browser_open' => _browserOpen(_text(arguments, 'url')),
      'browser_read' => _browserRead(
        (arguments['max_characters'] as num?)?.toInt() ?? 12000,
      ),
      'browser_click' => _browserClick(_text(arguments, 'ref')),
      'browser_type' => _browserType(
        _text(arguments, 'ref'),
        _text(arguments, 'text', allowEmpty: true),
        clear: arguments['clear'] as bool? ?? true,
        submit: arguments['submit'] as bool? ?? false,
      ),
      'browser_upload' => _browserUpload(
        _text(arguments, 'ref'),
        _textList(arguments, 'paths'),
      ),
      'browser_screenshot' => _browserScreenshot(
        fullPage: arguments['full_page'] as bool? ?? false,
      ),
      'browser_back' => _browserNavigate('back'),
      'browser_forward' => _browserNavigate('forward'),
      'browser_reload' => _browserNavigate('reload'),
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

  List<String> _textList(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! List || value.isEmpty || value.length > 20) {
      throw FormatException('Parameter $key harus berupa daftar file.');
    }
    final result = value.map((item) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException(
          'Setiap nilai dalam $key harus berupa path file.',
        );
      }
      return item;
    }).toList();
    return result;
  }

  Future<String> _resolve(String requestedPath) async {
    final rootPath = path.normalize(path.absolute(root));
    final candidate = path.normalize(
      path.isAbsolute(requestedPath)
          ? requestedPath
          : path.join(rootPath, requestedPath),
    );
    final external =
        !path.equals(candidate, rootPath) &&
        !path.isWithin(rootPath, candidate);
    // Hard guarantee for isolated workers: external paths are never reachable,
    // regardless of approval mode or how permissive the permission callback is.
    if (external && !allowExternalPaths) {
      throw FileSystemException(
        'Akses di luar workspace ditolak: izin eksternal dinonaktifkan.',
        candidate,
      );
    }
    if (approvalMode == ApprovalMode.fullAccess) return candidate;
    if (external) {
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
    return _truncate(_redact(await _edits.contentFor(resolved)));
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
    await _edits.stageWrite(
      requestedPath: requestedPath,
      resolvedPath: resolved,
      content: content,
    );
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
    final content = stageEdits
        ? await _edits.contentFor(resolved)
        : await file.readAsString();
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
    _edits.stageReplacement(
      requestedPath: requestedPath,
      resolvedPath: resolved,
      currentContent: content,
      proposedContent: content.replaceFirst(oldText, newText),
    );
    return '$requestedPath disiapkan untuk review; belum ditulis ke disk.';
  }

  Future<WorkspaceTurnChanges?> applyChanges({Set<String>? hunkIds}) =>
      _edits.apply(hunkIds: hunkIds);

  void rejectChanges() => _edits.reject();

  Future<void> revertLastTurn() => _edits.revertLastTurn();

  BrowserAutomation get _requiredBrowser {
    final value = browser;
    if (value == null) {
      throw StateError(
        'Browser agent tidak tersedia. Pastikan workspace dipercaya dan '
        'Build Mode aktif.',
      );
    }
    return value;
  }

  Future<String> _browserOpen(String rawUrl) async {
    final normalized = rawUrl.trim();
    await _requiredBrowser.openUrl(
      normalized,
      downloadDirectory: path.join(root, 'downloads'),
    );
    return 'Browser membuka $normalized.';
  }

  Future<String> _browserRead(int maxCharacters) async {
    final snapshot = await _requiredBrowser.readPage(
      maxCharacters: maxCharacters.clamp(1000, 30000),
    );
    return _truncate(snapshot.toToolText());
  }

  Future<String> _browserClick(String ref) async {
    final element = await _requiredBrowser.describeElement(ref);
    final dangerous = _isDangerousBrowserAction(element);
    if (dangerous) {
      final origin = _browserOrigin(_requiredBrowser.currentUrl);
      if (!await _approve(
        'Konfirmasi aksi browser berisiko',
        '${element.description}\n\nHalaman: ${_requiredBrowser.currentUrl}',
        pattern: 'browser:click:$origin:important-action',
        potentiallyUnsafe: true,
        requireExplicit: true,
      )) {
        return 'Ditolak oleh pengguna.';
      }
    }
    return _truncate(await _requiredBrowser.click(ref));
  }

  Future<String> _browserType(
    String ref,
    String text, {
    required bool clear,
    required bool submit,
  }) async {
    final element = await _requiredBrowser.describeElement(ref);
    final sensitive =
        element.type == 'password' || SecretScanner.containsSecret(text);
    final requireExplicit = sensitive || submit;
    final preview = SecretScanner.redact(
      text,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (requireExplicit) {
      final origin = _browserOrigin(_requiredBrowser.currentUrl);
      if (!await _approve(
        'Konfirmasi pengiriman data browser',
        '${element.description}\n'
            'Isi: ${preview.length > 160 ? '${preview.substring(0, 160)}…' : preview}\n'
            'Panjang: ${text.length} karakter'
            '${submit ? '\nForm akan dikirim atau Enter ditekan.' : ''}',
        pattern: 'browser:type:$origin:${sensitive ? 'sensitive' : 'submit'}',
        potentiallyUnsafe: true,
        requireExplicit: true,
      )) {
        return 'Ditolak oleh pengguna.';
      }
    }
    return _truncate(
      await _requiredBrowser.typeText(ref, text, clear: clear, submit: submit),
    );
  }

  Future<String> _browserUpload(String ref, List<String> requestedPaths) async {
    final resolved = <String>[];
    for (final requestedPath in requestedPaths) {
      resolved.add(await _resolveWorkspaceUpload(requestedPath));
    }
    final origin = _browserOrigin(_requiredBrowser.currentUrl);
    if (!await _approve(
      'Upload file workspace',
      'Tujuan: ${_requiredBrowser.currentUrl}\n'
          'Input: $ref\n'
          'File:\n${requestedPaths.map((item) => '- $item').join('\n')}',
      pattern: 'browser:upload:$origin',
      potentiallyUnsafe: true,
      requireExplicit: true,
    )) {
      return 'Ditolak oleh pengguna.';
    }
    return _truncate(await _requiredBrowser.uploadFiles(ref, resolved));
  }

  Future<String> _browserScreenshot({required bool fullPage}) async {
    final screenshotPath = await _requiredBrowser.takeScreenshot(
      path.join(root, 'screenshots'),
      fullPage: fullPage,
    );
    return 'Screenshot browser disimpan: $screenshotPath';
  }

  Future<String> _browserNavigate(String action) async {
    switch (action) {
      case 'back':
        await _requiredBrowser.goBack();
      case 'forward':
        await _requiredBrowser.goForward();
      case 'reload':
        await _requiredBrowser.reload();
      default:
        throw StateError('Navigasi browser tidak dikenal: $action');
    }
    return 'Navigasi browser "$action" dijalankan.';
  }

  Future<String> _resolveWorkspaceUpload(String requestedPath) async {
    final rootPath = path.normalize(path.absolute(root));
    final candidate = path.normalize(
      path.isAbsolute(requestedPath)
          ? requestedPath
          : path.join(rootPath, requestedPath),
    );
    if (!path.equals(candidate, rootPath) &&
        !path.isWithin(rootPath, candidate)) {
      throw FileSystemException(
        'Upload hanya diizinkan untuk file di dalam workspace.',
        requestedPath,
      );
    }
    final file = File(candidate);
    if (!await file.exists()) {
      throw FileSystemException('File upload tidak ditemukan.', requestedPath);
    }
    final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
    final canonicalFile = await file.resolveSymbolicLinks();
    if (!path.isWithin(canonicalRoot, canonicalFile)) {
      throw FileSystemException(
        'Symlink upload yang keluar workspace ditolak.',
        requestedPath,
      );
    }
    return canonicalFile;
  }

  bool _isDangerousBrowserAction(BrowserElementInfo element) {
    final value = '${element.text} ${element.type} ${element.href}'
        .toLowerCase();
    return RegExp(
      r'\b(delete|remove|erase|hapus|destroy|submit|send|kirim|publish|deploy|'
      r'purchase|buy|checkout|pay|bayar|transfer|login|log in|sign in|'
      r'authorize|approve|confirm|konfirmasi|uninstall|disconnect)\b',
    ).hasMatch(value);
  }

  String _browserOrigin(String rawUrl) {
    var value = rawUrl.trim();
    if (value.isEmpty) return 'current';
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return 'current';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port';
  }

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
    final policy = toolPermissionPolicies[pattern];
    if (policy == ToolPermissionPolicy.allow) return true;
    if (policy == ToolPermissionPolicy.deny) return false;
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
      toolPermissionPolicies[pattern] = ToolPermissionPolicy.allow;
      onToolPermissionChanged?.call(pattern, ToolPermissionPolicy.allow);
    }
    if (decision == PermissionDecision.rejectAlways) {
      _alwaysRejected.add(pattern);
      toolPermissionPolicies[pattern] = ToolPermissionPolicy.deny;
      onToolPermissionChanged?.call(pattern, ToolPermissionPolicy.deny);
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
