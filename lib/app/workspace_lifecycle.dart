part of '../main.dart';

extension _WorkspaceLifecycle on _AgentHomePageState {
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
    final toolPolicies = await _toolPermissionStore
        .load(workspace)
        .catchError((_) => <String, ToolPermissionPolicy>{});
    if (!mounted) return;
    final workspaceSessions = sessions
        .where((session) => session.workspace == workspace)
        .toList();
    _updateState(() {
      _baseUrl = settings.baseUrl;
      _fallbackBaseUrls = List.of(settings.fallbackBaseUrls);
      _inputCostPerMillion = settings.inputCostPerMillion;
      _outputCostPerMillion = settings.outputCostPerMillion;
      _monthlyTokenBudget = settings.monthlyTokenBudget;
      _qualityGateEnabled = settings.qualityGateEnabled;
      _model = settings.model;
      _models
        ..clear()
        ..addAll(settings.models);
      _workspace = workspace;
      _allowWrite = settings.allowWrite;
      _allowTerminal = settings.allowTerminal;
      _approvalMode = settings.approvalMode;
      _timeoutMs = settings.timeoutMs;
      _dapTimeoutMs = settings.dapTimeoutMs;
      _chatSessions
        ..clear()
        ..addAll(sessions);
      _addons
        ..clear()
        ..addAll(addons);
      _toolPermissionPolicies
        ..clear()
        ..addAll(toolPolicies);
      if (workspaceSessions.isNotEmpty) {
        _activeChatId = workspaceSessions.first.id;
        _entries
          ..clear()
          ..addAll(workspaceSessions.first.entries);
        _agentCheckpoint
          ..clear()
          ..addAll(workspaceSessions.first.agentMessages);
        _goal = _goalRestoredFromSession(workspaceSessions.first.goal);
      }
      _loading = false;
      _workspaceTrusted = trusted;
    });
    if (workspace != settings.workspace) unawaited(_saveSettings());
    if (_entries.isNotEmpty) _scrollToBottom();
    unawaited(_refreshGit());
    unawaited(_loadCheckpointHistory(workspace));
    unawaited(_initializeCodeIntelligence(workspace));
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
    final toolPolicies = await _toolPermissionStore
        .load(selected)
        .catchError((_) => <String, ToolPermissionPolicy>{});
    await _persistActiveChat();
    await _agent?.dispose();
    await _terminalService.dispose();
    _updateState(() {
      for (final document in _documents) {
        document.dispose();
      }
      _documents.clear();
      _activeFile = null;
      _terminalOutput.clear();
      _workspace = selected;
      _workspaceTrusted = trust == true;
      _browserMode = false;
      _browserInitialUrl = null;
      _budgetWarningShown = false;
      _agent = null;
      _entries.clear();
      _agentCheckpoint.clear();
      _goal = null;
      _toolPermissionPolicies
        ..clear()
        ..addAll(toolPolicies);
      final workspaceSessions =
          _chatSessions
              .where((session) => session.workspace == selected)
              .toList()
            ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      if (workspaceSessions.isNotEmpty) {
        _activeChatId = workspaceSessions.first.id;
        _entries.addAll(workspaceSessions.first.entries);
        _agentCheckpoint.addAll(workspaceSessions.first.agentMessages);
        _goal = _goalRestoredFromSession(workspaceSessions.first.goal);
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
    await _loadCheckpointHistory(selected);
    await _initializeCodeIntelligence(selected);
    if (_entries.isNotEmpty) _scrollToBottom();
  }

  Future<void> _loadCheckpointHistory(String workspace) async {
    final history = await _checkpointStore.load(workspace);
    if (!mounted || workspace != _workspace) return;
    _updateState(() {
      _changeHistory
        ..clear()
        ..addAll(history);
      _lastAppliedTurn = null;
    });
  }

  Future<void> _initializeCodeIntelligence(String workspace) async {
    final service = workspace.isEmpty
        ? null
        : CodeIntelligenceService(workspace);
    _codeIntelligence = service;
    if (service == null) return;
    await service.ensureIndexed();
    if (!mounted || workspace != _workspace || _codeIntelligence != service) {
      return;
    }
    final identifiers = service.symbolNames;
    for (final document in _documents) {
      document.controller.workspaceIdentifiers = identifiers;
    }
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
    _updateState(() {
      _searchMode = true;
      _imageGenerationMode = false;
      _browserMode = false;
    });
  }

  void _openImageGeneration() {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum membuka Image Generation.');
      return;
    }
    _updateState(() {
      _activeFile = null;
      _searchMode = false;
      _imageGenerationMode = true;
      _browserMode = false;
    });
  }

  Future<void> _searchWorkspace() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searchBusy) return;
    _updateState(() {
      _searchBusy = true;
      _searchResults = [];
    });
    final searchedWorkspace = _workspace;
    try {
      final service =
          _codeIntelligence ?? CodeIntelligenceService(searchedWorkspace);
      _codeIntelligence = service;
      final result = await service.search(query, limit: 500);
      if (!mounted || searchedWorkspace != _workspace) return;
      _updateState(() {
        _searchResults = result.map((item) => item.displayLine).toList();
      });
    } catch (error) {
      if (mounted) _showMessage('Pencarian gagal: $error');
    } finally {
      if (mounted) _updateState(() => _searchBusy = false);
    }
  }
}
