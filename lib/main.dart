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

part 'ui/chrome.dart';
part 'ui/editor.dart';
part 'ui/inspector.dart';
part 'ui/provider_presets.dart';
part 'ui/dialogs.dart';
part 'ui/overlays.dart';

const _fastMotion = Duration(milliseconds: 140);
const _mediumMotion = Duration(milliseconds: 240);
const _motionCurve = Curves.easeOutCubic;
const _appVersion = '1.1.0';

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
