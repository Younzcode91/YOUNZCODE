import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/chat_entry.dart';
import 'models/chat_session.dart';
import 'models/addon.dart';
import 'models/workspace_change.dart';
import 'agent_working_palette.dart';
import 'editor_support.dart';
import 'lottie_support.dart';
import 'services/agent_service.dart';
import 'services/addon_service.dart';
import 'services/approval_mode.dart';
import 'services/provider_catalog.dart';
import 'services/chat_session_store.dart';
import 'services/debug_adapter_service.dart';
import 'services/settings_store.dart';
import 'services/mcp_client.dart';
import 'services/secret_scanner.dart';
import 'services/git_service.dart';
import 'services/workspace_trust_service.dart';
import 'services/persistent_terminal_service.dart';
import 'services/workspace_tools.dart';

const _fastMotion = Duration(milliseconds: 140);
const _mediumMotion = Duration(milliseconds: 240);
const _motionCurve = Curves.easeOutCubic;
const _appVersion = '1.0.1';

enum _AgentTurnState {
  idle,
  running,
  success,
  failed,
  cancelled,
  timedOut,
  paused,
}

enum _InspectorSection { activity, plan, files }

class _SlashCommand {
  const _SlashCommand(this.command, this.description, this.icon);

  final String command;
  final String description;
  final IconData icon;
}

const _slashCommands = <_SlashCommand>[
  _SlashCommand('/graphify', 'Update workspace knowledge graph', Icons.hub),
  _SlashCommand('/mcp', 'Manage MCP servers', Icons.device_hub),
  _SlashCommand('/review', 'Review pending or Git changes', Icons.rate_review),
  _SlashCommand('/fork', 'Fork the current chat', Icons.call_split),
  _SlashCommand('/model', 'Open model settings', Icons.psychology_outlined),
  _SlashCommand('/share', 'Copy the current chat transcript', Icons.share),
  _SlashCommand('/open', 'Open a workspace file', Icons.file_open_outlined),
  _SlashCommand('/skill', 'Manage installed skills', Icons.auto_awesome),
  _SlashCommand('/help', 'Show available commands', Icons.help_outline),
  _SlashCommand('/new', 'Start a new chat', Icons.add_comment_outlined),
  _SlashCommand(
    '/clear',
    'Clear prompt, context, and activity',
    Icons.clear_all,
  ),
  _SlashCommand('/terminal', 'Toggle integrated terminal', Icons.terminal),
  _SlashCommand('/explorer', 'Toggle Explorer panel', Icons.folder_outlined),
  _SlashCommand('/editor', 'Open the last editor or file picker', Icons.code),
  _SlashCommand('/settings', 'Open project settings', Icons.tune),
  _SlashCommand('/models', 'Open model settings', Icons.psychology_outlined),
  _SlashCommand('/history', 'Open chat history', Icons.history),
  _SlashCommand('/addons', 'Open Add-on Manager', Icons.extension_outlined),
  _SlashCommand('/search', 'Search the workspace', Icons.manage_search),
  _SlashCommand(
    '/notifications',
    'Open notifications',
    Icons.notifications_none,
  ),
  _SlashCommand('/plan', 'Enable Plan Mode', Icons.account_tree_outlined),
  _SlashCommand('/build', 'Enable Build Mode', Icons.build_outlined),
];

bool _isEnvironmentFileName(String name) =>
    name == '.env' || name.startsWith('.env.');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KodeAgentApp());
}

class KodeAgentApp extends StatefulWidget {
  const KodeAgentApp({super.key});

  @override
  State<KodeAgentApp> createState() => _KodeAgentAppState();
}

class _KodeAgentAppState extends State<KodeAgentApp> {
  bool _lightMode = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((preferences) {
      if (mounted) {
        setState(() => _lightMode = preferences.getBool('light_mode') ?? false);
      }
    });
  }

  Future<void> _toggleTheme() async {
    final lightMode = !_lightMode;
    setState(() => _lightMode = lightMode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('light_mode', lightMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'YOUNZCODE',
      theme: _buildTheme(light: true),
      darkTheme: _buildTheme(light: false),
      themeMode: _lightMode ? ThemeMode.light : ThemeMode.dark,
      home: AgentHomePage(lightMode: _lightMode, onToggleTheme: _toggleTheme),
    );
  }

  ThemeData _buildTheme({required bool light}) {
    final scheme = light
        ? const ColorScheme.light(
            primary: Color(0xFF4F378A),
            secondary: Color(0xFF63597C),
            tertiary: Color(0xFF765B00),
            surface: Color(0xFFFDF7FF),
            onSurface: Color(0xFF1D1B20),
            onSurfaceVariant: Color(0xFF494551),
            outline: Color(0xFF7A7582),
            error: Color(0xFFBA1A1A),
          )
        : const ColorScheme.dark(
            primary: Color(0xFFCFBCFF),
            secondary: Color(0xFFCDC0E9),
            tertiary: Color(0xFFE7C365),
            surface: Color(0xFF1D1B20),
            onSurface: Color(0xFFE6E1E5),
            onSurfaceVariant: Color(0xFFC9C5D0),
            outline: Color(0xFF938F99),
            error: Color(0xFFFFB4AB),
          );
    final border = light ? const Color(0xFFCBC4D2) : const Color(0xFF49454F);
    final input = light ? const Color(0xFFFFFFFF) : const Color(0xFF211F26);
    return ThemeData(
      brightness: light ? Brightness.light : Brightness.dark,
      scaffoldBackgroundColor: light
          ? const Color(0xFFFDF7FF)
          : const Color(0xFF141218),
      colorScheme: scheme,
      fontFamily: 'Inter',
      dividerColor: border,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14, height: 1.42),
        bodySmall: TextStyle(fontSize: 12, height: 1.34),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: input,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
          elevation: 2,
          animationDuration: _fastMotion,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          animationDuration: _fastMotion,
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? scheme.secondary.withValues(alpha: 0.2)
                : null,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          animationDuration: _fastMotion,
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? scheme.secondary.withValues(alpha: 0.2)
                : null,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          animationDuration: _fastMotion,
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? scheme.secondary.withValues(alpha: 0.25)
                : null,
          ),
        ),
      ),
      hoverColor: scheme.secondary.withValues(alpha: 0.08),
      splashFactory: InkRipple.splashFactory,
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: light ? const Color(0xFF322F35) : const Color(0xFF36343B),
          border: Border.all(color: border),
        ),
        textStyle: const TextStyle(fontSize: 11, color: Color(0xFFE2E4D5)),
      ),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    );
  }
}

class AgentHomePage extends StatefulWidget {
  const AgentHomePage({
    super.key,
    required this.lightMode,
    required this.onToggleTheme,
  });

  final bool lightMode;
  final VoidCallback onToggleTheme;

  @override
  State<AgentHomePage> createState() => _AgentHomePageState();
}

class _AgentHomePageState extends State<AgentHomePage> {
  final _promptController = TextEditingController();
  final _searchController = TextEditingController();
  final _environment = <String, String>{};
  final _apiHeaders = <String, String>{};
  final _scrollController = ScrollController();
  final _promptFocusNode = FocusNode();
  final _settingsStore = SettingsStore();
  final _chatSessionStore = ChatSessionStore();
  final _addonService = AddonService();
  final _gitService = const GitService();
  final _trustService = WorkspaceTrustService();
  final _entries = <ChatEntry>[];
  final _chatSessions = <ChatSession>[];
  final _addons = <Addon>[];
  final _activities = <_AgentActivity>[];
  final _agentCheckpoint = <Map<String, dynamic>>[];
  final _models = <String>['gpt-4.1-mini'];
  final _documents = <_OpenDocument>[];
  final _terminalController = TextEditingController();
  final _terminalScrollController = ScrollController();
  final _terminalOutput = <String>[];
  final _contextFiles = <String>[];
  final _changeHistory = <WorkspaceTurnChanges>[];
  final _notifications = <_AppNotification>[];
  // Bumped whenever _notifications changes so an open notifications dialog
  // rebuilds to show additions made while it is on screen.
  final _notificationRevision = ValueNotifier<int>(0);
  // Cumulative provider token spend for the active chat session.
  int _sessionTokens = 0;
  late final PersistentTerminalService _terminalService =
      PersistentTerminalService(
        onOutput: (output) {
          if (mounted) setState(() => _terminalOutput.add(output));
        },
      );

