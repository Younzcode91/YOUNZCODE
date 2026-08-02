part of '../main.dart';

extension _AgentConfiguration on _AgentHomePageState {
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
      fallbackBaseUrls: _fallbackBaseUrls,
      inputCostPerMillion: _inputCostPerMillion,
      outputCostPerMillion: _outputCostPerMillion,
      monthlyTokenBudget: _monthlyTokenBudget,
      qualityGateEnabled: _qualityGateEnabled,
    ),
  );

  AgentService _createAgent({String? baseUrl, String? model}) {
    final ownerChatId = _activeChatId;
    final ownerWorkspace = _workspace;
    final providerBaseUrl = baseUrl ?? _baseUrl;
    final providerModel = model ?? _model;
    return AgentService(
      baseUrl: providerBaseUrl,
      apiKey: _apiKey,
      model: providerModel,
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
      browser: _workspaceTrusted && !_planMode ? _browserService : null,
      requestPermission: _requestPermission,
      onToolActivity: (id, name, detail, state) {
        if (!mounted) return;
        _updateState(() {
          if (name.startsWith('browser_') && state == 'berjalan') {
            _browserTurnNavigation.browserToolStarted(
              browserWasVisible: _browserMode,
            );
            _activeFile = null;
            _searchMode = false;
            _imageGenerationMode = false;
            _browserMode = true;
          }
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
        _updateState(() => _agentStatus = status);
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
        _updateState(() {
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
        _updateState(() {
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
        _recordProviderUsage(
          baseUrl: providerBaseUrl,
          model: providerModel,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
        );
      },
      toolPermissionPolicies: _toolPermissionPolicies,
      onToolPermissionChanged: (pattern, policy) {
        _toolPermissionPolicies[pattern] = policy;
        unawaited(_toolPermissionStore.set(ownerWorkspace, pattern, policy));
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

  void _recordProviderUsage({
    required String baseUrl,
    required String model,
    required int? promptTokens,
    required int? completionTokens,
    required int? totalTokens,
  }) {
    final prompt = promptTokens ?? 0;
    final completion = completionTokens ?? 0;
    final total = totalTokens ?? prompt + completion;
    if (total <= 0 || _workspace.isEmpty) return;
    final workspace = _workspace;
    final record = ProviderUsageRecord(
      timestamp: DateTime.now(),
      baseUrl: baseUrl,
      model: model,
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      estimatedCostUsd: ProviderUsageStore.estimateCost(
        promptTokens: prompt,
        completionTokens: completion,
        inputCostPerMillion: _inputCostPerMillion,
        outputCostPerMillion: _outputCostPerMillion,
      ),
    );
    unawaited(_persistProviderUsage(workspace, record));
  }

  Future<void> _persistProviderUsage(
    String workspace,
    ProviderUsageRecord record,
  ) async {
    await _providerUsageStore.record(workspace, record);
    if (_monthlyTokenBudget <= 0 ||
        _budgetWarningShown ||
        workspace != _workspace) {
      return;
    }
    final now = DateTime.now();
    final records = await _providerUsageStore.load(workspace);
    final summary = ProviderUsageStore.summarize(
      records,
      since: DateTime(now.year, now.month),
    );
    if (summary.totalTokens >= _monthlyTokenBudget * 0.8 && mounted) {
      _budgetWarningShown = true;
      _notify(
        'Token budget warning',
        '${summary.totalTokens} dari $_monthlyTokenBudget token bulan ini '
            'telah digunakan.',
      );
    }
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
    _updateState(() {
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
        onCheckMcp: _checkMcpAddon,
        toolPermissionPolicies: _toolPermissionPolicies,
        onToolPermissionChanged: _setToolPermission,
      ),
    );
  }

  Future<List<McpHealth>> _checkMcpAddon(Addon addon) async {
    if (addon.kind != AddonKind.mcpServer) return const [];
    final health = <McpHealth>[];
    for (final server in (addon.metadata as McpMetadata).servers) {
      final client = McpClient(server, workspace: _workspace);
      try {
        health.add(
          await client.healthCheck(
            approveLaunch: (command, arguments) async {
              final decision = await _requestPermission(
                'Test MCP connection',
                '${server.name}\n$command ${arguments.join(' ')}',
              );
              return decision == PermissionDecision.allowOnce ||
                  decision == PermissionDecision.allowAlways;
            },
          ),
        );
      } finally {
        await client.dispose();
      }
    }
    return health;
  }

  Future<void> _setToolPermission(
    String pattern,
    ToolPermissionPolicy policy,
  ) async {
    _toolPermissionPolicies[pattern] = policy;
    await _toolPermissionStore.set(_workspace, pattern, policy);
    await _disposeAgent();
    if (mounted) _updateState(() {});
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
      _updateState(() => _addons.add(addon));
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
    _updateState(() {
      final index = _addons.indexWhere((item) => item.id == addon.id);
      if (index != -1) _addons[index] = updated;
      _agent = null;
    });
  }

  Future<void> _removeAddon(Addon addon) async {
    await _addonService.remove(addon.id);
    unawaited(_agent?.dispose());
    if (!mounted) return;
    _updateState(() {
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
        fallbackBaseUrls: _fallbackBaseUrls,
        inputCostPerMillion: _inputCostPerMillion,
        outputCostPerMillion: _outputCostPerMillion,
        monthlyTokenBudget: _monthlyTokenBudget,
      ),
    );
    if (result == null) return;
    await _disposeAgent();
    late final String normalizedBaseUrl;
    late final List<String> normalizedFallbacks;
    try {
      normalizedBaseUrl = normalizeProviderBaseUrl(result.baseUrl);
      normalizedFallbacks = {
        for (final fallback in result.fallbackBaseUrls)
          normalizeProviderBaseUrl(fallback),
      }.where((fallback) => fallback != normalizedBaseUrl).toList();
    } on FormatException catch (error) {
      if (mounted) _showMessage('$error');
      return;
    }
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
    _updateState(() {
      _baseUrl = normalizedBaseUrl;
      _apiKey = result.apiKey;
      _models
        ..clear()
        ..addAll(normalizedModels);
      _model = normalizedSelectedModel;
      _fallbackBaseUrls = normalizedFallbacks;
      _inputCostPerMillion = result.inputCostPerMillion
          .clamp(0, double.infinity)
          .toDouble();
      _outputCostPerMillion = result.outputCostPerMillion
          .clamp(0, double.infinity)
          .toDouble();
      _monthlyTokenBudget = result.monthlyTokenBudget.clamp(0, 1 << 62).toInt();
      _budgetWarningShown = false;
      _providerVerified = false;
    });
    await _saveSettings();
  }

  Future<void> _selectModel(String model) async {
    final normalizedModel = normalizeProviderModel(model, baseUrl: _baseUrl);
    if (_busy || normalizedModel == _model) return;
    await _disposeAgent();
    _updateState(() {
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
        qualityGateEnabled: _qualityGateEnabled,
        approvalMode: _approvalMode,
        environment: _environment,
        baseUrl: _baseUrl,
        model: _model,
        apiKey: _apiKey,
        timeoutMs: _timeoutMs,
        headers: _apiHeaders,
        onSave:
            (
              write,
              terminal,
              qualityGateEnabled,
              approvalMode,
              variables,
              api,
            ) async {
              await _disposeAgent();
              final normalizedBaseUrl = normalizeProviderBaseUrl(api.baseUrl);
              final normalizedModel = normalizeProviderModel(
                api.model,
                baseUrl: normalizedBaseUrl,
              );
              _updateState(() {
                _allowWrite = write;
                _allowTerminal = terminal;
                _qualityGateEnabled = qualityGateEnabled;
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
}