  String _baseUrl = 'https://api.openai.com/v1';
  String _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
  String _model = 'gpt-4.1-mini';
  String _apiKey = '';
  String _workspace = '';
  bool _busy = false;
  bool _loading = true;
  bool _searchMode = false;
  bool _searchBusy = false;
  bool _allowWrite = true;
  bool _allowTerminal = true;
  ApprovalMode _approvalMode = ApprovalMode.askForApproval;
  bool _providerVerified = false;
  bool _activityPanelVisible = true;
  bool _executionSummaryVisible = false;
  bool _explorerPanelVisible = true;
  bool _terminalVisible = false;
  bool _terminalBusy = false;
  bool _planMode = false;
  String? _activeFile;
  String _agentStatus = 'Siap menerima tugas';
  int _timeoutMs = 120000;
  List<String> _searchResults = [];
  AgentService? _agent;
  _AgentTurnState _turnState = _AgentTurnState.idle;
  _InspectorSection _inspectorSection = _InspectorSection.activity;
  WorkspaceTurnChanges? _pendingChanges;
  WorkspaceTurnChanges? _lastAppliedTurn;
  DateTime? _turnStartedAt;
  Duration _lastTurnDuration = Duration.zero;
  GitStatus _gitStatus = const GitStatus(isRepository: false);
  bool _workspaceTrusted = false;
  bool _onboardingShown = false;
  double _explorerWidth = 260;
  double _inspectorWidth = 260;
  Future<void> _persistenceQueue = Future.value();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final results = await Future.wait([
      _settingsStore.load().catchError(
        (_) => const AppSettings(
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-4.1-mini',
          workspace: '',
          models: ['gpt-4.1-mini'],
        ),
      ),
      _chatSessionStore.load().catchError((_) => <ChatSession>[]),
      _addonService
          .ensureBundledSkills(
            '$executableDirectory${Platform.pathSeparator}skills',
          )
          .catchError((_) => <Addon>[]),
    ]);
    final settings = results[0] as AppSettings;
    final sessions = results[1] as List<ChatSession>;
    final addons = results[2] as List<Addon>;
    var workspace = settings.workspace;
    if (workspace.isNotEmpty) {
      try {
        final directory = Directory(workspace);
        if (!await directory.exists()) {
          workspace = '';
        }
      } on FileSystemException {
        workspace = '';
      }
    }
    var trusted = false;
    try {
      trusted = await _trustService.isTrusted(workspace);
    } catch (_) {}
    if (!mounted) return;
    final workspaceSessions = sessions
        .where((session) => session.workspace == workspace)
        .toList();
    setState(() {
      _baseUrl = settings.baseUrl;
      _model = settings.model;
      _models
        ..clear()
        ..addAll(settings.models);
      _workspace = workspace;
      _allowWrite = settings.allowWrite;
      _allowTerminal = settings.allowTerminal;
      _approvalMode = settings.approvalMode;
      _timeoutMs = settings.timeoutMs;
      _chatSessions
        ..clear()
        ..addAll(sessions);
      _addons
        ..clear()
        ..addAll(addons);
      if (workspaceSessions.isNotEmpty) {
        _activeChatId = workspaceSessions.first.id;
        _entries
          ..clear()
          ..addAll(workspaceSessions.first.entries);
        _agentCheckpoint
          ..clear()
          ..addAll(workspaceSessions.first.agentMessages);
      }
      _loading = false;
      _workspaceTrusted = trusted;
    });
    if (workspace != settings.workspace) unawaited(_saveSettings());
    if (_entries.isNotEmpty) _scrollToBottom();
    unawaited(_refreshGit());
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!(preferences.getBool('onboarding_complete') ?? false) && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding());
      }
    } catch (_) {}
  }

  Future<void> _chooseWorkspace() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum mengganti workspace.');
      return;
    }
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pilih workspace proyek',
      initialDirectory: _workspace.isEmpty ? null : _workspace,
    );
    if (selected == null) return;
    if (!mounted) return;
    final trust = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: const Text('Trust Workspace?'),
        content: Text(
          '$selected\n\nRestricted Mode menonaktifkan write, terminal, add-on, dan MCP lokal.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('RESTRICTED MODE'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('TRUST WORKSPACE'),
          ),
        ],
      ),
    );
    await _trustService.setTrusted(selected, trust == true);
    await _persistActiveChat();
    await _agent?.dispose();
    await _terminalService.dispose();
    setState(() {
      for (final document in _documents) {
        document.dispose();
      }
      _documents.clear();
      _activeFile = null;
      _terminalOutput.clear();
      _workspace = selected;
      _workspaceTrusted = trust == true;
      _agent = null;
      _entries.clear();
      _agentCheckpoint.clear();
      final workspaceSessions =
          _chatSessions
              .where((session) => session.workspace == selected)
              .toList()
            ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      if (workspaceSessions.isNotEmpty) {
        _activeChatId = workspaceSessions.first.id;
        _entries.addAll(workspaceSessions.first.entries);
        _agentCheckpoint.addAll(workspaceSessions.first.agentMessages);
      } else {
        _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
      }
      _activities.clear();
      _turnState = _AgentTurnState.idle;
      _searchResults = [];
      _searchController.clear();
    });
    await _saveSettings();
    await _refreshGit();
    if (_entries.isNotEmpty) _scrollToBottom();
  }

  void _openSearch() {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum membuka pencarian.');
      return;
    }
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum melakukan pencarian.');
      return;
    }
    setState(() => _searchMode = true);
  }

  Future<void> _searchWorkspace() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searchBusy) return;
    setState(() {
      _searchBusy = true;
      _searchResults = [];
    });
    final searchedWorkspace = _workspace;
    try {
      final result = await Process.run('rg', [
        '--line-number',
        '--color',
        'never',
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
        '--',
        query,
      ], workingDirectory: searchedWorkspace);
      if (!mounted || searchedWorkspace != _workspace) return;
      if (result.exitCode != 0 && result.exitCode != 1) {
        throw ProcessException('rg', const [], '${result.stderr}');
      }
      setState(() {
        _searchResults = result.exitCode == 1
            ? []
            : '${result.stdout}'
                  .split(RegExp(r'\r?\n'))
                  .where((line) => line.isNotEmpty)
                  .take(500)
                  .toList();
      });
    } catch (error) {
      if (mounted) _showMessage('Pencarian gagal: $error');
    } finally {
      if (mounted) setState(() => _searchBusy = false);
    }
  }

  Future<void> _saveSettings() => _settingsStore.save(
    AppSettings(
      baseUrl: _baseUrl,
      model: _model,
      workspace: _workspace,
      allowWrite: _allowWrite,
      allowTerminal: _allowTerminal,
      approvalMode: _approvalMode,
      timeoutMs: _timeoutMs,
      models: _models,
    ),
  );

  AgentService _createAgent() {
    final ownerChatId = _activeChatId;
    final ownerWorkspace = _workspace;
    return AgentService(
      baseUrl: _baseUrl,
      apiKey: _apiKey,
      model: _model,
      workspace: _workspace,
      allowWrite: _workspaceTrusted && _allowWrite && !_planMode,
      allowTerminal: _workspaceTrusted && _allowTerminal && !_planMode,
      approvalMode: _approvalMode,
      environment: _environment,
      timeoutMs: _timeoutMs,
      headers: _apiHeaders,
      planMode: _planMode,
      addonInstructions: _enabledAddonInstructions(),
      mcpClients: _enabledMcpClients(),
      requestPermission: _requestPermission,
      onToolActivity: (id, name, detail, state) {
        if (!mounted) return;
        setState(() {
          final index = _activities.indexWhere((activity) => activity.id == id);
          final activity = _AgentActivity(
            id: id,
            name: name,
            detail: detail,
            state: state,
          );
          if (index < 0) {
            _activities.add(activity);
          } else {
            _activities[index] = activity;
          }
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        setState(() => _agentStatus = status);
        _scrollToBottom();
      },
      onCheckpoint: (messages) {
        if (ownerChatId != _activeChatId || ownerWorkspace != _workspace) {
          return;
        }
        _agentCheckpoint
          ..clear()
          ..addAll(_copyCheckpoint(messages));
        unawaited(
          _persistActiveChat(
            expectedChatId: ownerChatId,
            expectedWorkspace: ownerWorkspace,
          ),
        );
      },
      onChanges: (changes) {
        if (!mounted) return;
        setState(() {
          _pendingChanges = changes;
          if (changes != null) _inspectorSection = _InspectorSection.files;
        });
        _notify(
          'Agent finished',
          'Task completed in ${_lastTurnDuration.inSeconds}s.',
        );
      },
      onInsight: ({reasoning, promptTokens, completionTokens, totalTokens}) {
        if (!mounted) return;
        setState(() {
          if (totalTokens != null) _sessionTokens += totalTokens;
          final thought = reasoning?.trim() ?? '';
          if (thought.isNotEmpty) {
            final trimmed = thought.length > 600
                ? '${thought.substring(0, 600)}…'
                : thought;
            _activities.add(
              _AgentActivity(
                id: 'reasoning-${DateTime.now().microsecondsSinceEpoch}',
                name: 'reasoning',
                detail: trimmed,
                state: 'selesai',
              ),
            );
          }
        });
      },
    );
  }

  AgentService _ensureAgent() {
    final existing = _agent;
    if (existing != null) return existing;
    final agent = _createAgent();
    _agent = agent;
    if (_agentCheckpoint.isNotEmpty) {
      agent.restoreMessages(_agentCheckpoint);
    } else if (_entries.isNotEmpty) {
      agent.restore(_entries);
    }
    return agent;
  }

  List<String> _enabledAddonInstructions() {
    if (!_workspaceTrusted) return const [];
    final instructions = <String>[];
    for (final addon in _addons.where((addon) => addon.enabled)) {
      if (addon.kind == AddonKind.skill) {
        final metadata = addon.metadata as SkillMetadata;
        final base = FileSystemEntity.isDirectorySync(addon.installedPath)
            ? addon.installedPath
            : File(addon.installedPath).parent.path;
        final file = File('$base${Platform.pathSeparator}${metadata.fileName}');
        if (file.existsSync()) {
          instructions.add(
            '[SKILL: ${addon.name}]\n${file.readAsStringSync()}',
          );
        }
      } else if (addon.kind == AddonKind.nativePlugin) {
        final metadata = addon.metadata as NativePluginMetadata;
        final prompt =
            metadata.manifest['prompt'] ?? metadata.manifest['instructions'];
        if (prompt is String && prompt.trim().isNotEmpty) {
          instructions.add('[PLUGIN: ${addon.name}]\n$prompt');
        }
      }
    }
    return instructions;
  }

  List<McpClient> _enabledMcpClients() => _planMode || !_workspaceTrusted
      ? []
      : [
          for (final addon in _addons.where(
            (addon) => addon.enabled && addon.kind == AddonKind.mcpServer,
          ))
            for (final server in (addon.metadata as McpMetadata).servers)
              // Both stdio and Streamable HTTP transports are executable now.
              McpClient(server, workspace: _workspace),
        ];

  void _setPlanMode(bool value) {
    if (_busy || value == _planMode) return;
    unawaited(_agent?.dispose());
    setState(() {
      _planMode = value;
      _agent = null;
    });
  }

  Future<void> _disposeAgent() async {
    final agent = _agent;
    _agent = null;
    await agent?.dispose();
  }

  Future<void> _openAddonManager() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum mengelola add-on.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _AddonManagerDialog(
        addons: _addons,
        onImportFile: _importAddonFile,
        onImportFolder: _importAddonFolder,
        onToggle: _toggleAddon,
        onRemove: _removeAddon,
      ),
    );
  }

  Future<void> _importAddonFile() async {
    final selected = await FilePicker.platform.pickFiles(
      dialogTitle: 'Pilih skill, plugin, MCP config, atau VSIX',
      type: FileType.custom,
      allowedExtensions: ['md', 'json', 'vsix'],
    );
    final path = selected?.files.single.path;
    if (path != null) await _confirmAndImportAddon(path);
  }

  Future<void> _importAddonFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pilih folder add-on',
    );
    if (path != null) await _confirmAndImportAddon(path);
  }

  Future<void> _confirmAndImportAddon(String path) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import add-on lokal?'),
        content: Text(
          '$path\n\nFile akan disalin ke storage YOUNZCODE. Plugin dan VSIX tidak '
          'dieksekusi saat instalasi. MCP yang diaktifkan dapat menjalankan proses '
          'dengan izin pengguna Windows.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('BATAL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('IMPORT'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final addon = await _addonService.importLocal(path);
      if (!mounted) return;
      setState(() => _addons.add(addon));
      _showMessage('${addon.name} berhasil diimpor.');
      Navigator.of(context, rootNavigator: true).maybePop();
    } on AddonImportException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  Future<void> _toggleAddon(Addon addon, bool enabled) async {
    final updated = await _addonService.setEnabled(addon.id, enabled);
    unawaited(_agent?.dispose());
    if (!mounted) return;
    setState(() {
      final index = _addons.indexWhere((item) => item.id == addon.id);
      if (index != -1) _addons[index] = updated;
      _agent = null;
    });
  }

  Future<void> _removeAddon(Addon addon) async {
    await _addonService.remove(addon.id);
    unawaited(_agent?.dispose());
    if (!mounted) return;
    setState(() {
      _addons.removeWhere((item) => item.id == addon.id);
      _agent = null;
    });
  }

  Future<PermissionDecision> _requestPermission(
    String title,
    String detail,
  ) async {
    if (!mounted) return PermissionDecision.reject;
    final command = title.toLowerCase().contains('perintah');
    return await showDialog<PermissionDecision>(
          context: context,
          barrierDismissible: false,
          builder: (context) => command
              ? _TerminalPermissionDialog(detail: detail, workspace: _workspace)
              : _PermissionDialog(title: title, detail: detail),
        ) ??
        PermissionDecision.reject;
  }

  Future<void> _openSettings() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum mengubah pengaturan.');
      return;
    }
    final result = await showDialog<_ModelSettingsResult>(
      context: context,
      builder: (context) => _ModelDialog(
        baseUrl: _baseUrl,
        apiKey: _apiKey,
        models: _models,
        selectedModel: _model,
      ),
    );
    if (result == null) return;
    await _disposeAgent();
    final normalizedBaseUrl = normalizeProviderBaseUrl(result.baseUrl);
    final normalizedModels = {
      for (final model in result.models)
        normalizeProviderModel(model, baseUrl: normalizedBaseUrl),
    }.where((model) => model.isNotEmpty).toList();
    final normalizedSelectedModel = normalizeProviderModel(
      result.selectedModel,
      baseUrl: normalizedBaseUrl,
    );
    if (!normalizedModels.contains(normalizedSelectedModel)) {
      normalizedModels.insert(0, normalizedSelectedModel);
    }
    setState(() {
      _baseUrl = normalizedBaseUrl;
      _apiKey = result.apiKey;
      _models
        ..clear()
        ..addAll(normalizedModels);
      _model = normalizedSelectedModel;
      _providerVerified = false;
    });
    await _saveSettings();
  }

  Future<void> _selectModel(String model) async {
    final normalizedModel = normalizeProviderModel(model, baseUrl: _baseUrl);
    if (_busy || normalizedModel == _model) return;
    await _disposeAgent();
    setState(() {
      _model = normalizedModel;
      _providerVerified = false;
    });
    await _saveSettings();
  }

  Future<void> _openProjectSettings() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum mengubah pengaturan.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _ProjectSettingsDialog(
        workspace: _workspace,
        allowWrite: _allowWrite,
        allowTerminal: _allowTerminal,
        approvalMode: _approvalMode,
        environment: _environment,
        baseUrl: _baseUrl,
        model: _model,
        apiKey: _apiKey,
        timeoutMs: _timeoutMs,
        headers: _apiHeaders,
        onSave: (write, terminal, approvalMode, variables, api) async {
          await _disposeAgent();
          final normalizedBaseUrl = normalizeProviderBaseUrl(api.baseUrl);
          final normalizedModel = normalizeProviderModel(
            api.model,
            baseUrl: normalizedBaseUrl,
          );
          setState(() {
            _allowWrite = write;
            _allowTerminal = terminal;
            _approvalMode = approvalMode;
            _environment
              ..clear()
              ..addAll(variables);
            _baseUrl = normalizedBaseUrl;
            _model = normalizedModel;
            if (!_models.contains(normalizedModel)) {
              _models.add(normalizedModel);
            }
            _apiKey = api.apiKey;
            _providerVerified = false;
            _timeoutMs = api.timeoutMs;
            _apiHeaders
              ..clear()
              ..addAll(api.headers);
          });
          await _saveSettings();
        },
      ),
    );
  }

  Future<void> _send() async {
    final prompt = _promptController.text.trim();
    if (_busy || prompt.isEmpty) return;
    if (prompt.startsWith('/')) {
      _promptController.clear();
      await _runSlashCommand(prompt);
      return;
    }
    if (_workspace.isEmpty || !Directory(_workspace).existsSync()) {
      _showMessage('Pilih folder workspace yang valid terlebih dahulu.');
      return;
    }
    if (_apiKey.isEmpty) {
      await _openSettings();
      if (_apiKey.isEmpty) return;
    }
    if (!mounted) return;
    if (!_planMode && _gitStatus.mainBranch) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.account_tree_outlined),
          title: Text('Work directly on ${_gitStatus.branch}?'),
          content: const Text(
            'Agent akan bekerja pada branch utama. Branch fitur lebih aman untuk review dan rollback.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('CONTINUE'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    final promptWithContext = await _buildPromptWithContext(prompt);
    _promptController.clear();
    await _runAgentOperation(
      (agent) => agent.send(promptWithContext),
      userEntry: ChatEntry(role: ChatRole.user, content: prompt),
    );
  }

  Future<void> _runSlashCommand(String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    final command = parts.first.toLowerCase();
    final argument = parts.skip(1).join(' ').trim();
    switch (command) {
      case '/graphify':
        await _runGraphify(argument);
      case '/mcp':
        _showAddonSummary(AddonKind.mcpServer, argument);
      case '/review':
        await _openReview();
      case '/fork':
        await _forkChat();
      case '/model' || '/models':
        await _openSettings();
      case '/share':
        await _shareChat();
      case '/open':
        await _openFromCommand(argument);
      case '/skill':
        _showAddonSummary(AddonKind.skill, argument);
      case '/help':
        _addLocalResponse(
          'Slash commands:\n${_slashCommands.map((item) => '• ${item.command}  ${item.description}').join('\n')}',
        );
      case '/new':
        await _clearChat();
      case '/clear':
        setState(() {
          _promptController.clear();
          _contextFiles.clear();
          _activities.clear();
          _turnState = _AgentTurnState.idle;
        });
        _showMessage('Prompt, context, dan activity dibersihkan.');
      case '/terminal':
        await _toggleTerminal();
      case '/explorer':
        setState(() => _explorerPanelVisible = !_explorerPanelVisible);
      case '/editor':
        _showEditor();
      case '/settings':
        await _openProjectSettings();
      case '/history':
        await _openChatHistory();
      case '/addons':
        await _openAddonManager();
      case '/search':
        _openSearch();
      case '/notifications':
        await _showNotifications();
      case '/plan':
        _setPlanMode(true);
        _showMessage('Plan Mode diaktifkan.');
      case '/build':
        _setPlanMode(false);
        _showMessage('Build Mode diaktifkan.');
      default:
        _addLocalResponse(
          'Command "$command" tidak dikenal. Gunakan "/help" untuk melihat daftar command.',
          error: true,
        );
    }
  }

  Future<void> _runGraphify(String argument) async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum menjalankan Graphify.');
      return;
    }
    if (!_workspaceTrusted && !await _trustCurrentWorkspace()) return;
    setState(() => _terminalVisible = true);
    if (!_terminalService.running) {
      await _terminalService.start(
        workspace: _workspace,
        environment: _environment,
      );
    }
    final graphExists = File(
      '$_workspace${Platform.pathSeparator}graphify-out${Platform.pathSeparator}graph.json',
    ).existsSync();
    final normalizedArgument = argument.trim();
    final query = normalizedArgument.toLowerCase().startsWith('query ')
        ? normalizedArgument.substring(6).trim()
        : normalizedArgument;
    final command = normalizedArgument.isEmpty
        ? graphExists
              ? 'graphify update'
              : 'graphify .'
        : 'graphify query ${_powerShellQuote(query)}';
    _terminalOutput.add('> $command');
    try {
      final exitCode = await _terminalService.execute(command);
      if (mounted) {
        setState(() => _terminalOutput.add('[Graphify exited with $exitCode]'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _terminalOutput.add('[Graphify error: $error]'));
      }
    }
  }

  String _powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";

  void _showAddonSummary(AddonKind kind, String filter) {
    final matches = _addons.where(
      (addon) =>
          addon.kind == kind &&
          (filter.isEmpty ||
              addon.name.toLowerCase().contains(filter.toLowerCase())),
    );
    if (filter.isEmpty) {
      unawaited(_openAddonManager());
      return;
    }
    if (matches.isEmpty) {
      _addLocalResponse(
        'Tidak ada ${kind == AddonKind.skill ? 'skill' : 'MCP'} bernama "$filter". Gunakan "/addons" untuk mengimpor atau mengaktifkannya.',
        error: true,
      );
      return;
    }
    _addLocalResponse(
      matches
          .map(
            (addon) =>
                '${addon.enabled ? 'Aktif' : 'Nonaktif'}: ${addon.name}\n${addon.description}',
          )
          .join('\n\n'),
    );
  }

  Future<void> _openReview() async {
    if (_pendingChanges != null) {
      await _reviewChanges();
      return;
    }
    if (_gitStatus.isRepository) {
      await _showGitDetails();
      return;
    }
    _addLocalResponse(
      'Tidak ada perubahan agent atau repository Git untuk direview.',
    );
  }

  Future<void> _forkChat() async {
    if (_entries.isEmpty) {
      _addLocalResponse('Chat kosong belum dapat di-fork.', error: true);
      return;
    }
    await _persistActiveChat();
    if (!mounted) return;
    setState(() {
      _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
      _agent = null;
      _agentCheckpoint.clear();
      _activities.clear();
      _turnState = _AgentTurnState.idle;
    });
    await _persistActiveChat();
    _addLocalResponse(
      'Chat di-fork menjadi sesi baru. Riwayat pesan tetap dipertahankan.',
    );
  }

  Future<void> _shareChat() async {
    if (_entries.isEmpty) {
      _showMessage('Tidak ada percakapan untuk dibagikan.');
      return;
    }
    final transcript = _entries
        .map(
          (entry) =>
              '${entry.role == ChatRole.user
                  ? 'USER'
                  : entry.role == ChatRole.error
                  ? 'ERROR'
                  : 'AGENT'}\n${formatAgentResponse(entry.content)}',
        )
        .join('\n\n');
    await Clipboard.setData(ClipboardData(text: transcript));
    if (mounted) _showMessage('Percakapan disalin untuk dibagikan.');
  }

  Future<void> _openFromCommand(String argument) async {
    if (_workspace.isEmpty || !Directory(_workspace).existsSync()) {
      _showMessage('Pilih workspace sebelum membuka file.');
      return;
    }
    if (argument.isEmpty) {
      await _openFileSearch();
      return;
    }
    final file = File(argument).isAbsolute
        ? File(argument)
        : File('$_workspace${Platform.pathSeparator}$argument');
    await _openFile(file.path);
  }

  void _addLocalResponse(String content, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _entries.add(
        ChatEntry(
          role: error ? ChatRole.error : ChatRole.assistant,
          content: content,
        ),
      );
    });
    unawaited(_persistActiveChat());
    _scrollToBottom();
  }

  Future<void> _refreshGit() async {
    final workspace = _workspace;
    final status = await _gitService.status(workspace);
    if (mounted && workspace == _workspace) {
      setState(() => _gitStatus = status);
    }
  }

  Future<void> _showGitDetails() async {
    if (!_gitStatus.isRepository) {
      _showMessage('Workspace bukan repository Git.');
      return;
    }
    final results = await Future.wait([
      _gitService.diff(_workspace),
      _gitService.history(_workspace),
    ]);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _GitDialog(
        status: _gitStatus,
        diff: results[0],
        history: results[1],
        onCreateBranch: (name) async {
          await _gitService.createBranch(_workspace, name);
          await _refreshGit();
        },
      ),
    );
  }

  Future<void> _openFileSearch() async {
    if (_workspace.isEmpty) return;
    final result = await Process.run('rg', [
      '--files',
      '--glob',
      '!.git/**',
      '--glob',
      '!build/**',
    ], workingDirectory: _workspace);
    if (!mounted || result.exitCode != 0) return;
    final files = '${result.stdout}'
        .split(RegExp(r'\r?\n'))
        .where((line) => line.isNotEmpty)
        .toList();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _QuickFileDialog(files: files),
    );
    if (selected != null) {
      await _openFile('$_workspace${Platform.pathSeparator}$selected');
    }
  }

  Future<void> _openCommandPalette() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => const _CommandPaletteDialog(),
    );
    switch (action) {
      case 'file':
        await _openFileSearch();
      case 'chat':
        await _clearChat();
      case 'search':
        _openSearch();
      case 'terminal':
        _toggleTerminal();
      case 'settings':
        await _openProjectSettings();
      case 'model':
        await _openSettings();
      case 'plan':
        _setPlanMode(!_planMode);
    }
  }

  Future<String> _buildPromptWithContext(String prompt) async {
    if (_contextFiles.isEmpty) return prompt;
    final context = StringBuffer('$prompt\n\nATTACHED FILE CONTEXT:');
    for (final filePath in _contextFiles) {
      final safePath = await _trustService.resolveContainedFile(
        _workspace,
        filePath,
      );
      if (safePath == null) continue;
      final file = File(safePath);
      if (await file.length() > 1024 * 1024) continue;
      final revalidated = await _trustService.resolveContainedFile(
        _workspace,
        safePath,
      );
      if (revalidated == null || revalidated != safePath) continue;
      final relative = safePath.replaceAll('\\', '/').split('/').last;
      var content = await File(revalidated).readAsString();
      content = SecretScanner.redact(content);
      context.write('\n\n--- $relative ---\n$content');
    }
    return context.toString();
  }

  Future<void> _attachContext() async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum menambahkan context.');
      return;
    }
    final selection = await FilePicker.platform.pickFiles(
      dialogTitle: 'Attach files to agent context',
      initialDirectory: _workspace,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const [
        'dart',
        'py',
        'js',
        'ts',
        'tsx',
        'jsx',
        'json',
        'yaml',
        'yml',
        'toml',
        'md',
        'txt',
        'html',
        'css',
        'scss',
        'java',
        'kt',
        'go',
        'rs',
        'cpp',
        'h',
      ],
    );
    if (selection == null) return;
    final files = <String>[];
    for (final selected in selection.paths.whereType<String>()) {
      final safePath = await _trustService.resolveContainedFile(
        _workspace,
        selected,
      );
      if (safePath == null) continue;
      try {
        if (await File(safePath).length() <= 1024 * 1024) files.add(safePath);
      } on FileSystemException {
        continue;
      }
    }
    setState(() {
      for (final file in files) {
        if (!_contextFiles.contains(file)) _contextFiles.add(file);
      }
    });
  }

  Future<void> _continueFromCheckpoint() async {
    if (_busy || _agentCheckpoint.isEmpty) return;
    await _runAgentOperation((agent) => agent.continueFromCheckpoint());
  }

  Future<void> _runAgentOperation(
    Future<String> Function(AgentService agent) operation, {
    ChatEntry? userEntry,
  }) async {
    final agent = _ensureAgent();
    setState(() {
      _busy = true;
      _executionSummaryVisible = false;
      _turnState = _AgentTurnState.running;
      _agentStatus = 'Menyiapkan konteks';
      _activities.clear();
      _turnStartedAt = DateTime.now();
      if (userEntry != null) _entries.add(userEntry);
    });
    await _persistActiveChat();
    _scrollToBottom();
    try {
      late String answer;
      try {
        answer = await operation(agent);
      } catch (error) {
        final recovered = error is http.ClientException
            ? await _continueWithLocal9Router(error)
            : null;
        if (recovered == null) rethrow;
        answer = recovered;
      }
      if (!mounted) return;
      setState(() {
        _providerVerified = true;
        _turnState = _AgentTurnState.success;
        _entries.add(ChatEntry(role: ChatRole.assistant, content: answer));
      });
      await _persistActiveChat();
    } catch (error) {
      if (!mounted) return;
      final turnState = _turnStateForError(error);
      final message = _friendlyAgentError(error);
      setState(() {
        _turnState = turnState;
        _entries.add(
          ChatEntry(
            role: turnState == _AgentTurnState.paused
                ? ChatRole.assistant
                : ChatRole.error,
            content: message,
          ),
        );
      });
      await _persistActiveChat();
      if (turnState == _AgentTurnState.cancelled) {
        _agent = null;
      } else if (error is AgentTurnTimeoutException) {
        if (identical(_agent, agent)) _agent = null;
        await agent.dispose();
      } else if (turnState != _AgentTurnState.paused) {
        await _showConnectionError(message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _agentStatus = 'Siap menerima tugas';
          _lastTurnDuration = _turnStartedAt == null
              ? Duration.zero
              : DateTime.now().difference(_turnStartedAt!);
        });
      }
      _scrollToBottom();
    }
  }

  void _notify(String title, String body, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notifications.insert(
        0,
        _AppNotification(
          title: title,
          body: body,
          createdAt: DateTime.now(),
          error: error,
        ),
      );
    });
    _notificationRevision.value++;
  }

  Future<void> _showNotifications() => showDialog<void>(
    context: context,
    builder: (context) => _NotificationDialog(
      notifications: _notifications,
      revision: _notificationRevision,
      onDelete: (notification) {
        if (mounted) setState(() => _notifications.remove(notification));
        _notificationRevision.value++;
      },
      onClear: () {
        if (mounted) setState(_notifications.clear);
        _notificationRevision.value++;
      },
    ),
  );

  Future<void> _showOnboarding() async {
    if (_onboardingShown || !mounted) return;
    _onboardingShown = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _OnboardingDialog(
        workspaceConfigured: _workspace.isNotEmpty,
        providerConfigured: _apiKey.isNotEmpty,
        model: _model,
        onWorkspace: _chooseWorkspace,
        onProvider: _openSettings,
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('onboarding_complete', true);
  }

  Future<void> _reviewChanges() async {
    final changes = _pendingChanges;
    final agent = _agent;
    if (changes == null || agent == null || !mounted) return;
    final accepted = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ChangesReviewDialog(changes: changes),
    );
    if (accepted == null) return;
    if (accepted.isEmpty) {
      agent.rejectPendingChanges();
      setState(() => _pendingChanges = null);
      _showMessage('Semua perubahan agent ditolak.');
      return;
    }
    final applied = await agent.applyPendingChanges(hunkIds: accepted);
    if (!mounted || applied == null) return;
    setState(() {
      _lastAppliedTurn = applied;
      _changeHistory.insert(0, applied);
      _pendingChanges = null;
    });
    await _reloadChangedDocuments(applied.files);
    _showMessage('${applied.files.length} file diterapkan.');
  }

  Future<void> _revertTurn() async {
    final agent = _agent;
    final turn = _lastAppliedTurn;
    if (agent == null || turn == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revert agent turn?'),
        content: Text(
          'Pulihkan ${turn.files.length} file ke kondisi sebelum prompt ini?\n\n'
          '${turn.prompt}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('REVERT TURN'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await agent.revertLastTurn();
    if (!mounted) return;
    setState(() => _lastAppliedTurn = null);
    await _reloadChangedDocuments(turn.files);
    _showMessage('Perubahan turn dipulihkan.');
  }

  Future<void> _reloadChangedDocuments(
    List<WorkspaceFileChange> changes,
  ) async {
    var keptUnsaved = false;
    for (final change in changes) {
      final normalized = File(
        '$_workspace${Platform.pathSeparator}${change.path}',
      ).path;
      final matching = _documents.where(
        (document) =>
            document.path == normalized || document.path == change.path,
      );
      for (final document in matching) {
        // Don't overwrite the user's unsaved edits with the on-disk version.
        if (document.controller.text != document.savedContent) {
          keptUnsaved = true;
          continue;
        }
        final file = File(document.path);
        final content = await file.exists() ? await file.readAsString() : '';
        document.controller.text = content;
        document.savedContent = content;
      }
    }
    if (mounted) setState(() {});
    if (keptUnsaved) {
      _showMessage(
        'Beberapa file terbuka punya perubahan belum disimpan dan tidak '
        'dimuat ulang otomatis.',
      );
    }
  }

  Future<String?> _continueWithLocal9Router(http.ClientException error) async {
    const localBaseUrl = 'http://127.0.0.1:20128/v1';
    if (normalizeProviderBaseUrl(_baseUrl) == localBaseUrl) {
      throw AgentHttpException(
        '9router lokal memutus koneksi saat memproses request: '
        '${error.message}. Pastikan provider di dashboard 9router sudah '
        'terhubung dan API key dari dashboard digunakan di MODEL SETTINGS.',
      );
    }

    if (!mounted) return null;
    setState(() => _agentStatus = 'Mencari provider 9router lokal');
    try {
      final response = await http
          .get(
            Uri.parse('$localBaseUrl/models'),
            headers: {
              ..._apiHeaders,
              if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      await _disposeAgent();
      if (!mounted) return null;
      setState(() {
        _baseUrl = localBaseUrl;
        _providerVerified = true;
        _agentStatus = '9router lokal ditemukan, melanjutkan checkpoint';
      });
      await _saveSettings();
      final recoveredAgent = _ensureAgent();
      try {
        return await recoveredAgent.continueFromCheckpoint();
      } on AgentHttpException catch (error) {
        if (error.statusCode == 401 || error.statusCode == 403) {
          throw AgentHttpException(
            '9router lokal menolak API key. Buka MODEL SETTINGS dan masukkan '
            'API key 9router yang valid.',
            statusCode: error.statusCode,
          );
        }
        rethrow;
      }
    } on AgentHttpException {
      rethrow;
    } on http.ClientException catch (localError) {
      throw AgentHttpException(
        '9router lokal memutus koneksi saat melanjutkan checkpoint: '
        '${localError.message}. Pastikan provider di dashboard 9router '
        'sudah terhubung dan API key dari dashboard digunakan di MODEL SETTINGS.',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _cancelAgent() async {
    if (!_busy) return;
    final agent = _agent;
    _agent = null;
    setState(() => _agentStatus = 'Membatalkan request dan proses aktif');
    await agent?.cancel();
  }

  _AgentTurnState _turnStateForError(Object error) {
    if (error is AgentCancelledException) return _AgentTurnState.cancelled;
    if (error is AgentStepLimitException) return _AgentTurnState.paused;
    if (error is TimeoutException) return _AgentTurnState.timedOut;
    if (error is AgentHttpException &&
        {408, 504, 522, 524}.contains(error.statusCode)) {
      return _AgentTurnState.timedOut;
    }
    return _AgentTurnState.failed;
  }

  String _friendlyAgentError(Object error) {
    if (error is AgentCancelledException) {
      return 'Tugas dibatalkan. Checkpoint dan hasil tool yang sudah selesai '
          'tetap disimpan.';
    }
    if (error is AgentStepLimitException) return '$error';
    if (error is AgentTurnTimeoutException) {
      return '${error.message} Proses yang masih aktif telah dihentikan. '
          'Checkpoint dan hasil tool yang sudah selesai tetap tersimpan; '
          'gunakan CONTINUE FROM CHECKPOINT bila ingin melanjutkan.';
    }
    if (error is TimeoutException) {
      final detail = error.message?.trim();
      return '${detail == null || detail.isEmpty ? 'Operasi melewati batas waktu.' : detail} '
          'Checkpoint tersimpan dan dapat dilanjutkan. Jika operasi memang '
          'memerlukan waktu lebih lama, naikkan DEFAULT TIMEOUT (MS) di '
          'PROJECT SETTINGS > API.';
    }
    if (error is AgentHttpException && error.statusCode == 524) {
      return 'Gateway API model mengalami timeout (HTTP 524). Checkpoint '
          'tersimpan; gunakan CONTINUE FROM CHECKPOINT setelah koneksi pulih.';
    }
    if (error is AgentHttpException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      return 'Autentikasi provider ditolak (HTTP ${error.statusCode}). Buka '
          'MODEL SETTINGS dan masukkan API key yang valid. Checkpoint tetap '
          'tersimpan dan dapat dilanjutkan setelah key diperbaiki.';
    }
    if (error is http.ClientException) {
      return 'Koneksi streaming ke provider terputus setelah beberapa kali '
          'percobaan. Checkpoint tetap tersimpan. Provider 9router lokal juga '
          'tidak dapat digunakan untuk melanjutkan otomatis.';
    }
    return '$error';
  }

  Future<void> _clearChat() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum memulai chat baru.');
      return;
    }
    await _persistActiveChat();
    setState(() {
      _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
      _entries.clear();
      _activities.clear();
      _agentCheckpoint.clear();
      _turnState = _AgentTurnState.idle;
      _agent?.clear();
      _searchMode = false;
    });
  }

  Future<void> _persistActiveChat({
    String? expectedChatId,
    String? expectedWorkspace,
  }) async {
    if (_entries.isEmpty) return;
    final chatId = _activeChatId;
    final workspace = _workspace;
    if ((expectedChatId != null && expectedChatId != chatId) ||
        (expectedWorkspace != null && expectedWorkspace != workspace)) {
      return;
    }
    final session = ChatSession(
      id: chatId,
      workspace: workspace,
      updatedAt: DateTime.now(),
      entries: List.unmodifiable(_entries),
      agentMessages: List.unmodifiable(_copyCheckpoint(_agentCheckpoint)),
    );
    final index = _chatSessions.indexWhere((item) => item.id == chatId);
    if (index == -1) {
      _chatSessions.add(session);
    } else {
      _chatSessions[index] = session;
    }
    _chatSessions.sort(
      (left, right) => right.updatedAt.compareTo(left.updatedAt),
    );
    final sessionsSnapshot = List<ChatSession>.unmodifiable(_chatSessions);
    final save = _persistenceQueue.then(
      (_) => _chatSessionStore.save(sessionsSnapshot),
    );
    _persistenceQueue = save.catchError((_) {});
    await save;
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> _copyCheckpoint(
    List<Map<String, dynamic>> messages,
  ) => (jsonDecode(jsonEncode(messages)) as List)
      .map((message) => Map<String, dynamic>.from(message as Map))
      .toList(growable: false);

  Future<void> _openChatHistory() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum membuka riwayat.');
      return;
    }
    await _persistActiveChat();
    if (!mounted) return;
    final sessions = _chatSessions
        .where((session) => session.workspace == _workspace)
        .toList();
    await showDialog<void>(
      context: context,
      builder: (context) => _ChatHistoryDialog(
        sessions: sessions,
        activeId: _activeChatId,
        onOpen: (session) {
          Navigator.pop(context);
          _restoreChatSession(session);
        },
        onDelete: (session) async {
          setState(() {
            _chatSessions.removeWhere((item) => item.id == session.id);
            if (session.id == _activeChatId) {
              _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
              _entries.clear();
              _activities.clear();
              _agentCheckpoint.clear();
              _turnState = _AgentTurnState.idle;
              _agent?.clear();
            }
          });
          await _chatSessionStore.save(_chatSessions);
          if (context.mounted) Navigator.pop(context);
        },
      ),
    );
  }

  void _restoreChatSession(ChatSession session) {
    // Dispose the agent being replaced so its http client and MCP child
    // processes are not leaked each time a session is restored.
    unawaited(_agent?.dispose());
    setState(() {
      _activeChatId = session.id;
      _sessionTokens = 0;
      _entries
        ..clear()
        ..addAll(session.entries);
      _agentCheckpoint
        ..clear()
        ..addAll(session.agentMessages);
      _activities.clear();
      _turnState = _AgentTurnState.idle;
      _searchMode = false;
      _activeFile = null;
      _agent = _createAgent();
      if (session.agentMessages.isNotEmpty) {
        _agent!.restoreMessages(session.agentMessages);
      } else {
        _agent!.restore(session.entries);
      }
    });
    _scrollToBottom();
  }

  Future<void> _showConnectionError(String detail) async {
    if (!mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => _ConnectionErrorDialog(detail: detail),
    );
    if (openSettings == true && mounted) await _openSettings();
  }

  void _useSuggestion(String prompt) {
    _promptController.text = prompt;
    _promptController.selection = TextSelection.collapsed(
      offset: _promptController.text.length,
    );
    _promptFocusNode.requestFocus();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openFile(String filePath) async {
    final existingIndex = _documents.indexWhere(
      (item) => item.path == filePath,
    );
    if (existingIndex != -1) {
      setState(() {
        _activeFile = filePath;
        _searchMode = false;
      });
      return;
    }
    final normalized = filePath.replaceAll('\\', '/').toLowerCase();
    final name = normalized.split('/').last;
    if ({'id_rsa', 'id_ed25519'}.contains(name) ||
        normalized.contains('/.ssh/')) {
      _showMessage('File sensitif tidak dapat dibuka di editor.');
      return;
    }
    if (_isEnvironmentFileName(name)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Buka file environment?'),
          content: const Text(
            'File ini mungkin berisi API key, token, atau password. Isinya '
            'hanya dibuka di editor lokal dan tetap tidak dapat diakses oleh '
            'agent AI.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('BATAL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('BUKA LOKAL'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    } else if ({'.npmrc', '.pypirc'}.contains(name)) {
      _showMessage('File kredensial tidak dapat dibuka di editor.');
      return;
    }
    try {
      final file = File(filePath);
      if (await file.length() > 2 * 1024 * 1024) {
        _showMessage('File lebih besar dari 2 MB dan tidak dibuka.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) {
        _showMessage('File biner tidak dapat dibuka di editor teks.');
        return;
      }
      final content = utf8.decode(bytes);
      if (!mounted) return;
      late final _OpenDocument document;
      document = _OpenDocument(path: filePath, content: content);
      document.controller.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() {
        _documents.add(document);
        _activeFile = filePath;
        _searchMode = false;
      });
    } catch (error) {
      _showMessage('File tidak dapat dibuka: $error');
    }
  }

  Future<void> _saveDocument(_OpenDocument document) async {
    try {
      await File(document.path).writeAsString(document.controller.text);
      if (!mounted) return;
      setState(() => document.savedContent = document.controller.text);
      _showMessage('${document.name} disimpan.');
    } catch (error) {
      _showMessage('Gagal menyimpan file: $error');
    }
  }

  Future<void> _closeDocument(_OpenDocument document) async {
    if (document.dirty) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Perubahan belum disimpan'),
          content: Text('Tutup ${document.name} tanpa menyimpan perubahan?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('DISCARD'),
            ),
          ],
        ),
      );
      if (close != true) return;
    }
    final index = _documents.indexOf(document);
    setState(() {
      _documents.remove(document);
      if (_activeFile == document.path) {
        _activeFile = _documents.isEmpty
            ? null
            : _documents[index.clamp(0, _documents.length - 1)].path;
      }
    });
    document.dispose();
  }

  void _showChat() => setState(() {
    _activeFile = null;
    _searchMode = false;
  });

  void _showEditor() {
    if (_documents.isNotEmpty) {
      setState(() {
        _activeFile = _documents.last.path;
        _searchMode = false;
      });
      return;
    }
    unawaited(_openFileSearch());
  }

  Future<bool> _trustCurrentWorkspace() async {
    if (_workspace.isEmpty || _workspaceTrusted) return _workspaceTrusted;
    final trusted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: const Text('Trust Workspace?'),
        content: Text(
          '$_workspace\n\nTrusting this workspace enables file changes, '
          'PowerShell terminal access, local add-ons, and MCP servers. '
          'Commands run with your normal Windows account permissions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('KEEP RESTRICTED'),
          ),
          FilledButton(
            key: const ValueKey('trust-current-workspace'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('TRUST WORKSPACE'),
          ),
        ],
      ),
    );
    if (trusted != true) return false;
    await _trustService.setTrusted(_workspace, true);
    if (!mounted) return false;
    setState(() => _workspaceTrusted = true);
    _notify(
      'Workspace trusted',
      'Terminal, file changes, local add-ons, and MCP tools are enabled.',
    );
    _showMessage('Workspace dipercaya. Terminal dan tool lokal diaktifkan.');
    return true;
  }

  Future<void> _toggleTerminal() async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum membuka terminal.');
      return;
    }
    if (!_workspaceTrusted && !await _trustCurrentWorkspace()) return;
    setState(() => _terminalVisible = !_terminalVisible);
    if (_terminalVisible && !_terminalService.running) {
      unawaited(
        _terminalService
            .start(workspace: _workspace, environment: _environment)
            .catchError(
              (error) => _showMessage('Terminal gagal dimulai: $error'),
            ),
      );
    }
  }

  Future<void> _runTerminalCommand() async {
    final command = _terminalController.text.trim();
    if (command.isEmpty || _terminalBusy) return;
    _terminalController.clear();
    if (command.toLowerCase() == 'clear' || command.toLowerCase() == 'cls') {
      setState(() => _terminalOutput.clear());
      return;
    }
    setState(() {
      _terminalBusy = true;
      _terminalOutput.add('PS $_workspace> $command');
    });
    try {
      if (!_terminalService.running) {
        await _terminalService.start(
          workspace: _workspace,
          environment: _environment,
        );
      }
      final exitCode = await _terminalService.execute(command);
      if (mounted) {
        setState(() {
          _terminalOutput.add('[exit $exitCode]');
          _terminalOutput.add('');
        });
      }
    } catch (error) {
      if (mounted) setState(() => _terminalOutput.add('Error: $error\n'));
    } finally {
      if (mounted) setState(() => _terminalBusy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_terminalScrollController.hasClients) {
          _terminalScrollController.jumpTo(
            _terminalScrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _promptFocusNode.dispose();
    _terminalController.dispose();
    _terminalScrollController.dispose();
    _notificationRevision.dispose();
    unawaited(_terminalService.dispose());
    unawaited(_agent?.dispose());
    for (final document in _documents) {
      document.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
          shift: true,
        ): _openCommandPalette,
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            _openFileSearch,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): _openSearch,
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showRail = constraints.maxWidth >= 760;
              final explorerAvailable = constraints.maxWidth >= 900;
              final showExplorer = explorerAvailable && _explorerPanelVisible;
              final showInspector = constraints.maxWidth >= 1150;
              final availableWidth = constraints.maxWidth - (showRail ? 72 : 0);
              final inspectorWidth = _inspectorWidth
                  .clamp(220.0, math.max(220.0, availableWidth - 580))
                  .toDouble();
              final explorerWidth = _explorerWidth
                  .clamp(
                    220.0,
                    math.max(
                      220.0,
                      availableWidth -
                          (showInspector && _activityPanelVisible
                              ? inspectorWidth + 6
                              : 0) -
                          360,
                    ),
                  )
                  .toDouble();
              return Row(
                children: [
                  if (showRail)
                    _CommandRail(
                      onNewChat: _clearChat,
                      onChat: _showChat,
                      onFiles: _chooseWorkspace,
                      onSearch: _openSearch,
                      onHistory: _openChatHistory,
                      onAddons: _openAddonManager,
                      onTerminal: _toggleTerminal,
                      onSettings: _openProjectSettings,
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        _TopWorkspaceBar(
                          activeFile: _activeFile,
                          searchMode: _searchMode,
                          terminalVisible: _terminalVisible,
                          inspectorVisible:
                              showInspector && _activityPanelVisible,
                          lightMode: widget.lightMode,
                          onExplorer: () => setState(() {
                            _explorerPanelVisible = true;
                            _activeFile = null;
                            _searchMode = false;
                          }),
                          onEditor: _workspace.isEmpty ? null : _showEditor,
                          onTerminal: _toggleTerminal,
                          onInspector: () => setState(
                            () =>
                                _activityPanelVisible = !_activityPanelVisible,
                          ),
                          onToggleTheme: widget.onToggleTheme,
                          onNotifications: _showNotifications,
                          notificationCount: _notifications.length,
                        ),
                        Expanded(
                          child: Row(
                            children: [
                              if (showExplorer)
                                SizedBox(
                                  width: explorerWidth,
                                  child: _ProjectPanel(
                                    workspace: _workspace,
                                    onOpenFile: _openFile,
                                    onChoose: _chooseWorkspace,
                                    onNewChat: _clearChat,
                                    onChat: _showChat,
                                    onTerminal: _toggleTerminal,
                                    onSettings: _openProjectSettings,
                                    onSearch: _openSearch,
                                    onHistory: _openChatHistory,
                                    onAddons: _openAddonManager,
                                    onHide: () => setState(
                                      () => _explorerPanelVisible = false,
                                    ),
                                  ),
                                ),
                              if (showExplorer)
                                _PanelResizeHandle(
                                  key: const ValueKey('explorer-resize-handle'),
                                  onDrag: (delta) => setState(
                                    () => _explorerWidth =
                                        (_explorerWidth + delta).clamp(
                                          220.0,
                                          480.0,
                                        ),
                                  ),
                                ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: AnimatedSwitcher(
                                        duration: _mediumMotion,
                                        child: _searchMode
                                            ? _SearchView(
                                                key: const ValueKey('search'),
                                                controller: _searchController,
                                                results: _searchResults,
                                                busy: _searchBusy,
                                                onSearch: _searchWorkspace,
                                                onClose: () => setState(
                                                  () => _searchMode = false,
                                                ),
                                                onOpenResult: (path, _) =>
                                                    _openFile(
                                                      '$_workspace${Platform.pathSeparator}$path',
                                                    ),
                                              )
                                            : _activeFile != null
                                            ? _WorkspaceEditor(
                                                key: const ValueKey('editor'),
                                                documents: _documents,
                                                activePath: _activeFile!,
                                                onSelect: (path) => setState(
                                                  () => _activeFile = path,
                                                ),
                                                onClose: _closeDocument,
                                                onSave: _saveDocument,
                                                onShowChat: _showChat,
                                                workspace: _workspace,
                                                trusted: _workspaceTrusted,
                                              )
                                            : KeyedSubtree(
                                                key: const ValueKey(
                                                  'conversation',
                                                ),
                                                child: _buildConversation(
                                                  !showExplorer,
                                                ),
                                              ),
                                      ),
                                    ),
                                    if (_terminalVisible)
                                      SizedBox(
                                        height: 230,
                                        child: _IntegratedTerminal(
                                          controller: _terminalController,
                                          scrollController:
                                              _terminalScrollController,
                                          output: _terminalOutput,
                                          busy: _terminalBusy,
                                          workspace: _workspace,
                                          onRun: _runTerminalCommand,
                                          onClose: _toggleTerminal,
                                          onClear: () => setState(
                                            () => _terminalOutput.clear(),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (showInspector && _activityPanelVisible) ...[
                                _PanelResizeHandle(
                                  key: const ValueKey(
                                    'inspector-resize-handle',
                                  ),
                                  onDrag: (delta) => setState(
                                    () => _inspectorWidth =
                                        (_inspectorWidth - delta).clamp(
                                          220.0,
                                          480.0,
                                        ),
                                  ),
                                ),
                                SizedBox(
                                  width: inspectorWidth,
                                  child: _ActivityPanel(
                                    key: const ValueKey('activity-panel'),
                                    activities: _activities,
                                    busy: _busy,
                                    status: _agentStatus,
                                    onHide: () => setState(
                                      () => _activityPanelVisible = false,
                                    ),
                                    section: _inspectorSection,
                                    onSectionChanged: (section) => setState(
                                      () => _inspectorSection = section,
                                    ),
                                    pendingChanges: _pendingChanges,
                                    changeHistory: _changeHistory,
                                    onReviewChanges: _reviewChanges,
                                    onRevert: _lastAppliedTurn == null
                                        ? null
                                        : _revertTurn,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _StatusBar(
                          connected: _providerVerified,
                          configured: _apiKey.isNotEmpty,
                          busy: _busy,
                          model: _model,
                          status: _agentStatus,
                          tokens: _sessionTokens,
                          gitStatus: _gitStatus,
                          onGit: _showGitDetails,
                          workspaceTrusted: _workspaceTrusted,
                          onTrustWorkspace: _trustCurrentWorkspace,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildConversation(bool compact) {
    return Column(
      children: [
        if (compact)
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(
                _workspace.isEmpty ? 'Pilih workspace' : _workspace,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _chooseWorkspace,
              trailing: PopupMenuButton<String>(
                tooltip: 'Menu workspace',
                onSelected: (value) {
                  if (value == 'search') _openSearch();
                  if (value == 'settings') _openProjectSettings();
                  if (value == 'new') _clearChat();
                  if (value == 'history') _openChatHistory();
                  if (value == 'addons') _openAddonManager();
                  if (value == 'terminal') _toggleTerminal();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'search',
                    child: Text('Search workspace'),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Text('Project settings'),
                  ),
                  PopupMenuItem(value: 'new', child: Text('New chat')),
                  PopupMenuItem(value: 'history', child: Text('Chat history')),
                  PopupMenuItem(value: 'addons', child: Text('Add-ons')),
                  PopupMenuItem(value: 'terminal', child: Text('Terminal')),
                ],
              ),
            ),
          ),
        Expanded(
          child: _entries.isEmpty && !_busy
              ? _EmptyState(onSuggestion: _useSuggestion)
              : ListView.builder(
                  key: const ValueKey('conversation-list'),
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
                  itemCount:
                      _entries.length +
                      (_busy ||
                              _activities.isNotEmpty ||
                              _turnState != _AgentTurnState.idle
                          ? 1
                          : 0),
                  itemBuilder: (context, index) {
                    final showExecution =
                        _busy ||
                        _activities.isNotEmpty ||
                        _turnState != _AgentTurnState.idle;
                    if (showExecution && index == 0) {
                      return _busy
                          ? _AgentWorkingCard(
                              status: _agentStatus,
                              activities: _activities,
                            )
                          : _executionSummaryVisible
                          ? _ExecutionSummary(
                              activities: _activities,
                              turnState: _turnState,
                              onRetry: _agentCheckpoint.isEmpty
                                  ? null
                                  : _continueFromCheckpoint,
                              duration: _lastTurnDuration,
                              pendingChanges: _pendingChanges,
                              canRevert: _lastAppliedTurn != null,
                              onReviewChanges: _pendingChanges == null
                                  ? null
                                  : _reviewChanges,
                              onRevert: _lastAppliedTurn == null
                                  ? null
                                  : _revertTurn,
                              onHide: () => setState(
                                () => _executionSummaryVisible = false,
                              ),
                            )
                          : _ExecutionSummaryToggle(
                              turnState: _turnState,
                              duration: _lastTurnDuration,
                              onShow: () => setState(
                                () => _executionSummaryVisible = true,
                              ),
                            );
                    }
                    final entryIndex =
                        _entries.length - 1 - index + (showExecution ? 1 : 0);
                    return _MessageCard(
                      key: ValueKey(_entries[entryIndex]),
                      entry: _entries[entryIndex],
                    );
                  },
                ),
        ),
        _ModelBar(
          models: _models,
          selectedModel: _model,
          busy: _busy,
          planMode: _planMode,
          onSelected: _selectModel,
          onManage: _openSettings,
          onPlanModeChanged: _setPlanMode,
        ),
        _Composer(
          controller: _promptController,
          focusNode: _promptFocusNode,
          busy: _busy,
          onSend: _send,
          onStop: () => unawaited(_cancelAgent()),
          planMode: _planMode,
          onPlanModeChanged: _setPlanMode,
          contextFiles: _contextFiles,
          onAttachContext: _attachContext,
          onRemoveContext: (file) => setState(() => _contextFiles.remove(file)),
          onClearContext: () => setState(() => _contextFiles.clear()),
          slashCommands: _slashCommands,
          onSlashCommand: _runSlashCommand,
        ),
      ],
    );
  }
}

class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: AnimatedContainer(
              duration: _fastMotion,
              width: _hovered ? 3 : 1,
              color: _hovered ? colors.primary : Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandRail extends StatelessWidget {
  const _CommandRail({
    required this.onNewChat,
    required this.onChat,
    required this.onFiles,
    required this.onSearch,
    required this.onHistory,
    required this.onAddons,
    required this.onTerminal,
    required this.onSettings,
  });

  final VoidCallback onNewChat;
  final VoidCallback onChat;
  final VoidCallback onFiles;
  final VoidCallback onSearch;
  final VoidCallback onHistory;
  final VoidCallback onAddons;
  final VoidCallback onTerminal;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 560;
    return Container(
      key: const ValueKey('command-rail'),
      width: 72,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          SizedBox(height: compact ? 6 : 16),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(2)),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/younzcode_logo_new.png',
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'v$_appVersion',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: compact ? 5 : 22),
          _RailAction(
            icon: Icons.add_comment_outlined,
            label: 'NEW CHAT',
            onTap: onNewChat,
          ),
          _RailAction(
            icon: Icons.chat_bubble_outline,
            label: 'CHAT',
            selected: true,
            onTap: onChat,
          ),
          _RailAction(
            icon: Icons.folder_outlined,
            label: 'FILES',
            onTap: onFiles,
          ),
          _RailAction(icon: Icons.search, label: 'SEARCH', onTap: onSearch),
          _RailAction(icon: Icons.history, label: 'HISTORY', onTap: onHistory),
          _RailAction(
            icon: Icons.extension_outlined,
            label: 'ADD-ONS',
            onTap: onAddons,
          ),
          const Spacer(),
          _RailAction(
            icon: Icons.terminal,
            label: 'TERMINAL',
            onTap: onTerminal,
          ),
          _RailAction(
            icon: Icons.settings_outlined,
            label: 'SETTINGS',
            onTap: onSettings,
          ),
          SizedBox(height: compact ? 4 : 14),
        ],
      ),
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 560;
    return Tooltip(
      message: label,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 0 : 2),
        child: Material(
          color: selected
              ? colors.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              key: ValueKey('rail-${label.toLowerCase().replaceAll(' ', '-')}'),
              width: 48,
              height: compact ? 36 : 42,
              decoration: BoxDecoration(
                border: selected
                    ? Border(left: BorderSide(color: colors.primary, width: 2))
                    : null,
              ),
              child: Icon(
                icon,
                size: 21,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopWorkspaceBar extends StatelessWidget {
  const _TopWorkspaceBar({
    required this.activeFile,
    required this.searchMode,
    required this.terminalVisible,
    required this.inspectorVisible,
    required this.lightMode,
    required this.onExplorer,
    required this.onEditor,
    required this.onTerminal,
    required this.onInspector,
    required this.onToggleTheme,
    required this.onNotifications,
    required this.notificationCount,
  });

  final String? activeFile;
  final bool searchMode;
  final bool terminalVisible;
  final bool inspectorVisible;
  final bool lightMode;
  final VoidCallback onExplorer;
  final VoidCallback? onEditor;
  final VoidCallback onTerminal;
  final VoidCallback onInspector;
  final VoidCallback onToggleTheme;
  final VoidCallback onNotifications;
  final int notificationCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('top-workspace-bar'),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            'YOUNZCODE',
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(width: 20),
          _WorkspaceTab(
            label: 'Explorer',
            active: activeFile == null && !searchMode && !terminalVisible,
            onTap: onExplorer,
          ),
          _WorkspaceTab(
            label: 'Editor',
            active: activeFile != null,
            onTap: onEditor,
          ),
          _WorkspaceTab(
            label: 'Terminal',
            active: terminalVisible,
            onTap: onTerminal,
          ),
          _WorkspaceTab(
            key: const ValueKey('show-activity-panel'),
            label: 'Inspector',
            active: inspectorVisible,
            onTap: onInspector,
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('theme-toggle'),
            tooltip: lightMode ? 'Gunakan mode gelap' : 'Gunakan mode terang',
            onPressed: onToggleTheme,
            icon: Icon(
              lightMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              size: 20,
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 1000)
            IconButton(
              tooltip: 'Project settings',
              onPressed: onInspector,
              icon: const Icon(Icons.account_tree_outlined, size: 20),
            ),
          IconButton(
            key: const ValueKey('notifications-button'),
            tooltip: 'Notifications',
            onPressed: onNotifications,
            icon: Badge(
              isLabelVisible: notificationCount > 0,
              label: Text('${notificationCount.clamp(0, 99)}'),
              child: const Icon(Icons.notifications_none, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTab extends StatelessWidget {
  const _WorkspaceTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        margin: const EdgeInsets.only(right: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: active
              ? Border(bottom: BorderSide(color: colors.primary, width: 2))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ProjectPanel extends StatefulWidget {
  const _ProjectPanel({
    required this.workspace,
    required this.onOpenFile,
    required this.onChoose,
    required this.onNewChat,
    required this.onChat,
    required this.onTerminal,
    required this.onHistory,
    required this.onAddons,
    required this.onSettings,
    required this.onSearch,
    required this.onHide,
  });

  final String workspace;
  final ValueChanged<String> onOpenFile;
  final VoidCallback onChoose;
  final VoidCallback onNewChat;
  final VoidCallback onChat;
  final VoidCallback onTerminal;
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final VoidCallback onHistory;
  final VoidCallback onAddons;
  final VoidCallback onHide;

  @override
  State<_ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<_ProjectPanel> {
  int _treeRevision = 0;
  bool _treeExpanded = true;
  final _filterController = TextEditingController();

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ProjectPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) _treeRevision++;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = Theme.of(context).colorScheme;
    final folderName = widget.workspace.isEmpty
        ? 'Belum dipilih'
        : widget.workspace.replaceAll('\\', '/').split('/').last;
    return Container(
      key: const ValueKey('workspace-explorer'),
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'WORKSPACE',
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onChoose,
                  tooltip: 'Choose workspace',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_horiz, size: 18),
                ),
                IconButton(
                  key: const ValueKey('hide-explorer-panel'),
                  onPressed: widget.onHide,
                  tooltip: 'Hide Explorer',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: InkWell(
              onTap: widget.onChoose,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                color: colors.primary.withValues(alpha: 0.12),
                child: Text(
                  widget.workspace.isEmpty
                      ? '/select/a/project'
                      : widget.workspace,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: SizedBox(
              height: 38,
              child: TextField(
                key: const ValueKey('file-filter'),
                controller: _filterController,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Filter files...',
                  prefixIcon: Icon(Icons.search, size: 18),
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
          if (widget.workspace.isNotEmpty) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('workspace-tree-root-toggle'),
                onTap: () => setState(() => _treeExpanded = !_treeExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _treeExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 17,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.folder_outlined,
                        size: 18,
                        color: colors.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          folderName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => setState(() => _treeRevision++),
                        tooltip: 'Refresh file tree',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 15),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_treeExpanded)
              Expanded(
                child: _WorkspaceTree(
                  key: ValueKey('${widget.workspace}:$_treeRevision'),
                  root: widget.workspace,
                  filter: _filterController.text,
                  onOpenFile: widget.onOpenFile,
                ),
              )
            else
              const Spacer(),
          ] else
            Expanded(
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: widget.onChoose,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('SELECT WORKSPACE'),
                ),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RECENT',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.workspace.isEmpty
                      ? 'No workspace history'
                      : 'History is available from the command rail',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTree extends StatefulWidget {
  const _WorkspaceTree({
    super.key,
    required this.root,
    this.filter = '',
    required this.onOpenFile,
  });

  final String root;
  final String filter;
  final ValueChanged<String> onOpenFile;

  @override
  State<_WorkspaceTree> createState() => _WorkspaceTreeState();
}

class _WorkspaceTreeState extends State<_WorkspaceTree> {
  late Future<List<FileSystemEntity>> _entries = _readDirectory(widget.root);

  static Future<List<FileSystemEntity>> _readDirectory(String directory) async {
    final entries = await Directory(
      directory,
    ).list(followLinks: false).toList();
    entries.sort((left, right) {
      final leftDirectory = left is Directory;
      final rightDirectory = right is Directory;
      if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
      return _entityName(
        left,
      ).toLowerCase().compareTo(_entityName(right).toLowerCase());
    });
    return entries;
  }

  static String _entityName(FileSystemEntity entity) =>
      entity.path.replaceAll('\\', '/').split('/').last;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FileSystemEntity>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          );
        }
        if (snapshot.hasError) {
          return _TreeMessage(
            icon: Icons.error_outline,
            message: 'Gagal membaca folder',
            onRetry: () =>
                setState(() => _entries = _readDirectory(widget.root)),
          );
        }
        final query = widget.filter.trim().toLowerCase();
        final entries = query.isEmpty
            ? snapshot.data!
            : snapshot.data!
                  .where(
                    (entry) => _entityName(entry).toLowerCase().contains(query),
                  )
                  .toList();
        if (entries.isEmpty) {
          return const _TreeMessage(
            icon: Icons.folder_off_outlined,
            message: 'Folder kosong',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          itemCount: entries.length,
          itemBuilder: (context, index) => _FileTreeEntry(
            key: ValueKey(entries[index].path),
            entity: entries[index],
            depth: 0,
            onOpenFile: widget.onOpenFile,
          ),
        );
      },
    );
  }
}

class _FileTreeEntry extends StatefulWidget {
  const _FileTreeEntry({
    super.key,
    required this.entity,
    required this.depth,
    required this.onOpenFile,
  });

  final FileSystemEntity entity;
  final int depth;
  final ValueChanged<String> onOpenFile;

  @override
  State<_FileTreeEntry> createState() => _FileTreeEntryState();
}

class _FileTreeEntryState extends State<_FileTreeEntry> {
  bool _expanded = false;
  Future<List<FileSystemEntity>>? _children;

  bool get _isDirectory => widget.entity is Directory;

  void _toggle() {
    if (!_isDirectory) return;
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _children ??= _WorkspaceTreeState._readDirectory(widget.entity.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = _WorkspaceTreeState._entityName(widget.entity);
    final icon = _isDirectory
        ? (_expanded ? Icons.folder_open : Icons.folder)
        : _fileIcon(name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: widget.entity.path,
          waitDuration: const Duration(milliseconds: 650),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              onTap: _isDirectory
                  ? _toggle
                  : () => widget.onOpenFile(widget.entity.path),
              highlightColor: const Color(0x3379D6CD),
              splashColor: const Color(0x4479D6CD),
              child: SizedBox(
                height: 28,
                child: Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        child: _isDirectory
                            ? Icon(
                                _expanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                size: 15,
                                color: colors.onSurfaceVariant,
                              )
                            : null,
                      ),
                      Icon(
                        icon,
                        size: 15,
                        color: _isDirectory
                            ? colors.secondary
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w500,
                            color: _isDirectory
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_expanded && _children != null)
          FutureBuilder<List<FileSystemEntity>>(
            future: _children,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.2),
                  ),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: Text(
                    'Tidak dapat dibaca',
                    style: TextStyle(fontSize: 9, color: colors.error),
                  ),
                );
              }
              final children = snapshot.data!;
              if (children.isEmpty) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: Text(
                    'Folder kosong',
                    style: TextStyle(
                      fontSize: 9,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final child in children)
                    _FileTreeEntry(
                      key: ValueKey(child.path),
                      entity: child,
                      depth: widget.depth + 1,
                      onOpenFile: widget.onOpenFile,
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  IconData _fileIcon(String name) {
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    return switch (extension) {
      'dart' => Icons.flutter_dash,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object,
      'md' || 'txt' => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'ico' => Icons.image_outlined,
      'exe' || 'dll' => Icons.memory,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

class _TreeMessage extends StatelessWidget {
  const _TreeMessage({required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onRetry,
        icon: Icon(icon, size: 16),
        label: Text(message, style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}

class _OpenDocument {
  _OpenDocument({required this.path, required String content})
    : controller = SyntaxEditingController(
        language: EditorLanguage.fromPath(path),
        text: content,
      ),
      savedContent = content;

  final String path;
  final SyntaxEditingController controller;
  String savedContent;

  String get name => path.replaceAll('\\', '/').split('/').last;
  bool get sensitive => _isEnvironmentFileName(name.toLowerCase());
  bool get dirty => controller.text != savedContent;

  void dispose() => controller.dispose();
}

class _WorkspaceEditor extends StatefulWidget {
  const _WorkspaceEditor({
    super.key,
    required this.documents,
    required this.activePath,
    required this.onSelect,
    required this.onClose,
    required this.onSave,
    required this.onShowChat,
    required this.workspace,
    required this.trusted,
  });

  final List<_OpenDocument> documents;
  final String activePath;
  final ValueChanged<String> onSelect;
  final ValueChanged<_OpenDocument> onClose;
  final Future<void> Function(_OpenDocument) onSave;
  final VoidCallback onShowChat;
  final String workspace;
  final bool trusted;

  @override
  State<_WorkspaceEditor> createState() => _WorkspaceEditorState();
}

class _WorkspaceEditorState extends State<_WorkspaceEditor> {
  final _editorFocus = FocusNode();
  final _breakpoints = <String, Set<int>>{};
  final _debugOutput = <String>[];
  final _debugAdapter = DebugAdapterService();
  StreamSubscription<DebugAdapterEvent>? _debugEvents;
  List<String> _completions = const [];
  List<EditorDiagnostic> _diagnostics = const [];
  Process? _debugProcess;
  bool _debugConsoleVisible = false;
  bool _analyzing = false;
  bool _debugStarting = false;
  bool _debugPaused = false;
  int? _stoppedLine;
  final _editorScroll = ScrollController();
  final _gutterScroll = ScrollController();

  _OpenDocument get _document =>
      widget.documents.firstWhere((item) => item.path == widget.activePath);

  @override
  void initState() {
    super.initState();
    // Keep the line-number gutter aligned with the editor's own scroll.
    _editorScroll.addListener(_syncGutterScroll);
  }

  void _syncGutterScroll() {
    if (!_gutterScroll.hasClients || !_editorScroll.hasClients) return;
    final target = _editorScroll.offset.clamp(
      0.0,
      _gutterScroll.position.maxScrollExtent,
    );
    if ((_gutterScroll.offset - target).abs() > 0.5) {
      _gutterScroll.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _editorFocus.dispose();
    _editorScroll.dispose();
    _gutterScroll.dispose();
    final debugProcess = _debugProcess;
    if (debugProcess != null) {
      debugProcess.kill();
      if (Platform.isWindows) {
        // kill() alone orphans the debuggee child tree on Windows.
        unawaited(
          Process.run('taskkill', ['/PID', '${debugProcess.pid}', '/T', '/F']),
        );
      }
    }
    _debugEvents?.cancel();
    _debugAdapter.dispose();
    super.dispose();
  }

  void _updateCompletions() {
    final next = _document.controller.completionsAtCursor();
    if (next.toString() != _completions.toString()) {
      setState(() => _completions = next);
    }
  }

  void _applyCompletion(String value) {
    _document.controller.applyCompletion(value);
    setState(() => _completions = const []);
    _editorFocus.requestFocus();
  }

  Future<void> _analyze() async {
    if (!widget.trusted) return;
    setState(() => _analyzing = true);
    await widget.onSave(_document);
    final result = await LanguageTooling.analyze(_document.path);
    if (mounted) {
      setState(() {
        _diagnostics = result;
        _analyzing = false;
      });
    }
  }

  Future<void> _startDebug() async {
    if (!widget.trusted) return;
    await _stopDebug();
    await widget.onSave(_document);
    final launch = DebugAdapterLaunch.forFile(_document.path, widget.workspace);
    final fallback = LanguageTooling.debugCommand(_document.path);
    if (launch == null && fallback == null) {
      setState(() {
        _debugConsoleVisible = true;
        _debugOutput.add(
          'No debug adapter is available for ${_document.controller.language.id}.',
        );
      });
      return;
    }
    setState(() {
      _debugConsoleVisible = true;
      _debugStarting = true;
      _debugPaused = false;
      _stoppedLine = null;
      _debugOutput
        ..clear()
        ..add(
          launch == null
              ? 'Run fallback: ${fallback!.executable} ${fallback.arguments.join(' ')}'
              : 'Starting ${_document.controller.language.id} debug adapter...',
        )
        ..add(
          'Breakpoints: ${(_breakpoints[_document.path] ?? {}).join(', ')}',
        );
    });
    if (launch != null) {
      try {
        await _debugEvents?.cancel();
        _debugEvents = _debugAdapter.events.listen(_handleDebugEvent);
        await _debugAdapter.start(
          launch: launch,
          workspace: widget.workspace,
          sourcePath: _document.path,
          breakpoints: _breakpoints[_document.path] ?? const {},
        );
        if (mounted) {
          setState(() {
            _debugStarting = false;
            _debugOutput.add('Debugger attached. Breakpoints are active.');
          });
        }
        return;
      } catch (error) {
        await _debugAdapter.disconnect();
        _appendDebug(
          '${_document.controller.language.id} debug adapter unavailable: $error',
        );
        if (_document.controller.language.id == 'Python') {
          _appendDebug('Install it with: python -m pip install debugpy');
        }
        _appendDebug('Continuing with run-only fallback.');
      }
    }
    if (fallback == null) {
      if (mounted) setState(() => _debugStarting = false);
      return;
    }
    try {
      final process = await Process.start(
        fallback.executable,
        fallback.arguments,
        workingDirectory: widget.workspace,
      );
      _debugProcess = process;
      if (mounted) setState(() => _debugStarting = false);
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(_appendDebug);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(_appendDebug);
      final exitCode = await process.exitCode;
      if (mounted && identical(_debugProcess, process)) {
        setState(() {
          _debugOutput.add('Process exited with code $exitCode.');
          _debugProcess = null;
        });
      }
    } catch (error) {
      _appendDebug('Unable to start debugger: $error');
      if (mounted) setState(() => _debugStarting = false);
    }
  }

  void _handleDebugEvent(DebugAdapterEvent event) {
    if (!mounted) return;
    if (event.name == 'output') {
      _appendDebug('${event.body['output'] ?? ''}');
      return;
    }
    if (event.name == 'stopped') {
      setState(() {
        _debugPaused = true;
        _debugOutput.add('Paused: ${event.body['reason'] ?? 'breakpoint'}');
      });
      _loadStoppedLocation();
      return;
    }
    if (event.name == 'continued') {
      setState(() {
        _debugPaused = false;
        _stoppedLine = null;
      });
      return;
    }
    if (event.name == 'terminated' || event.name == 'exited') {
      setState(() {
        _debugPaused = false;
        _debugStarting = false;
        _stoppedLine = null;
        _debugOutput.add('Debug session terminated.');
      });
    }
  }

  Future<void> _loadStoppedLocation() async {
    final threadId = _debugAdapter.threadId;
    if (threadId == null) return;
    try {
      final body = await _debugAdapter.request('stackTrace', {
        'threadId': threadId,
        'startFrame': 0,
        'levels': 1,
      });
      final frames = body['stackFrames'] as List?;
      if (frames == null || frames.isEmpty || !mounted) return;
      final frame = Map<String, dynamic>.from(frames.first as Map);
      final line = frame['line'] as int?;
      setState(() {
        _stoppedLine = line;
        _debugOutput.add(
          'Stopped at ${frame['name'] ?? 'frame'} (${line ?? '?'}:${frame['column'] ?? '?'})',
        );
      });
    } catch (error) {
      _appendDebug('Unable to load stack frame: $error');
    }
  }

  void _appendDebug(String value) {
    if (mounted) setState(() => _debugOutput.add(value.trimRight()));
  }

  Future<void> _stopDebug() async {
    if (_debugAdapter.running) {
      await _debugAdapter.disconnect();
      if (mounted) {
        setState(() {
          _debugPaused = false;
          _debugStarting = false;
          _stoppedLine = null;
          _debugOutput.add('Debug session stopped.');
        });
      }
    }
    final process = _debugProcess;
    if (process == null) return;
    process.kill();
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    }
    if (mounted) {
      setState(() {
        _debugProcess = null;
        _debugOutput.add('Debug session stopped.');
      });
    }
  }

  void _toggleBreakpoint(int line) {
    final points = _breakpoints.putIfAbsent(_document.path, () => <int>{});
    setState(
      () => points.contains(line) ? points.remove(line) : points.add(line),
    );
    if (_debugAdapter.running) {
      _debugAdapter
          .updateBreakpoints(_document.path, points)
          .catchError(
            (error) => _appendDebug('Breakpoint update failed: $error'),
          );
    }
  }

  void _debugCommand(Future<void> Function() command) {
    command().catchError(
      (error) => _appendDebug('Debug command failed: $error'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final editorBackground = light
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF0C0E12);
    final editorChrome = light ? colors.surface : const Color(0xFF151810);
    final editorGutter = light
        ? const Color(0xFFF2F4EC)
        : const Color(0xFF10120F);
    final lines = '\n'.allMatches(document.controller.text).length + 1;
    final points = _breakpoints[document.path] ?? <int>{};
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            widget.onSave(document),
        const SingleActivator(LogicalKeyboardKey.space, control: true): () {
          setState(
            () => _completions = document.controller.completionsAtCursor(),
          );
        },
        const SingleActivator(LogicalKeyboardKey.f5): () {
          if (!widget.trusted) return;
          if (_debugPaused) {
            _debugCommand(_debugAdapter.continueExecution);
          } else if (!_debugStarting &&
              !_debugAdapter.running &&
              _debugProcess == null) {
            _startDebug();
          }
        },
        const SingleActivator(LogicalKeyboardKey.f10): () {
          if (_debugPaused) _debugCommand(_debugAdapter.next);
        },
        const SingleActivator(LogicalKeyboardKey.f11): () {
          if (_debugPaused) _debugCommand(_debugAdapter.stepIn);
        },
        const SingleActivator(LogicalKeyboardKey.f11, shift: true): () {
          if (_debugPaused) _debugCommand(_debugAdapter.stepOut);
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Container(
              height: 40,
              color: editorChrome,
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onShowChat,
                    tooltip: 'Back to Chat',
                    icon: const Icon(Icons.chat_bubble_outline, size: 17),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final item in widget.documents)
                          Material(
                            color: item.path == widget.activePath
                                ? editorBackground
                                : Colors.transparent,
                            child: InkWell(
                              onTap: () => widget.onSelect(item.path),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 120,
                                  maxWidth: 220,
                                ),
                                padding: const EdgeInsets.only(left: 12),
                                decoration: BoxDecoration(
                                  border: item.path == widget.activePath
                                      ? const Border(
                                          top: BorderSide(
                                            color: Color(0xFFC6F269),
                                            width: 2,
                                          ),
                                        )
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      item.sensitive
                                          ? Icons.shield_outlined
                                          : Icons.insert_drive_file_outlined,
                                      size: 14,
                                      color: item.sensitive
                                          ? const Color(0xFFB26A00)
                                          : colors.secondary,
                                    ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Text(
                                        '${item.name}${item.dirty ? ' •' : ''}',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'Consolas',
                                          fontSize: 11,
                                          color: colors.onSurface,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () => widget.onClose(item),
                                      tooltip: 'Close',
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.close, size: 14),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: editorChrome,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      document.path,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (document.sensitive)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'File sensitif lokal; agent AI tetap diblokir',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.shield_outlined,
                              size: 14,
                              color: Color(0xFFFFC857),
                            ),
                            SizedBox(width: 5),
                            Text(
                              'LOCAL ONLY',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFFFC857),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  TextButton.icon(
                    key: const ValueKey('save-editor-file'),
                    onPressed: document.dirty
                        ? () => widget.onSave(document)
                        : null,
                    icon: const Icon(Icons.save_outlined, size: 15),
                    label: const Text('SAVE  CTRL+S'),
                  ),
                  IconButton(
                    key: const ValueKey('analyze-editor-file'),
                    onPressed: _analyzing || !widget.trusted ? null : _analyze,
                    tooltip: 'Analyze with language tooling',
                    icon: _analyzing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : const Icon(Icons.rule_folder_outlined, size: 17),
                  ),
                  IconButton(
                    key: const ValueKey('start-debugger'),
                    onPressed: _debugStarting
                        ? null
                        : !widget.trusted
                        ? null
                        : (!_debugAdapter.running && _debugProcess == null)
                        ? _startDebug
                        : _stopDebug,
                    tooltip: (!_debugAdapter.running && _debugProcess == null)
                        ? 'Run and debug (F5)'
                        : 'Stop debugging',
                    icon: Icon(
                      (!_debugAdapter.running && _debugProcess == null)
                          ? Icons.play_arrow
                          : Icons.stop,
                      size: 18,
                      color: (!_debugAdapter.running && _debugProcess == null)
                          ? const Color(0xFFC6F269)
                          : const Color(0xFFFF6B6B),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: editorBackground,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 58,
                      padding: const EdgeInsets.only(top: 14),
                      color: editorGutter,
                      alignment: Alignment.topRight,
                      child: SingleChildScrollView(
                        controller: _gutterScroll,
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            for (var line = 1; line <= lines; line++)
                              InkWell(
                                onTap: () => _toggleBreakpoint(line),
                                child: SizedBox(
                                  height: 19.5,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        child: _stoppedLine == line
                                            ? const Icon(
                                                Icons.arrow_right,
                                                size: 18,
                                                color: Color(0xFFC6F269),
                                              )
                                            : points.contains(line)
                                            ? const Icon(
                                                Icons.circle,
                                                size: 10,
                                                color: Color(0xFFFF6B6B),
                                              )
                                            : null,
                                      ),
                                      Expanded(
                                        child: Text(
                                          '$line',
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            fontFamily: 'Consolas',
                                            fontSize: 13,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          TextField(
                            key: const ValueKey('workspace-editor'),
                            focusNode: _editorFocus,
                            controller: document.controller,
                            scrollController: _editorScroll,
                            onChanged: (_) => _updateCompletions(),
                            expands: true,
                            minLines: null,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 13,
                              height: 1.5,
                              color: colors.onSurface,
                            ),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: editorBackground,
                              contentPadding: const EdgeInsets.all(14),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                          if (_completions.isNotEmpty)
                            Positioned(
                              left: 24,
                              top: 48,
                              child: Material(
                                elevation: 10,
                                color: colors.surface,
                                child: SizedBox(
                                  width: 260,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final completion in _completions)
                                        ListTile(
                                          dense: true,
                                          leading: Icon(
                                            document
                                                    .controller
                                                    .language
                                                    .keywords
                                                    .contains(completion)
                                                ? Icons.key
                                                : Icons.data_object,
                                            size: 14,
                                            color: colors.secondary,
                                          ),
                                          title: Text(
                                            completion,
                                            style: const TextStyle(
                                              fontFamily: 'Consolas',
                                              fontSize: 12,
                                            ),
                                          ),
                                          onTap: () =>
                                              _applyCompletion(completion),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (_diagnostics.isNotEmpty)
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                color: const Color(0xEE241A18),
                                child: Text(
                                  _diagnostics
                                      .take(3)
                                      .map(
                                        (item) =>
                                            'Line ${item.line}: ${item.message}',
                                      )
                                      .join('\n'),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Consolas',
                                    fontSize: 10,
                                    color: Color(0xFFFFB4AB),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 74,
                      child: CustomPaint(
                        key: const ValueKey('editor-minimap'),
                        painter: CodeMinimapPainter(
                          document.controller.text,
                          points,
                          normalColor: colors.onSurfaceVariant,
                          accentColor: colors.secondary,
                          breakpointColor: colors.error,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: editorGutter,
                            border: Border(
                              left: BorderSide(color: theme.dividerColor),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_debugConsoleVisible)
              Container(
                height: 150,
                decoration: BoxDecoration(
                  color: editorChrome,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: 32,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Text(
                            'DEBUG CONSOLE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: colors.primary,
                            ),
                          ),
                          const Spacer(),
                          if (_debugAdapter.running) ...[
                            IconButton(
                              onPressed: _debugPaused
                                  ? () => _debugCommand(
                                      _debugAdapter.continueExecution,
                                    )
                                  : () => _debugCommand(_debugAdapter.pause),
                              tooltip: _debugPaused ? 'Continue (F5)' : 'Pause',
                              icon: Icon(
                                _debugPaused ? Icons.play_arrow : Icons.pause,
                                size: 16,
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('debug-step-over'),
                              onPressed: _debugPaused
                                  ? () => _debugCommand(_debugAdapter.next)
                                  : null,
                              tooltip: 'Step over (F10)',
                              icon: const Icon(Icons.redo, size: 16),
                            ),
                            IconButton(
                              onPressed: _debugPaused
                                  ? () => _debugCommand(_debugAdapter.stepIn)
                                  : null,
                              tooltip: 'Step into (F11)',
                              icon: const Icon(
                                Icons.subdirectory_arrow_right,
                                size: 16,
                              ),
                            ),
                            IconButton(
                              onPressed: _debugPaused
                                  ? () => _debugCommand(_debugAdapter.stepOut)
                                  : null,
                              tooltip: 'Step out (Shift+F11)',
                              icon: const Icon(Icons.call_made, size: 16),
                            ),
                          ],
                          IconButton(
                            onPressed:
                                widget.trusted &&
                                    !_debugAdapter.running &&
                                    _debugProcess == null &&
                                    !_debugStarting
                                ? _startDebug
                                : null,
                            tooltip: 'Restart',
                            icon: const Icon(Icons.refresh, size: 16),
                          ),
                          IconButton(
                            onPressed: () =>
                                setState(() => _debugConsoleVisible = false),
                            tooltip: 'Close debug console',
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        itemCount: _debugOutput.length,
                        itemBuilder: (_, index) => SelectableText(
                          _debugOutput[index],
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 10,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IntegratedTerminal extends StatelessWidget {
  const _IntegratedTerminal({
    required this.controller,
    required this.scrollController,
    required this.output,
    required this.busy,
    required this.workspace,
    required this.onRun,
    required this.onClose,
    required this.onClear,
  });

  final TextEditingController controller;
  final ScrollController scrollController;
  final List<String> output;
  final bool busy;
  final String workspace;
  final VoidCallback onRun;
  final VoidCallback onClose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('integrated-terminal'),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.terminal, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                const Text(
                  'POWERSHELL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onClear,
                  tooltip: 'Clear terminal',
                  icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                ),
                IconButton(
                  onPressed: onClose,
                  tooltip: 'Close terminal',
                  icon: const Icon(Icons.close, size: 17),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: output.length,
              itemBuilder: (context, index) => SelectableText(
                output[index],
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.35,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Text(
                  'PS ${workspace.replaceAll('\\', '/').split('/').last}>',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('terminal-input'),
                    controller: controller,
                    enabled: !busy,
                    onSubmitted: (_) => onRun(),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Enter PowerShell command...',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: busy ? null : onRun,
                  tooltip: 'Run command',
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      : const Icon(Icons.play_arrow, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentActivity {
  const _AgentActivity({
    required this.id,
    required this.name,
    required this.detail,
    required this.state,
  });

  final String id;
  final String name;
  final String detail;
  final String state;

  String get label => switch (name) {
    'run_command' => 'Shell',
    'read_file' => 'Read',
    'write_file' => 'Write',
    'replace_text' => 'Edit',
    'list_files' => 'Glob',
    'search_text' => 'Grep',
    _ when name.startsWith('mcp_') => 'MCP',
    _ => name,
  };

  bool get running => state == 'berjalan';
  bool get completed => !running;
  bool get succeeded => state == 'selesai';
  bool get failed => state == 'gagal';
  bool get warning => state == 'ditolak' || state == 'dibatalkan';
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({
    super.key,
    required this.activities,
    required this.busy,
    required this.status,
    required this.onHide,
    required this.section,
    required this.onSectionChanged,
    required this.pendingChanges,
    required this.changeHistory,
    required this.onReviewChanges,
    this.onRevert,
  });

  final List<_AgentActivity> activities;
  final bool busy;
  final String status;
  final VoidCallback onHide;
  final _InspectorSection section;
  final ValueChanged<_InspectorSection> onSectionChanged;
  final WorkspaceTurnChanges? pendingChanges;
  final List<WorkspaceTurnChanges> changeHistory;
  final VoidCallback onReviewChanges;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final last = activities.isEmpty ? null : activities.last;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 52,
            child: Stack(
              children: [
                Row(
                  children: [
                    _InspectorTab(
                      label: 'ACTIVITY',
                      active: section == _InspectorSection.activity,
                      onTap: () => onSectionChanged(_InspectorSection.activity),
                    ),
                    _InspectorTab(
                      label: 'PLAN',
                      active: section == _InspectorSection.plan,
                      onTap: () => onSectionChanged(_InspectorSection.plan),
                    ),
                    _InspectorTab(
                      label: pendingChanges == null
                          ? 'FILES'
                          : 'FILES ${pendingChanges!.files.length}',
                      active: section == _InspectorSection.files,
                      onTap: () => onSectionChanged(_InspectorSection.files),
                    ),
                  ],
                ),
                Positioned(
                  right: 2,
                  top: 13,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      key: const ValueKey('hide-activity-panel'),
                      onPressed: onHide,
                      tooltip: 'Hide tool activity',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.chevron_right, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: section == _InspectorSection.files
                ? _InspectorFiles(
                    changes: pendingChanges,
                    history: changeHistory,
                    onReview: onReviewChanges,
                    onRevert: onRevert,
                  )
                : section == _InspectorSection.plan
                ? _InspectorPlan(activities: activities, busy: busy)
                : ListView(
                    padding: const EdgeInsets.all(18),
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            color: busy
                                ? colors.primary
                                : const Color(0xFF28C76F),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              busy
                                  ? 'AGENT: ${status.toUpperCase()}'
                                  : 'AGENT: IDLE',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: Column(
                          children: [
                            _InspectorMetric(
                              label: 'Last tool:',
                              value: last?.label ?? 'none',
                              accent: true,
                            ),
                            const SizedBox(height: 12),
                            _InspectorMetric(
                              label: 'Status:',
                              value:
                                  last?.state ?? (busy ? 'Running' : 'Ready'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      const _InspectorHeading('SYSTEM LOAD'),
                      const SizedBox(height: 12),
                      _LoadBar(label: 'COMPUTE', value: busy ? 0.72 : 0.12),
                      const SizedBox(height: 14),
                      _LoadBar(
                        label: 'CONTEXT',
                        value: activities.isEmpty ? 0.04 : 0.28,
                        tertiary: true,
                      ),
                      const SizedBox(height: 28),
                      const _InspectorHeading('NOTIFICATIONS'),
                      const SizedBox(height: 12),
                      if (activities.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.06),
                            border: Border(
                              left: BorderSide(color: colors.primary),
                            ),
                          ),
                          child: Text(
                            'NO ACTIVITY DETECTED',
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        for (final activity in activities.reversed)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: colors.primary),
                              ),
                              color: colors.primary.withValues(alpha: 0.05),
                            ),
                            child: Text(
                              '${activity.label}\n${activity.detail}\n${activity.state.toUpperCase()}',
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 10,
                                height: 1.4,
                              ),
                            ),
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _InspectorPlan extends StatelessWidget {
  const _InspectorPlan({required this.activities, required this.busy});

  final List<_AgentActivity> activities;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (activities.isEmpty) {
      return Center(
        child: Text(
          busy ? 'MENYIAPKAN RENCANA...' : 'BELUM ADA RENCANA',
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(18),
      itemCount: activities.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final activity = activities[index];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}.',
                style: TextStyle(fontFamily: 'Consolas', color: colors.primary),
              ),
            ),
            Expanded(
              child: Text(
                '${activity.label}\n${activity.detail}',
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InspectorFiles extends StatelessWidget {
  const _InspectorFiles({
    required this.changes,
    required this.history,
    required this.onReview,
    this.onRevert,
  });

  final WorkspaceTurnChanges? changes;
  final List<WorkspaceTurnChanges> history;
  final VoidCallback onReview;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final files = changes?.files ?? const <WorkspaceFileChange>[];
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (files.isEmpty)
          Text(
            'TIDAK ADA PERUBAHAN TERTUNDA',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: colors.onSurfaceVariant,
            ),
          )
        else ...[
          for (final file in files)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Text(
                file.status,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.w700,
                  color: colors.primary,
                ),
              ),
              title: Text(
                file.path,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
              ),
              subtitle: Text('${file.hunks.length} hunk'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onReview,
            child: const Text('REVIEW CHANGES'),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            '${history.length} TURN TERSIMPAN',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 10,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (onRevert != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRevert,
            child: const Text('REVERT LAST TURN'),
          ),
        ],
      ],
    );
  }
}

class _ChangesReviewDialog extends StatefulWidget {
  const _ChangesReviewDialog({required this.changes});

  final WorkspaceTurnChanges changes;

  @override
  State<_ChangesReviewDialog> createState() => _ChangesReviewDialogState();
}

class _ChangesReviewDialogState extends State<_ChangesReviewDialog> {
  late final Set<String> _selected = {
    for (final file in widget.changes.files)
      for (final hunk in file.hunks) hunk.id,
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review agent changes'),
    content: SizedBox(
      width: 760,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final file in widget.changes.files) ...[
            Text(
              '${file.status}  ${file.path}',
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final hunk in file.hunks)
              CheckboxListTile(
                value: _selected.contains(hunk.id),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _selected.add(hunk.id);
                  } else {
                    _selected.remove(hunk.id);
                  }
                }),
                title: Text(
                  hunk.unified,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('CANCEL'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, <String>{}),
        child: const Text('REJECT ALL'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, Set<String>.of(_selected)),
        child: Text('APPLY ${_selected.length} HUNKS'),
      ),
    ],
  );
}

class _InspectorTab extends StatelessWidget {
  const _InspectorTab({
    required this.label,
    this.active = false,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: active
                ? Border(bottom: BorderSide(color: colors.primary, width: 2))
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: active ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorMetric extends StatelessWidget {
  const _InspectorMetric({
    required this.label,
    required this.value,
    this.accent = false,
  });
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: colors.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: accent ? colors.primary : colors.onSurface,
          ),
        ),
      ],
    );
  }
}

class _InspectorHeading extends StatelessWidget {
  const _InspectorHeading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      fontFamily: 'Consolas',
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _LoadBar extends StatelessWidget {
  const _LoadBar({
    required this.label,
    required this.value,
    this.tertiary = false,
  });
  final String label;
  final double value;
  final bool tertiary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 9),
            ),
            const Spacer(),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 9),
            ),
          ],
        ),
        const SizedBox(height: 5),
        LinearProgressIndicator(
          value: value,
          minHeight: 2,
          color: tertiary ? colors.tertiary : colors.primary,
          backgroundColor: colors.onSurface.withValues(alpha: 0.12),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final horizontalPadding = compact ? 20.0 : 32.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 28,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 720,
                minHeight: math.max(0, constraints.maxHeight - 56),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: 0.18,
                    child: Container(
                      width: compact ? 88 : 112,
                      height: compact ? 88 : 112,
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      child: Image.asset(
                        'assets/younzcode_logo_new.png',
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 20 : 28),
                  Text(
                    'What are we building?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 32 : 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Select a workspace or describe a task to begin. I can help '
                    'with architecture, debugging, or test automation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                  SizedBox(height: compact ? 22 : 30),
                  GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: compact ? 1 : 2,
                    mainAxisExtent: 82,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _SuggestionCard(
                        icon: Icons.bolt_outlined,
                        title: 'Generate Feature',
                        subtitle: 'Bootstrap new module',
                        onTap: () => onSuggestion(
                          'Buat fitur baru dengan mengikuti pola kode yang sudah ada.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.bug_report_outlined,
                        title: 'Fix Logic Bug',
                        subtitle: 'Trace and repair errors',
                        onTap: () => onSuggestion(
                          'Bantu saya menganalisis dan memperbaiki bug pada proyek ini.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.checklist_rtl_outlined,
                        title: 'Write Test Suite',
                        subtitle: 'Unit & integration coverage',
                        onTap: () => onSuggestion(
                          'Jalankan semua test dan perbaiki kegagalan yang ditemukan.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.menu_book_outlined,
                        title: 'Explain Codebase',
                        subtitle: 'Analyze relationships',
                        onTap: () => onSuggestion(
                          'Jelaskan arsitektur proyek ini dan modul-modul utamanya.',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({super.key, required this.entry});

  final ChatEntry entry;

  Future<void> _copyResponse(BuildContext context, String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Respons disalin.'),
          duration: Duration(seconds: 1),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final user = entry.role == ChatRole.user;
    final error = entry.role == ChatRole.error;
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final displayedContent = user
        ? entry.content
        : formatAgentResponse(entry.content);
    return TweenAnimationBuilder<double>(
      duration: _mediumMotion,
      curve: _motionCurve,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset((user ? 12 : -12) * (1 - value), 6 * (1 - value)),
          child: child,
        ),
      ),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: user
                ? light
                      ? const Color(0xFFE4E8D8)
                      : const Color(0xFF33362C)
                : theme.colorScheme.surface,
            border: Border.all(
              color: error
                  ? Theme.of(context).colorScheme.error
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(user ? 12 : 3),
              bottomRight: Radius.circular(user ? 3 : 12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    user
                        ? 'YOU'
                        : error
                        ? 'ERROR'
                        : 'AGENT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: error
                          ? Theme.of(context).colorScheme.error
                          : user
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                    ),
                  ),
                  if (!user) ...[
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('copy-agent-response'),
                      tooltip: 'Salin respons',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () => _copyResponse(context, displayedContent),
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                displayedContent,
                style: TextStyle(
                  height: user ? 1.5 : 1.65,
                  fontFamily: user ? 'Consolas' : null,
                  fontSize: user ? null : 14,
                ),
              ),
              if (!user) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('copy-agent-response-bottom'),
                    onPressed: () => _copyResponse(context, displayedContent),
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    label: const Text('COPY RESPONSE'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelBar extends StatelessWidget {
  const _ModelBar({
    required this.models,
    required this.selectedModel,
    required this.busy,
    required this.planMode,
    required this.onSelected,
    required this.onManage,
    required this.onPlanModeChanged,
  });

  final List<String> models;
  final String selectedModel;
  final bool busy;
  final bool planMode;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage;
  final ValueChanged<bool> onPlanModeChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final modelControls = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.06),
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: colors.onSurface,
                  ),
                  const SizedBox(width: 7),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('model-selector'),
                      value: selectedModel,
                      borderRadius: BorderRadius.circular(4),
                      dropdownColor: colors.surface,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                        color: colors.onSurface,
                      ),
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value != null) onSelected(value);
                            },
                      items: [
                        for (final model in models)
                          DropdownMenuItem(value: model, child: Text(model)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: busy ? null : onManage,
              icon: const Icon(Icons.description_outlined, size: 15),
              label: const Text('MANAGE MODELS'),
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                side: BorderSide(color: colors.primary.withValues(alpha: 0.45)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        );
        final planControl = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: const ValueKey('agent-mode-selector'),
              value: planMode,
              onChanged: busy ? null : onPlanModeChanged,
            ),
            const SizedBox(width: 6),
            Text(
              'Plan Mode',
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 11,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        );
        return Container(
          height: compact ? 112 : 56,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: compact
              ? Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: modelControls,
                    ),
                    const Spacer(),
                    Align(alignment: Alignment.centerRight, child: planControl),
                  ],
                )
              : Row(children: [modelControls, const Spacer(), planControl]),
        );
      },
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.planMode,
    required this.onPlanModeChanged,
    required this.contextFiles,
    required this.onAttachContext,
    required this.onRemoveContext,
    required this.onClearContext,
    required this.slashCommands,
    required this.onSlashCommand,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool planMode;
  final ValueChanged<bool> onPlanModeChanged;
  final List<String> contextFiles;
  final VoidCallback onAttachContext;
  final ValueChanged<String> onRemoveContext;
  final VoidCallback onClearContext;
  final List<_SlashCommand> slashCommands;
  final Future<void> Function(String command) onSlashCommand;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _hasText = false;
  List<_SlashCommand> _matchingCommands = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncText);
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncText);
      widget.controller.addListener(_syncText);
      _syncText();
    }
  }

  void _syncText() {
    final text = widget.controller.text.trim();
    final hasText = text.isNotEmpty;
    final matchingCommands = text.startsWith('/') && !text.contains(' ')
        ? widget.slashCommands
              .where((item) => item.command.startsWith(text.toLowerCase()))
              .toList()
        : const <_SlashCommand>[];
    if (mounted) {
      setState(() {
        _hasText = hasText;
        _matchingCommands = matchingCommands;
      });
    }
  }

  Future<void> _selectCommand(_SlashCommand command) async {
    widget.controller.clear();
    await widget.onSlashCommand(command.command);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncText);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_matchingCommands.isNotEmpty)
            Container(
              key: const ValueKey('slash-command-menu'),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height >= 700 ? 440 : 280,
              ),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: theme.dividerColor),
              ),
              child: SingleChildScrollView(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 480 ? 2 : 1;
                    final itemWidth = constraints.maxWidth / columns;
                    return Wrap(
                      children: [
                        for (final command in _matchingCommands)
                          SizedBox(
                            width: itemWidth,
                            child: ListTile(
                              key: ValueKey(
                                'slash-command-${command.command.substring(1)}',
                              ),
                              dense: true,
                              minTileHeight: 52,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(
                                command.icon,
                                size: 17,
                                color: colors.primary,
                              ),
                              title: Text(
                                command.command,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                command.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: widget.busy
                                  ? null
                                  : () => _selectCommand(command),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          if (widget.contextFiles.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '${widget.contextFiles.length} files · ~${_estimatedTokens()} tokens',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 10,
                    color: colors.primary,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('clear-context'),
                  onPressed: widget.busy ? null : widget.onClearContext,
                  child: const Text('CLEAR CONTEXT'),
                ),
              ],
            ),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.contextFiles.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final file = widget.contextFiles[index];
                  return InputChip(
                    label: Text(
                      file.replaceAll('\\', '/').split('/').last,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                      ),
                    ),
                    onDeleted: widget.busy
                        ? null
                        : () => widget.onRemoveContext(file),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): () {
                    if (!widget.busy && _hasText) widget.onSend();
                  },
                },
                child: TextField(
                  key: const ValueKey('prompt-field'),
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 4,
                  maxLines: 7,
                  enabled: !widget.busy,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                  decoration: const InputDecoration(
                    hintText: 'Describe a task or type / for commands...',
                    contentPadding: EdgeInsets.fromLTRB(16, 16, 64, 24),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: FilledButton(
                    key: ValueKey(widget.busy ? 'stop-agent' : 'send-agent'),
                    onPressed: widget.busy
                        ? widget.onStop
                        : !_hasText
                        ? null
                        : widget.onSend,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: widget.busy
                          ? colors.error
                          : colors.primary,
                    ),
                    child: Icon(
                      widget.busy ? Icons.stop_rounded : Icons.send_rounded,
                      color: colors.onPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              TextButton.icon(
                key: const ValueKey('attach-context'),
                onPressed: widget.busy ? null : widget.onAttachContext,
                icon: const Icon(Icons.attach_file, size: 14),
                label: Text('${widget.contextFiles.length} FILES'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.planMode
                      ? 'READ-ONLY · Enter to send · Shift+Enter for new line'
                      : 'Enter to send · Shift+Enter for new line',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 9,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _estimatedTokens() {
    var bytes = 0;
    for (final file in widget.contextFiles) {
      try {
        bytes += File(file).lengthSync();
      } catch (_) {}
    }
    return (bytes / 4).ceil();
  }
}

class _SuggestionCard extends StatefulWidget {
  const _SuggestionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<_SuggestionCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: AnimatedScale(
        duration: _fastMotion,
        curve: _motionCurve,
        scale: _pressed ? 0.975 : 1,
        child: AnimatedContainer(
          duration: _fastMotion,
          curve: _motionCurve,
          transform: Matrix4.translationValues(0, _pressed ? 2 : 0, 0),
          decoration: BoxDecoration(
            color: _pressed
                ? light
                      ? const Color(0xFFDDE3D2)
                      : const Color(0xFF292D20)
                : _hovered
                ? light
                      ? const Color(0xFFE8ECE1)
                      : const Color(0xFF22261B)
                : colors.surface,
            border: Border.all(
              color: _hovered ? colors.primary : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(2),
            boxShadow: _hovered && !_pressed
                ? const [
                    BoxShadow(
                      color: Color(0x24000000),
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(2),
              onTap: widget.onTap,
              onHighlightChanged: (pressed) =>
                  setState(() => _pressed = pressed),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: _fastMotion,
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _hovered
                            ? colors.primary.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Icon(widget.icon, size: 19, color: colors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 9,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedSlide(
                      duration: _fastMotion,
                      offset: _hovered ? Offset.zero : const Offset(-0.25, 0),
                      child: AnimatedOpacity(
                        duration: _fastMotion,
                        opacity: _hovered ? 1 : 0.35,
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          size: 17,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.connected,
    required this.configured,
    required this.busy,
    required this.model,
    required this.status,
    required this.tokens,
    required this.gitStatus,
    required this.onGit,
    required this.workspaceTrusted,
    required this.onTrustWorkspace,
  });

  final bool connected;
  final bool configured;
  final bool busy;
  final String model;
  final String status;
  final int tokens;
  final GitStatus gitStatus;
  final VoidCallback onGit;
  final bool workspaceTrusted;
  final VoidCallback onTrustWorkspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final state = busy
        ? status.toUpperCase()
        : connected
        ? 'API CONNECTED'
        : configured
        ? 'API CONFIGURED · NOT VERIFIED'
        : 'OFFLINE';
    final color = connected
        ? colors.primary
        : configured
        ? const Color(0xFFB26A00)
        : colors.onSurfaceVariant;
    return Container(
      key: const ValueKey('status-bar'),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Environment: Windows  |  Model: $model  |  Build: v$_appVersion'
              '${tokens > 0 ? '  |  Tokens: $tokens' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 10,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (gitStatus.isRepository) ...[
            const SizedBox(width: 16),
            InkWell(
              onTap: onGit,
              child: Text(
                '${gitStatus.branch}${gitStatus.dirty ? ' *' : ''}',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 10,
                  color: gitStatus.dirty ? colors.tertiary : colors.primary,
                ),
              ),
            ),
          ],
          if (!workspaceTrusted) ...[
            const SizedBox(width: 16),
            InkWell(
              key: const ValueKey('restricted-mode-action'),
              onTap: onTrustWorkspace,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'RESTRICTED MODE · TRUST WORKSPACE',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: colors.tertiary,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          Container(width: 5, height: 5, color: color),
          const SizedBox(width: 8),
          Text(
            connected ? 'SYNCED' : state,
            style: TextStyle(fontFamily: 'Consolas', fontSize: 9, color: color),
          ),
        ],
      ),
    );
  }
}

class _ProviderPreset {
  const _ProviderPreset({
    required this.label,
    required this.baseUrl,
    required this.models,
    required this.keyHint,
  });

  final String label;
  final String baseUrl; // empty => custom, leave existing fields untouched
  final List<String> models;
  final String keyHint;
}

const _customProviderLabel = 'Custom / OpenAI-compatible';

// Every provider here speaks the OpenAI Chat Completions protocol, so only the
// Base URL, example models, and where-to-get-the-key hint differ. Claude and
// Gemini are reached through OpenRouter or Google's OpenAI-compatible endpoint.
const _providerPresets = <_ProviderPreset>[
  _ProviderPreset(
    label: _customProviderLabel,
    baseUrl: '',
    models: [],
    keyHint: 'Base URL & model bebas selama endpoint OpenAI-compatible.',
  ),
  _ProviderPreset(
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-4.1', 'gpt-4o', 'o4-mini'],
    keyHint: 'API key dari platform.openai.com/api-keys',
  ),
  _ProviderPreset(
    label: 'OpenRouter (Claude, Gemini, dll)',
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      'anthropic/claude-sonnet-4',
      'google/gemini-2.5-pro',
      'openai/gpt-4.1',
    ],
    keyHint: 'Satu key untuk banyak model — openrouter.ai/keys',
  ),
  _ProviderPreset(
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    models: ['gemini-2.5-pro', 'gemini-2.5-flash'],
    keyHint: 'API key dari aistudio.google.com/apikey',
  ),
  _ProviderPreset(
    label: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    models: ['deepseek-ai/deepseek-r1', 'meta/llama-3.3-70b-instruct'],
    keyHint: 'API key dari build.nvidia.com',
  ),
  _ProviderPreset(
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    models: ['llama-3.3-70b-versatile', 'moonshotai/kimi-k2-instruct'],
    keyHint: 'API key dari console.groq.com/keys',
  ),
  _ProviderPreset(
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    models: ['deepseek-chat', 'deepseek-reasoner'],
    keyHint: 'API key dari platform.deepseek.com',
  ),
  _ProviderPreset(
    label: '9router (lokal)',
    baseUrl: 'http://127.0.0.1:20128/v1',
    models: [],
    keyHint:
        'Jalankan 9router lokal, sambungkan provider di dashboard-nya; '
        'model & API key mengikuti dashboard tersebut.',
  ),
  _ProviderPreset(
    label: 'Ollama (lokal)',
    baseUrl: 'http://localhost:11434/v1',
    models: ['qwen2.5-coder', 'llama3.1'],
    keyHint: 'Server lokal Ollama; API key boleh diisi apa saja.',
  ),
];

_ProviderPreset _presetForBaseUrl(String url) {
  final normalized = url.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();
  for (final preset in _providerPresets) {
    if (preset.baseUrl.isNotEmpty &&
        preset.baseUrl.toLowerCase().replaceAll(RegExp(r'/+$'), '') ==
            normalized) {
      return preset;
    }
  }
  return _providerPresets.first;
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    required this.selectedModel,
  });

  final String baseUrl;
  final String apiKey;
  final List<String> models;
  final String selectedModel;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late final _baseController = TextEditingController(text: widget.baseUrl);
  late final _keyController = TextEditingController(text: widget.apiKey);
  final _newModelController = TextEditingController();
  late final List<String> _models = [...widget.models];
  late String _selectedModel = widget.selectedModel;
  late String _providerLabel = _presetForBaseUrl(widget.baseUrl).label;
  bool _fetchingModels = false;
  String? _fetchError;

  @override
  void initState() {
    super.initState();
    // Editing the Base URL by hand flips the provider dropdown back to Custom.
    _baseController.addListener(_syncProviderLabel);
  }

  @override
  void dispose() {
    _baseController.dispose();
    _keyController.dispose();
    _newModelController.dispose();
    super.dispose();
  }

  void _syncProviderLabel() {
    final label = _presetForBaseUrl(_baseController.text).label;
    if (label != _providerLabel) setState(() => _providerLabel = label);
  }

  void _applyPreset(_ProviderPreset preset) {
    setState(() {
      _providerLabel = preset.label;
      if (preset.baseUrl.isNotEmpty) _baseController.text = preset.baseUrl;
      if (preset.models.isNotEmpty) {
        _models
          ..clear()
          ..addAll(preset.models);
        _selectedModel = preset.models.first;
      }
    });
  }

  void _addModel() {
    final model = _newModelController.text.trim();
    if (model.isEmpty || _models.contains(model)) return;
    setState(() {
      _models.add(model);
      _selectedModel = model;
      _newModelController.clear();
    });
  }

  Future<void> _fetchModels() async {
    final baseUrl = _baseController.text.trim();
    if (baseUrl.isEmpty || _fetchingModels) return;
    setState(() {
      _fetchingModels = true;
      _fetchError = null;
    });
    try {
      final fetched = await fetchProviderModels(
        baseUrl,
        _keyController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        if (fetched.isEmpty) {
          _fetchError = 'Endpoint tidak mengembalikan daftar model.';
          return;
        }
        // Merge so manually-added models are not lost.
        final merged = {..._models, ...fetched}.toList()..sort();
        _models
          ..clear()
          ..addAll(merged);
        if (!_models.contains(_selectedModel)) _selectedModel = _models.first;
      });
    } catch (error) {
      if (mounted) setState(() => _fetchError = 'Gagal memuat model: $error');
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  void _removeModel(String model) {
    if (_models.length == 1) return;
    setState(() {
      _models.remove(model);
      if (_selectedModel == model) _selectedModel = _models.first;
    });
  }

  void _save() {
    final baseUrl = _baseController.text.trim();
    final parsedBase = Uri.tryParse(baseUrl);
    if (baseUrl.isEmpty || parsedBase == null || !parsedBase.isAbsolute) return;
    Navigator.pop(
      context,
      _ModelSettingsResult(
        baseUrl: baseUrl,
        apiKey: _keyController.text.trim(),
        models: _models,
        selectedModel: _selectedModel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.dividerColor),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height - 64,
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                children: [
                  const Text(
                    'MODEL CONNECTION',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Tutup',
                    icon: const Icon(Icons.close, size: 19),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('model-dialog-scroll'),
                primary: true,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FieldLabel('PROVIDER'),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: const ValueKey('provider-preset'),
                          value: _providerLabel,
                          isExpanded: true,
                          items: [
                            for (final preset in _providerPresets)
                              DropdownMenuItem(
                                value: preset.label,
                                child: Text(
                                  preset.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (label) {
                            if (label == null) return;
                            _applyPreset(
                              _providerPresets.firstWhere(
                                (preset) => preset.label == label,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _providerPresets
                          .firstWhere(
                            (preset) => preset.label == _providerLabel,
                            orElse: () => _providerPresets.first,
                          )
                          .keyHint,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _FieldLabel('BASE URL'),
                    TextField(
                      controller: _baseController,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const _FieldLabel('AVAILABLE MODELS'),
                        const Spacer(),
                        if (_fetchingModels)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        else
                          TextButton.icon(
                            key: const ValueKey('fetch-models-button'),
                            onPressed: _fetchModels,
                            icon: const Icon(
                              Icons.cloud_download_outlined,
                              size: 15,
                            ),
                            label: const Text(
                              'FETCH FROM PROVIDER',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                    if (_fetchError != null) ...[
                      Text(
                        _fetchError!,
                        style: TextStyle(fontSize: 11, color: colors.error),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Container(
                      constraints: const BoxConstraints(maxHeight: 160),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _models.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final model = _models[index];
                          final selected = model == _selectedModel;
                          return ListTile(
                            dense: true,
                            onTap: () => setState(() => _selectedModel = model),
                            leading: Icon(
                              selected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 17,
                              color: selected
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            title: Text(
                              model,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                              ),
                            ),
                            trailing: IconButton(
                              onPressed: _models.length == 1
                                  ? null
                                  : () => _removeModel(model),
                              tooltip: 'Hapus model',
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newModelController,
                            onSubmitted: (_) => _addModel(),
                            decoration: const InputDecoration(
                              hintText: 'Model ID, contoh gpt-4.1',
                            ),
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _newModelController,
                          builder: (context, value, _) => FilledButton.icon(
                            onPressed: value.text.trim().isEmpty
                                ? null
                                : _addModel,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('ADD MODEL'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const _FieldLabel('API KEY'),
                    TextField(
                      key: const ValueKey('model-api-key-field'),
                      controller: _keyController,
                      obscureText: true,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your API key is kept in memory and is not stored on disk.',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      shape: const RoundedRectangleBorder(),
                      side: BorderSide(color: theme.dividerColor),
                    ),
                    child: const Text('CANCEL'),
                  ),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('SAVE MODELS'),
                  ),
                ],
              ),
            ),
            SizedBox(height: 2, child: ColoredBox(color: colors.primary)),
          ],
        ),
      ),
    );
  }
}

class _ModelSettingsResult {
  const _ModelSettingsResult({
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    required this.selectedModel,
  });

  final String baseUrl;
  final String apiKey;
  final List<String> models;
  final String selectedModel;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _StaticField extends StatelessWidget {
  const _StaticField({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
      ),
      child: Text(
        value,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
      ),
    );
  }
}

class _PermissionDialog extends StatelessWidget {
  const _PermissionDialog({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final command = title.toLowerCase().contains('perintah');
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Color(0xFF444938)),
      ),
      child: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    color: const Color(0xFFC6F269),
                    child: const Icon(
                      Icons.shield,
                      color: Color(0xFF253500),
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          command ? 'ALLOW COMMAND?' : 'ALLOW FILE CHANGE?',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          command
                              ? 'The AI is requesting permission to run this command.'
                              : 'The AI is requesting permission to apply this change.',
                          style: const TextStyle(color: Color(0xFFC4C9B2)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0F07),
                border: Border.all(color: const Color(0xFF444938)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  detail,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.5,
                    color: Color(0xFFE2E4D5),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1D14),
                border: Border(top: BorderSide(color: Color(0xFF444938))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, PermissionDecision.reject),
                    style: OutlinedButton.styleFrom(
                      shape: const RoundedRectangleBorder(),
                      side: const BorderSide(color: Color(0xFF444938)),
                    ),
                    child: const Text('REJECT'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, PermissionDecision.allowAlways),
                    child: const Text('ALLOW ALWAYS'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, PermissionDecision.allowOnce),
                    child: const Text('ALLOW ONCE'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalPermissionDialog extends StatelessWidget {
  const _TerminalPermissionDialog({
    required this.detail,
    required this.workspace,
  });

  final String detail;
  final String workspace;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Color(0xFF252A32)),
      ),
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0x1AFFB000),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.shield,
                      color: Color(0xFFFFB000),
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ALLOW TERMINAL COMMAND?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The AI agent is requesting permission to execute this command in the project workspace.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFC4C9B2), height: 1.45),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0F07),
                border: Border.all(color: const Color(0xFF444938)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.terminal,
                    size: 19,
                    color: Color(0xFF8E937F),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      detail,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 13,
                        color: Color(0xFFC6F269),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 13,
                    color: Color(0xFF8E937F),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Working Directory: $workspace',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                        color: Color(0xFF8E937F),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.pop(context, PermissionDecision.reject),
                      child: const Text('REJECT'),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: Color(0xFF252A32)),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        PermissionDecision.allowAlways,
                      ),
                      child: const Text('ALLOW ALWAYS'),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: Color(0xFF252A32)),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.pop(context, PermissionDecision.allowOnce),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('ALLOW ONCE'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionErrorDialog extends StatelessWidget {
  const _ConnectionErrorDialog({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Color(0xFF444938)),
      ),
      child: SizedBox(
        width: 460,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline, color: Color(0xFFFF7B72), size: 34),
                  SizedBox(width: 14),
                  Text(
                    'CONNECTION FAILED',
                    style: TextStyle(
                      color: Color(0xFFFF7B72),
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'Unable to establish a secure connection with the model provider.',
                style: TextStyle(height: 1.45),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0F07),
                  border: Border.all(color: const Color(0xFF444938)),
                ),
                child: SelectableText(
                  detail,
                  maxLines: 5,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: Color(0xFFC4C9B2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'TROUBLESHOOTING',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: Color(0xFF8E937F),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Check your internet connection\n'
                '2. Verify the API key in Model Settings\n'
                '3. Ensure the Base URL and model are valid',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  height: 1.65,
                  color: Color(0xFFC4C9B2),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('MODEL SETTINGS'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('CLOSE'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectSettingsDialog extends StatefulWidget {
  const _ProjectSettingsDialog({
    required this.workspace,
    required this.allowWrite,
    required this.allowTerminal,
    required this.approvalMode,
    required this.environment,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    required this.timeoutMs,
    required this.headers,
    required this.onSave,
  });

  final String workspace;
  final bool allowWrite;
  final bool allowTerminal;
  final ApprovalMode approvalMode;
  final Map<String, String> environment;
  final String baseUrl;
  final String model;
  final String apiKey;
  final int timeoutMs;
  final Map<String, String> headers;
  final Future<void> Function(
    bool allowWrite,
    bool allowTerminal,
    ApprovalMode approvalMode,
    Map<String, String> environment,
    _ApiConfiguration api,
  )
  onSave;

  @override
  State<_ProjectSettingsDialog> createState() => _ProjectSettingsDialogState();
}

class _ProjectSettingsDialogState extends State<_ProjectSettingsDialog> {
  late bool _allowWrite = widget.allowWrite;
  late bool _allowTerminal = widget.allowTerminal;
  late ApprovalMode _approvalMode = widget.approvalMode;
  late final _projectController = TextEditingController(
    text: widget.workspace.isEmpty ? 'No workspace selected' : widget.workspace,
  );
  final _keyController = TextEditingController();
  final _valueController = TextEditingController();
  late final _apiBaseController = TextEditingController(text: widget.baseUrl);
  late final _apiModelController = TextEditingController(text: widget.model);
  late final _apiKeyController = TextEditingController(text: widget.apiKey);
  late final _timeoutController = TextEditingController(
    text: '${widget.timeoutMs}',
  );
  final _headerKeyController = TextEditingController();
  final _headerValueController = TextEditingController();
  late final _environment = {...widget.environment};
  late final _headers = {...widget.headers};
  bool _testingConnection = false;
  String? _connectionStatus;
  int _tab = 0;

  @override
  void dispose() {
    _projectController.dispose();
    _keyController.dispose();
    _valueController.dispose();
    _apiBaseController.dispose();
    _apiModelController.dispose();
    _apiKeyController.dispose();
    _timeoutController.dispose();
    _headerKeyController.dispose();
    _headerValueController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.onSave(
      _allowWrite,
      _allowTerminal,
      _approvalMode,
      _environment,
      _apiConfiguration,
    );
    if (mounted) Navigator.pop(context);
  }

  _ApiConfiguration get _apiConfiguration => _ApiConfiguration(
    baseUrl: _apiBaseController.text.trim(),
    model: _apiModelController.text.trim(),
    apiKey: _apiKeyController.text.trim(),
    timeoutMs: int.tryParse(_timeoutController.text) ?? 120000,
    headers: _headers,
  );

  Future<void> _testConnection() async {
    if (_testingConnection) return;
    setState(() {
      _testingConnection = true;
      _connectionStatus = null;
    });
    final api = _apiConfiguration;
    try {
      final base = api.baseUrl.replaceAll(RegExp(r'/$'), '');
      final response = await http
          .get(
            Uri.parse('$base/models'),
            headers: {...api.headers, 'Authorization': 'Bearer ${api.apiKey}'},
          )
          .timeout(Duration(milliseconds: api.timeoutMs));
      if (mounted) {
        setState(
          () => _connectionStatus =
              response.statusCode >= 200 && response.statusCode < 300
              ? 'CONNECTION SUCCESSFUL'
              : 'FAILED: HTTP ${response.statusCode}',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _connectionStatus = 'FAILED: $error');
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tabs = const [
      'GENERAL',
      'ENV VARIABLES',
      'PERMISSIONS',
      'SECURITY',
      'API',
    ];
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.dividerColor),
      ),
      child: SizedBox(
        width: 820,
        height: 680,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                children: [
                  const Text(
                    'PROJECT SETTINGS',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Configure environment, agent capabilities, and security.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Container(
              height: 46,
              color: colors.surface,
              child: Row(
                children: [
                  for (var index = 0; index < tabs.length; index++)
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: Ink(
                          decoration: BoxDecoration(
                            color: _tab == index
                                ? colors.primary.withValues(alpha: 0.12)
                                : Colors.transparent,
                            border: _tab == index
                                ? Border(
                                    top: BorderSide(
                                      color: colors.primary,
                                      width: 2,
                                    ),
                                  )
                                : null,
                          ),
                          child: InkWell(
                            onTap: () => setState(() => _tab = index),
                            highlightColor: const Color(0x3379D6CD),
                            splashColor: const Color(0x4479D6CD),
                            child: Center(
                              child: Text(
                                tabs[index],
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                  color: _tab == index
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: _mediumMotion,
                switchInCurve: _motionCurve,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.02, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: SingleChildScrollView(
                  key: ValueKey(_tab),
                  padding: const EdgeInsets.all(24),
                  child: _content(),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('DISCARD CHANGES'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('SAVE SETTINGS'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    return switch (_tab) {
      0 => _generalTab(),
      1 => _environmentTab(),
      2 => _permissionsTab(),
      3 => _securityTab(),
      _ => _apiTab(),
    };
  }

  Widget _generalTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('GENERAL', style: _SettingsHeading.style),
      const SizedBox(height: 16),
      const _FieldLabel('PROJECT NAME'),
      const _StaticField(value: 'YOUNZCODE WORKSPACE'),
      const SizedBox(height: 18),
      const _FieldLabel('ROOT DIRECTORY'),
      TextField(
        controller: _projectController,
        readOnly: true,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      ),
      const SizedBox(height: 18),
      const _FieldLabel('DEFAULT SHELL'),
      const _StaticField(value: 'PowerShell (Windows)'),
    ],
  );

  Widget _environmentTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('ENVIRONMENT VARIABLES', style: _SettingsHeading.style),
      const SizedBox(height: 8),
      const Text(
        'Variables are kept in memory for this session and are never written to disk.',
        style: TextStyle(fontSize: 11, color: Color(0xFF8E937F)),
      ),
      const SizedBox(height: 16),
      for (final entry in _environment.entries)
        Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: const Color(0xFF1A1D14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entry.key,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                ),
              ),
              Expanded(
                child: Text(
                  '•' * entry.value.length.clamp(4, 18),
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    color: Color(0xFF8E937F),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _environment.remove(entry.key)),
                icon: const Icon(
                  Icons.delete_outline,
                  size: 17,
                  color: Color(0xFFFF7B72),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keyController,
              decoration: const InputDecoration(hintText: 'KEY'),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _valueController,
              decoration: const InputDecoration(hintText: 'VALUE'),
              obscureText: true,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _keyController,
            builder: (context, value, _) => FilledButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () {
                      setState(() {
                        _environment[value.text.trim()] = _valueController.text;
                        _keyController.clear();
                        _valueController.clear();
                      });
                    },
              child: const Text('ADD'),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _permissionsTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('AGENT CAPABILITIES', style: _SettingsHeading.style),
      const SizedBox(height: 16),
      _PermissionSetting(
        title: 'FILE MODIFICATION',
        description:
            'Allow the agent to create and modify files in the workspace.',
        value: _allowWrite,
        onChanged: (value) => setState(() => _allowWrite = value),
      ),
      _PermissionSetting(
        title: 'TERMINAL COMMAND EXECUTION',
        description:
            'Allow the agent to run PowerShell commands in the workspace.',
        value: _allowTerminal,
        onChanged: (value) => setState(() => _allowTerminal = value),
      ),
      const _PermissionSetting(
        title: 'NETWORK ACCESS',
        description:
            'Model requests use the configured provider. Approved terminal commands use normal system access.',
        value: true,
        locked: true,
      ),
      const SizedBox(height: 22),
      const Text(
        'HOW SHOULD AGENT ACTIONS BE APPROVED?',
        style: _SettingsHeading.style,
      ),
      const SizedBox(height: 12),
      _ApprovalModeSetting(
        value: _approvalMode,
        onChanged: (value) => setState(() => _approvalMode = value),
      ),
    ],
  );

  Widget _securityTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('SECURITY & INFRASTRUCTURE', style: _SettingsHeading.style),
      const SizedBox(height: 16),
      const _SecurityCard(
        icon: Icons.shield,
        title: 'DATA PROTECTION',
        body:
            'Built-in file tools stay in the workspace and block .env and SSH credentials.',
      ),
      const SizedBox(height: 10),
      const _SecurityCard(
        icon: Icons.list_alt,
        title: 'AUDIT LOGGING',
        body:
            'Tool activity is shown in the activity panel for the current session.',
      ),
      const SizedBox(height: 10),
      _SecurityCard(
        icon: Icons.lock,
        title: 'SESSION SECURITY',
        body: _approvalMode == ApprovalMode.askForApproval
            ? 'API keys stay in memory. Permission prompts apply once per action.'
            : 'API keys stay in memory. Action approval follows the selected permission mode.',
      ),
      const SizedBox(height: 10),
      const _SecurityCard(
        icon: Icons.terminal,
        title: 'TERMINAL ACCESS',
        body:
            'Approved PowerShell commands run with your normal Windows account permissions and are not sandboxed.',
      ),
    ],
  );

  Widget _apiTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('API CONFIGURATION', style: _SettingsHeading.style),
      const SizedBox(height: 8),
      const Text(
        'Configure the OpenAI-compatible connection used by the agent.',
        style: TextStyle(fontSize: 11, color: Color(0xFF8E937F)),
      ),
      const SizedBox(height: 16),
      const _FieldLabel('BASE URL'),
      TextField(
        controller: _apiBaseController,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      ),
      const SizedBox(height: 12),
      const _FieldLabel('MODEL'),
      TextField(
        controller: _apiModelController,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      ),
      const SizedBox(height: 12),
      const _FieldLabel('TOKEN VALUE'),
      TextField(
        controller: _apiKeyController,
        obscureText: true,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      ),
      const SizedBox(height: 12),
      const _FieldLabel('MODEL & COMMAND INACTIVITY TIMEOUT (MS)'),
      TextField(
        controller: _timeoutController,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          helperText:
              'Default 120000 (2 minutes). Increase for slow models, builds, '
              'or tests. Each task also stops after 10 minutes total.',
        ),
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      ),
      const SizedBox(height: 18),
      const Text('GLOBAL HEADERS', style: _SettingsHeading.style),
      const SizedBox(height: 8),
      for (final entry in _headers.entries)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            entry.key,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: Color(0xFF79D6CD),
            ),
          ),
          subtitle: Text(
            entry.value,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
          ),
          trailing: IconButton(
            onPressed: () => setState(() => _headers.remove(entry.key)),
            icon: const Icon(Icons.delete_outline, color: Color(0xFFFF7B72)),
          ),
        ),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _headerKeyController,
              decoration: const InputDecoration(hintText: 'HEADER KEY'),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _headerValueController,
              decoration: const InputDecoration(hintText: 'VALUE'),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _headerKeyController,
            builder: (context, value, _) => IconButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () {
                      setState(() {
                        _headers[value.text.trim()] =
                            _headerValueController.text;
                        _headerKeyController.clear();
                        _headerValueController.clear();
                      });
                    },
              icon: const Icon(Icons.add_circle),
            ),
          ),
        ],
      ),
      if (_connectionStatus != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _connectionStatus!,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 10,
              color: _connectionStatus!.startsWith('CONNECTION')
                  ? const Color(0xFFC6F269)
                  : const Color(0xFFFF7B72),
            ),
          ),
        ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: _testingConnection ? null : _testConnection,
        icon: const Icon(Icons.network_check),
        label: Text(_testingConnection ? 'TESTING...' : 'TEST CONNECTION'),
      ),
      const SizedBox(height: 24),
      const Text('AVAILABLE TOOLS', style: _SettingsHeading.style),
      const SizedBox(height: 12),
      if (_allowWrite)
        const _ApiTool(
          name: 'list_files',
          method: 'TOOL',
          description: 'List files matching a workspace glob.',
        ),
      if (_allowWrite)
        const _ApiTool(
          name: 'read_file',
          method: 'TOOL',
          description: 'Read a text file inside the workspace.',
        ),
      if (_allowTerminal)
        const _ApiTool(
          name: 'search_text',
          method: 'TOOL',
          description: 'Search a regex using ripgrep.',
        ),
      const _ApiTool(
        name: 'write_file',
        method: 'TOOL',
        description: 'Create or overwrite a file after permission.',
      ),
      const _ApiTool(
        name: 'replace_text',
        method: 'TOOL',
        description: 'Replace one unique text occurrence after permission.',
      ),
      const _ApiTool(
        name: 'run_command',
        method: 'TOOL',
        description: 'Run PowerShell after permission.',
      ),
    ],
  );
}

class _SettingsHeading {
  static const style = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w900,
    letterSpacing: 0.6,
  );
}

class _ApiConfiguration {
  const _ApiConfiguration({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    required this.timeoutMs,
    required this.headers,
  });

  final String baseUrl;
  final String model;
  final String apiKey;
  final int timeoutMs;
  final Map<String, String> headers;
}

class _PermissionSetting extends StatelessWidget {
  const _PermissionSetting({
    required this.title,
    required this.description,
    required this.value,
    this.onChanged,
    this.locked = false,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.all(16),
      color: colors.surface,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: locked ? null : onChanged),
        ],
      ),
    );
  }
}

class _ApprovalModeSetting extends StatelessWidget {
  const _ApprovalModeSetting({required this.value, required this.onChanged});

  final ApprovalMode value;
  final ValueChanged<ApprovalMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const options = [
      (
        ApprovalMode.askForApproval,
        'ASK FOR APPROVAL',
        'Always ask before file changes, terminal commands, and external tools.',
      ),
      (
        ApprovalMode.approveForMe,
        'APPROVE FOR ME',
        'Auto-approve workspace edits and safe commands. Ask for potentially unsafe or external actions.',
      ),
      (
        ApprovalMode.fullAccess,
        'FULL ACCESS',
        'Unrestricted access to the internet and any file on your computer.',
      ),
    ];
    return RadioGroup<ApprovalMode>(
      groupValue: value,
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
      child: Column(
        children: [
          for (final option in options)
            Material(
              color: value == option.$1
                  ? colors.primary.withValues(alpha: 0.12)
                  : colors.surface,
              child: InkWell(
                onTap: () => onChanged(option.$1),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 2),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: value == option.$1
                          ? colors.primary
                          : theme.dividerColor,
                    ),
                  ),
                  child: Row(
                    children: [
                      Radio<ApprovalMode>(value: option.$1),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.$2,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              option.$3,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (value == option.$1)
                        Icon(Icons.check, color: colors.primary),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SecurityCard extends StatelessWidget {
  const _SecurityCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colors.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.7,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiTool extends StatelessWidget {
  const _ApiTool({
    required this.name,
    required this.method,
    required this.description,
  });

  final String name;
  final String method;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.primary, width: 2)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 3),
            color: colors.primary,
            alignment: Alignment.center,
            child: Text(
              method,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 9,
                color: Color(0xFF253500),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            name,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              color: colors.secondary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              description,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddonManagerDialog extends StatefulWidget {
  const _AddonManagerDialog({
    required this.addons,
    required this.onImportFile,
    required this.onImportFolder,
    required this.onToggle,
    required this.onRemove,
  });

  final List<Addon> addons;
  final Future<void> Function() onImportFile;
  final Future<void> Function() onImportFolder;
  final Future<void> Function(Addon addon, bool enabled) onToggle;
  final Future<void> Function(Addon addon) onRemove;

  @override
  State<_AddonManagerDialog> createState() => _AddonManagerDialogState();
}

class _AddonManagerDialogState extends State<_AddonManagerDialog> {
  late final List<Addon> _addons = [...widget.addons];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: 760,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  const Icon(
                    Icons.extension_outlined,
                    color: Color(0xFFC6F269),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'ADD-ON MANAGER',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onImportFolder,
                    icon: const Icon(Icons.folder_copy_outlined, size: 16),
                    label: const Text('IMPORT FOLDER'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: widget.onImportFile,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('IMPORT FILE'),
                  ),
                  IconButton(
                    key: const ValueKey('close-addon-manager'),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close Add-on Manager',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: Text(
                'Supported: YOUNZCODE plugins, OpenCode/Claude SKILL.md, MCP JSON, and VSIX. Imported code is never executed during installation.',
                style: TextStyle(fontSize: 10, color: Color(0xFF8E937F)),
              ),
            ),
            Expanded(
              child: _addons.isEmpty
                  ? const Center(
                      child: Text(
                        'No add-ons installed',
                        style: TextStyle(color: Color(0xFF8E937F)),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(14),
                      itemCount: _addons.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final addon = _addons[index];
                        return Container(
                          key: ValueKey('addon-${addon.id}'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF171A12),
                            border: Border.all(color: const Color(0xFF34392D)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _addonIcon(addon.kind),
                                color: const Color(0xFF79D6CD),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      addon.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      addon.description,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFFA5AA98),
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      _addonStatus(addon),
                                      style: const TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 9,
                                        color: Color(0xFFFFC857),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: addon.enabled,
                                onChanged: (value) async {
                                  await widget.onToggle(addon, value);
                                  if (!mounted) return;
                                  // Re-find by id: the captured index may be
                                  // stale after the await if the list changed.
                                  final i = _addons.indexWhere(
                                    (item) => item.id == addon.id,
                                  );
                                  if (i >= 0) {
                                    setState(
                                      () => _addons[i] = addon.copyWith(
                                        enabled: value,
                                      ),
                                    );
                                  }
                                },
                              ),
                              IconButton(
                                onPressed: () async {
                                  await widget.onRemove(addon);
                                  if (!mounted) return;
                                  setState(
                                    () => _addons.removeWhere(
                                      (item) => item.id == addon.id,
                                    ),
                                  );
                                },
                                tooltip: 'Remove add-on',
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _addonIcon(AddonKind kind) => switch (kind) {
    AddonKind.skill => Icons.psychology_outlined,
    AddonKind.mcpServer => Icons.hub_outlined,
    AddonKind.nativePlugin => Icons.extension_outlined,
    AddonKind.vsix => Icons.inventory_2_outlined,
  };

  static String _addonStatus(Addon addon) => switch (addon.kind) {
    AddonKind.skill => 'ACTIVE AS AGENT INSTRUCTIONS',
    AddonKind.nativePlugin =>
      'MANIFEST/PROMPT ACTIVE · CODE EXECUTION DISABLED',
    AddonKind.vsix => 'STORED ONLY · VS CODE API RUNTIME NOT EMBEDDED',
    AddonKind.mcpServer =>
      (addon.metadata as McpMetadata).servers.any(
            (server) => server.transport == McpTransport.stdio,
          )
          ? 'MCP STDIO TOOLS ACTIVE'
          : 'MCP HTTP TOOLS ACTIVE',
  };
}

class _ChatHistoryDialog extends StatelessWidget {
  const _ChatHistoryDialog({
    required this.sessions,
    required this.activeId,
    required this.onOpen,
    required this.onDelete,
  });

  final List<ChatSession> sessions;
  final String activeId;
  final ValueChanged<ChatSession> onOpen;
  final ValueChanged<ChatSession> onDelete;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.history, size: 20),
          SizedBox(width: 9),
          Text('CHAT HISTORY'),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: sessions.isEmpty
            ? const Center(
                child: Text(
                  'Belum ada percakapan tersimpan di workspace ini.',
                  style: TextStyle(color: Color(0xFF8E937F)),
                ),
              )
            : ListView.separated(
                itemCount: sessions.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  final active = session.id == activeId;
                  return ListTile(
                    key: ValueKey('chat-session-${session.id}'),
                    selected: active,
                    leading: Icon(
                      active ? Icons.chat_bubble : Icons.chat_bubble_outline,
                      color: active
                          ? const Color(0xFFC6F269)
                          : const Color(0xFF79D6CD),
                    ),
                    title: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${session.entries.length} pesan  ·  '
                      '${_formatChatDate(session.updatedAt)}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    onTap: () => onOpen(session),
                    trailing: IconButton(
                      onPressed: () => onDelete(session),
                      tooltip: 'Hapus percakapan',
                      icon: const Icon(Icons.delete_outline, size: 17),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('TUTUP'),
        ),
      ],
    );
  }

  static String _formatChatDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _SearchView extends StatelessWidget {
  const _SearchView({
    super.key,
    required this.controller,
    required this.results,
    required this.busy,
    required this.onSearch,
    required this.onClose,
    required this.onOpenResult,
  });

  final TextEditingController controller;
  final List<String> results;
  final bool busy;
  final VoidCallback onSearch;
  final VoidCallback onClose;
  final void Function(String path, int line) onOpenResult;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          color: const Color(0xFF0D0F07),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    'SEARCH WORKSPACE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                onSubmitted: (_) {
                  if (!busy && controller.text.trim().isNotEmpty) onSearch();
                },
                style: const TextStyle(fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search files, symbols, or code...',
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => IconButton(
                      onPressed: busy || value.text.trim().isEmpty
                          ? null
                          : onSearch,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : results.isEmpty
              ? Center(
                  child: Text(
                    controller.text.isEmpty
                        ? 'ENTER A QUERY TO SEARCH THE WORKSPACE'
                        : 'NO MATCHES FOUND',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      color: Color(0xFF8E937F),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(24),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final line = results[index];
                    final firstColon = line.indexOf(':');
                    final secondColon = firstColon < 0
                        ? -1
                        : line.indexOf(':', firstColon + 1);
                    final path = firstColon > 0
                        ? line.substring(0, firstColon)
                        : line;
                    final number = secondColon > firstColon
                        ? line.substring(firstColon + 1, secondColon)
                        : '';
                    final content = secondColon >= 0
                        ? line.substring(secondColon + 1)
                        : '';
                    return InkWell(
                      onTap: () =>
                          onOpenResult(path, int.tryParse(number) ?? 1),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A1D14),
                          border: Border(
                            left: BorderSide(
                              color: Color(0xFF79D6CD),
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 220,
                              child: Text(
                                path,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 10,
                                  color: Color(0xFF79D6CD),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 42,
                              child: Text(
                                number,
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 10,
                                  color: Color(0xFF8E937F),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                content,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _QuickFileDialog extends StatefulWidget {
  const _QuickFileDialog({required this.files});

  final List<String> files;

  @override
  State<_QuickFileDialog> createState() => _QuickFileDialogState();
}

class _QuickFileDialogState extends State<_QuickFileDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.toLowerCase();
    final matches = widget.files
        .where((file) => file.toLowerCase().contains(query))
        .take(100)
        .toList();
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                key: const ValueKey('quick-file-search'),
                controller: _controller,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search files by name...  Ctrl+P',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (context, index) => ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 17,
                  ),
                  title: Text(
                    matches[index],
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, matches[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandPaletteDialog extends StatelessWidget {
  const _CommandPaletteDialog();

  @override
  Widget build(BuildContext context) {
    const actions = <(String, IconData, String)>[
      ('file', Icons.file_open_outlined, 'Open File'),
      ('chat', Icons.add_comment_outlined, 'New Chat'),
      ('search', Icons.manage_search, 'Search Workspace'),
      ('terminal', Icons.terminal, 'Toggle Terminal'),
      ('settings', Icons.tune, 'Project Settings'),
      ('model', Icons.psychology_outlined, 'Switch Model'),
      ('plan', Icons.account_tree_outlined, 'Toggle Plan Mode'),
    ];
    return Dialog(
      child: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.keyboard_command_key),
              title: Text('COMMAND PALETTE'),
              subtitle: Text('Ctrl+Shift+P'),
            ),
            const Divider(height: 1),
            for (final action in actions)
              ListTile(
                leading: Icon(action.$2, size: 18),
                title: Text(action.$3),
                onTap: () => Navigator.pop(context, action.$1),
              ),
          ],
        ),
      ),
    );
  }
}

class _GitDialog extends StatefulWidget {
  const _GitDialog({
    required this.status,
    required this.diff,
    required this.history,
    required this.onCreateBranch,
  });

  final GitStatus status;
  final String diff;
  final String history;
  final Future<void> Function(String name) onCreateBranch;

  @override
  State<_GitDialog> createState() => _GitDialogState();
}

class _GitDialogState extends State<_GitDialog> {
  final _branchController = TextEditingController();
  String? _branchError;

  @override
  void dispose() {
    _branchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 680,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(widget.status.branch),
                subtitle: Text(
                  widget.status.dirty
                      ? '${widget.status.files.length} changed files'
                      : 'Working tree clean',
                ),
                trailing: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'STATUS'),
                  Tab(text: 'DIFF'),
                  Tab(text: 'HISTORY'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final file in widget.status.files.entries)
                          ListTile(
                            dense: true,
                            leading: Text(file.value),
                            title: Text(
                              file.key,
                              style: const TextStyle(fontFamily: 'Consolas'),
                            ),
                          ),
                        const Divider(),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _branchController,
                                decoration: InputDecoration(
                                  labelText: 'New branch name',
                                  errorText: _branchError,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () async {
                                final name = _branchController.text.trim();
                                if (name.isEmpty) {
                                  setState(
                                    () => _branchError =
                                        'Nama branch tidak boleh kosong.',
                                  );
                                  return;
                                }
                                try {
                                  await widget.onCreateBranch(name);
                                  if (context.mounted) Navigator.pop(context);
                                } catch (error) {
                                  if (mounted) {
                                    setState(
                                      () => _branchError =
                                          'Gagal membuat branch: $error',
                                    );
                                  }
                                }
                              },
                              child: const Text('CREATE BRANCH'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    _CodeOutput(widget.diff.isEmpty ? 'No diff.' : widget.diff),
                    _CodeOutput(
                      widget.history.isEmpty ? 'No commits.' : widget.history,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CodeOutput extends StatelessWidget {
  const _CodeOutput(this.value);
  final String value;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: SelectableText(
      value,
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.4),
    ),
  );
}

class _AppNotification {
  const _AppNotification({
    required this.title,
    required this.body,
    required this.createdAt,
    required this.error,
  });

  final String title;
  final String body;
  final DateTime createdAt;
  final bool error;
}

class _NotificationDialog extends StatefulWidget {
  const _NotificationDialog({
    required this.notifications,
    required this.revision,
    required this.onDelete,
    required this.onClear,
  });

  final List<_AppNotification> notifications;
  final Listenable revision;
  final ValueChanged<_AppNotification> onDelete;
  final VoidCallback onClear;

  @override
  State<_NotificationDialog> createState() => _NotificationDialogState();
}

class _NotificationDialogState extends State<_NotificationDialog> {
  _AppNotification? _selected;

  void _delete(_AppNotification notification) {
    widget.onDelete(notification);
    setState(() {
      if (identical(_selected, notification)) _selected = null;
    });
  }

  void _clear() {
    widget.onClear();
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.revision,
    builder: (context, _) => AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Notifications')),
          if (widget.notifications.isNotEmpty)
            TextButton(
              key: const ValueKey('clear-all-notifications'),
              onPressed: _clear,
              child: const Text('CLEAR ALL'),
            ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: widget.notifications.isEmpty
            ? const Center(child: Text('No notifications.'))
            : Column(
                children: [
                  if (_selected != null)
                    Container(
                      key: const ValueKey('notification-detail'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selected!.title,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(_selected!.body),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.notifications.length,
                      itemBuilder: (context, index) {
                        final item = widget.notifications[index];
                        return ListTile(
                          key: ValueKey('notification-item-$index'),
                          selected: identical(_selected, item),
                          onTap: () => setState(() => _selected = item),
                          leading: Icon(
                            item.error
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            color: item.error
                                ? Theme.of(context).colorScheme.error
                                : const Color(0xFF28C76F),
                          ),
                          title: Text(item.title),
                          subtitle: Text(
                            item.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',
                              ),
                              IconButton(
                                key: ValueKey('delete-notification-$index'),
                                tooltip: 'Delete notification',
                                onPressed: () => _delete(item),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    ),
  );
}

class _OnboardingDialog extends StatelessWidget {
  const _OnboardingDialog({
    required this.workspaceConfigured,
    required this.providerConfigured,
    required this.model,
    required this.onWorkspace,
    required this.onProvider,
  });

  final bool workspaceConfigured;
  final bool providerConfigured;
  final String model;
  final Future<void> Function() onWorkspace;
  final Future<void> Function() onProvider;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.rocket_launch_outlined),
    title: const Text('Set Up YOUNZCODE'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _OnboardingStep(
              number: 1,
              title: 'Choose workspace',
              complete: workspaceConfigured,
              onTap: onWorkspace,
            ),
            _OnboardingStep(
              number: 2,
              title: 'Configure provider and test connection',
              complete: providerConfigured,
              onTap: onProvider,
            ),
            _OnboardingStep(
              number: 3,
              title: 'Selected model: $model',
              complete: true,
              onTap: onProvider,
            ),
            const _OnboardingStep(
              number: 4,
              title: 'Send your first prompt',
              complete: false,
            ),
            const SizedBox(height: 8),
            const Text(
              'Compatible templates: OpenAI, Ollama, LM Studio, and 9router through MODEL SETTINGS.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('START CODING'),
      ),
    ],
  );
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.number,
    required this.title,
    required this.complete,
    this.onTap,
  });

  final int number;
  final String title;
  final bool complete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(
      child: complete ? const Icon(Icons.check, size: 17) : Text('$number'),
    ),
    title: Text(title),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _ExecutionSummary extends StatelessWidget {
  const _ExecutionSummary({
    required this.activities,
    required this.turnState,
    this.onRetry,
    required this.duration,
    required this.pendingChanges,
    required this.canRevert,
    this.onReviewChanges,
    this.onRevert,
    required this.onHide,
  });

  final List<_AgentActivity> activities;
  final _AgentTurnState turnState;
  final VoidCallback? onRetry;
  final Duration duration;
  final WorkspaceTurnChanges? pendingChanges;
  final bool canRevert;
  final VoidCallback? onReviewChanges;
  final VoidCallback? onRevert;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final complete = activities.where((item) => item.completed).length;
    final failedTools = activities.where((item) => item.failed).length;
    final warningTools = activities.where((item) => item.warning).length;
    final toolIssues = failedTools + warningTools;
    final activityOutcome = turnState == _AgentTurnState.success
        ? toolIssues == 0
              ? ''
              : ' · $toolIssues tool warning${toolIssues == 1 ? '' : 's'}'
        : '${failedTools == 0 ? '' : ' · $failedTools failed'}'
              '${warningTools == 0 ? '' : ' · $warningTools skipped'}';
    final status = switch (turnState) {
      _AgentTurnState.success => (
        'STATUS: SUCCESS',
        Icons.check_circle,
        const Color(0xFFC6F269),
      ),
      _AgentTurnState.cancelled => (
        'STATUS: CANCELLED',
        Icons.stop_circle_outlined,
        const Color(0xFFFFC857),
      ),
      _AgentTurnState.timedOut => (
        'STATUS: TIMED OUT',
        Icons.timer_off_outlined,
        const Color(0xFFFF7B72),
      ),
      _AgentTurnState.paused => (
        'STATUS: CHECKPOINT SAVED',
        Icons.pause_circle_outline,
        const Color(0xFFFFC857),
      ),
      _AgentTurnState.failed => (
        'STATUS: FAILED',
        Icons.error_outline,
        const Color(0xFFFF7B72),
      ),
      _ => (
        'STATUS: COMPLETED WITH ERRORS',
        Icons.error_outline,
        const Color(0xFFFF7B72),
      ),
    };
    final canRetry =
        onRetry != null &&
        {
          _AgentTurnState.cancelled,
          _AgentTurnState.timedOut,
          _AgentTurnState.paused,
          _AgentTurnState.failed,
        }.contains(turnState);
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2117),
        border: Border.all(color: const Color(0xFF444938)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(status.$2, color: status.$3, size: 18),
              const SizedBox(width: 8),
              const Text(
                'EXECUTION SUMMARY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('hide-execution-summary'),
                tooltip: 'Hide execution summary',
                onPressed: onHide,
                icon: const Icon(Icons.expand_more, size: 18),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Text(
                status.$1,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 9,
                  color: status.$3,
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Text(
            '${activities.length} tool events · $complete completed'
            '$activityOutcome · '
            '${duration.inSeconds}s',
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: Color(0xFFC4C9B2),
            ),
          ),
          if (activities.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final activity in activities)
              Container(
                key: ValueKey('completed-tool-${activity.id}'),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF171A12),
                  border: Border(
                    left: BorderSide(
                      color: activity.failed
                          ? const Color(0xFFFF7B72)
                          : activity.warning
                          ? const Color(0xFFFFC857)
                          : const Color(0xFFC6F269),
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 58,
                      child: Text(
                        activity.label,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF79D6CD),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        activity.detail,
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                          height: 1.4,
                          color: activity.failed
                              ? const Color(0xFFFF7B72)
                              : activity.warning
                              ? const Color(0xFFFFC857)
                              : const Color(0xFFE2E4D5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (pendingChanges != null || canRevert) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (pendingChanges != null)
                  FilledButton.icon(
                    key: const ValueKey('summary-review-changes'),
                    onPressed: onReviewChanges,
                    icon: const Icon(Icons.difference_outlined, size: 16),
                    label: Text('REVIEW ${pendingChanges!.files.length} FILES'),
                  ),
                if (canRevert)
                  OutlinedButton.icon(
                    key: const ValueKey('summary-revert-turn'),
                    onPressed: onRevert,
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('REVERT TURN'),
                  ),
              ],
            ),
          ],
          if (canRetry) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('continue-from-checkpoint'),
              onPressed: onRetry,
              icon: const Icon(Icons.replay, size: 16),
              label: const Text('CONTINUE FROM CHECKPOINT'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExecutionSummaryToggle extends StatelessWidget {
  const _ExecutionSummaryToggle({
    required this.turnState,
    required this.duration,
    required this.onShow,
  });

  final _AgentTurnState turnState;
  final Duration duration;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final color = turnState == _AgentTurnState.success
        ? const Color(0xFFC6F269)
        : turnState == _AgentTurnState.cancelled ||
              turnState == _AgentTurnState.paused
        ? const Color(0xFFFFC857)
        : const Color(0xFFFF7B72);
    final label = turnState == _AgentTurnState.success
        ? 'SUCCESS'
        : turnState.name.toUpperCase();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('show-execution-summary'),
        onPressed: onShow,
        icon: Icon(Icons.expand_less, size: 17, color: color),
        label: Text(
          'SHOW EXECUTION SUMMARY  ·  $label  ·  ${duration.inSeconds}s',
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _AgentWorkingCard extends StatefulWidget {
  const _AgentWorkingCard({required this.status, required this.activities});

  final String status;
  final List<_AgentActivity> activities;

  @override
  State<_AgentWorkingCard> createState() => _AgentWorkingCardState();
}

class _AgentWorkingCardState extends State<_AgentWorkingCard>
    with SingleTickerProviderStateMixin {
  final _elapsed = Stopwatch()..start();
  late final Timer _elapsedTimer;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _elapsedTimer.cancel();
    _elapsed.stop();
    _controller.dispose();
    super.dispose();
  }

  String get _elapsedLabel {
    final totalSeconds = _elapsed.elapsed.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AgentWorkingPalette.fromTheme(Theme.of(context));
    return TweenAnimationBuilder<double>(
      duration: _mediumMotion,
      curve: _motionCurve,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey('agent-working-card'),
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: palette.background,
            border: Border.all(color: palette.border),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomRight: Radius.circular(12),
              bottomLeft: Radius.circular(3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final activity in widget.activities)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 18,
                        child: activity.succeeded
                            ? Icon(Icons.check, size: 14, color: palette.accent)
                            : activity.failed
                            ? Icon(Icons.close, size: 14, color: palette.error)
                            : activity.warning
                            ? Icon(
                                Icons.remove,
                                size: 14,
                                color: palette.mutedText,
                              )
                            : SizedBox(
                                width: 14,
                                height: 14,
                                child: AnimatedBuilder(
                                  animation: _controller,
                                  builder: (context, _) => CustomPaint(
                                    painter: _AgentOrbitPainter(
                                      _controller.value,
                                      orbitColor: palette.orbit,
                                      dotColor: palette.accent,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 54,
                        child: Text(
                          activity.label,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: palette.activity,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Tooltip(
                          message: activity.detail,
                          child: Text(
                            activity.detail,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                              height: 1.35,
                              color: activity.failed
                                  ? palette.error
                                  : activity.warning
                                  ? palette.mutedText
                                  : palette.primaryText,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.activities.isNotEmpty) const Divider(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    key: const ValueKey('response-loading-animation'),
                    width: 120,
                    height: 86,
                    child: Lottie.asset(
                      'assets/younzcode_cat_loading.lottie',
                      decoder: decodeDotLottie,
                      fit: BoxFit.contain,
                      repeat: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: SizedBox(
                      width: 64,
                      child: Text(
                        'Thinking',
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: palette.accent,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSwitcher(
                            duration: _fastMotion,
                            child: Text(
                              widget.status,
                              key: ValueKey(widget.status),
                              style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                color: palette.secondaryText,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_elapsedLabel  ·  '
                            '${widget.activities.where((item) => item.completed).length} '
                            'of ${widget.activities.length} actions completed',
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 10,
                              color: palette.mutedText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentOrbitPainter extends CustomPainter {
  const _AgentOrbitPainter(
    this.progress, {
    required this.orbitColor,
    required this.dotColor,
  });

  final double progress;
  final Color orbitColor;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final orbit = Paint()
      ..color = orbitColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final dot = Paint()..color = dotColor;
    canvas.drawCircle(center, size.shortestSide * 0.34, orbit);
    final angle = progress * 6.283185307179586;
    final radius = size.shortestSide * 0.34;
    canvas.drawCircle(
      center + Offset(radius * math.cos(angle), radius * math.sin(angle)),
      3,
      dot,
    );
  }

  @override
  bool shouldRepaint(covariant _AgentOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.orbitColor != orbitColor ||
      oldDelegate.dotColor != dotColor;
}
