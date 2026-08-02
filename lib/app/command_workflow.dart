part of '../main.dart';

extension _CommandWorkflow on _AgentHomePageState {
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
    final mediaIntent = MediaDownloadIntent.tryParse(prompt);
    if (mediaIntent != null) {
      _promptController.clear();
      await _downloadMediaFromChat(mediaIntent, userInput: prompt);
      return;
    }
    if (_apiKey.isEmpty) {
      await _openSettings();
      if (_apiKey.isEmpty) return;
    }
    if (!mounted || !await _confirmMainBranchWork()) return;
    final promptWithContext = await _buildPromptWithContext(prompt);
    _promptController.clear();
    await _runAgentOperation(
      (agent) => agent.send(promptWithContext),
      userEntry: ChatEntry(role: ChatRole.user, content: prompt),
    );
  }

  Future<bool> _confirmMainBranchWork() async {
    if (!_mainBranchWarningPolicy.shouldWarn(
      workspace: _workspace,
      branch: _gitStatus.branch,
      isMainBranch: _gitStatus.mainBranch,
      planMode: _planMode,
    )) {
      return true;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.account_tree_outlined),
        title: Text('Work directly on ${_gitStatus.branch}?'),
        content: const Text(
          'Agent akan bekerja pada branch utama. Branch fitur lebih aman '
          'untuk review dan rollback.\n\nPeringatan ini hanya ditampilkan '
          'sekali untuk branch ini selama aplikasi berjalan.',
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
    if (proceed != true) return false;
    _mainBranchWarningPolicy.accept(
      workspace: _workspace,
      branch: _gitStatus.branch,
    );
    return true;
  }

  Future<void> _runSlashCommand(String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    final command = parts.first.toLowerCase();
    final argument = parts.skip(1).join(' ').trim();
    switch (command) {
      case '/download':
        final intent = MediaDownloadIntent.tryParse(
          argument,
          requireDownloadWord: false,
        );
        if (intent == null) {
          _addLocalResponse(
            'Gunakan: /download https://alamat-video\n'
            'Hanya URL HTTPS publik yang didukung.',
            error: true,
          );
          return;
        }
        await _downloadMediaFromChat(intent, userInput: input);
      case '/graphify':
        await _runGraphify(argument);
      case '/agents':
        await _runMultiAgents(argument);
      case '/mcp':
        _showAddonSummary(AddonKind.mcpServer, argument);
      case '/review':
        await _openReview();
      case '/fork':
        await _forkChat();
      case '/model' || '/models':
        await _openSettings();
      case '/usage':
        await _openUsageDashboard();
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
        _updateState(() {
          _promptController.clear();
          _contextFiles.clear();
          _activities.clear();
          _turnState = _AgentTurnState.idle;
        });
        _showMessage('Prompt, context, dan activity dibersihkan.');
      case '/terminal':
        await _toggleTerminal();
      case '/explorer':
        _updateState(() => _explorerPanelVisible = !_explorerPanelVisible);
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
        if (argument.isNotEmpty) {
          _searchController.text = argument;
          await _searchWorkspace();
        }
      case '/symbol':
        await _findSymbolReferences(argument);
      case '/images':
        _openImageGeneration();
      case '/browser':
        _openBrowser(argument.isEmpty ? null : argument);
      case '/notifications':
        await _showNotifications();
      case '/goal':
        await _runGoalCommand(argument);
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

  Future<void> _runMultiAgents(String argument) async {
    if (_busy) {
      _showMessage('Tunggu operasi agent saat ini selesai.');
      return;
    }
    if (_workspace.isEmpty || !_workspaceTrusted) {
      _showMessage(
        'Pilih dan trust workspace sebelum menjalankan multi-agent.',
      );
      return;
    }
    if (!_gitStatus.isRepository) {
      _showMessage('Multi-agent memerlukan repository Git.');
      return;
    }
    final prompts = argument
        .split('|')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .take(6)
        .toList();
    if (prompts.isEmpty) {
      _addLocalResponse(
        'Gunakan /agents tugas pertama | tugas kedua | tugas ketiga. '
        'Setiap tugas dijalankan pada branch dan worktree terpisah.',
      );
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.groups_2_outlined),
        title: Text('Run ${prompts.length} isolated agents?'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Setiap agent menggunakan branch "codex/agent-*" dari HEAD '
                'dan worktree terpisah. Perubahan lokal yang belum di-commit '
                'tidak ikut disalin.',
              ),
              const SizedBox(height: 12),
              for (final prompt in prompts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $prompt'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('RUN AGENTS'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final instructions = _enabledAddonInstructions();
    final environment = Map<String, String>.of(_environment);
    final headers = Map<String, String>.of(_apiHeaders);
    _updateState(() {
      _busy = true;
      _turnState = _AgentTurnState.running;
      _agentStatus = 'Menyiapkan ${prompts.length} worktree';
      _activities.clear();
      _turnStartedAt = DateTime.now();
    });
    final orchestrator = MultiAgentOrchestrator(
      workspace: _workspace,
      maxParallel: 3,
      onTaskChanged: (task) {
        if (!mounted) return;
        final state = switch (task.status) {
          AgentTaskStatus.queued ||
          AgentTaskStatus.preparing ||
          AgentTaskStatus.running => 'berjalan',
          AgentTaskStatus.completed => 'selesai',
          AgentTaskStatus.failed => 'gagal',
          AgentTaskStatus.cancelled => 'dibatalkan',
        };
        _updateState(() {
          final index = _activities.indexWhere(
            (activity) => activity.id == task.id,
          );
          final activity = _AgentActivity(
            id: task.id,
            name: 'multi_agent',
            detail:
                '${task.prompt}\n'
                '${task.branch.isEmpty ? task.status.name : task.branch}',
            state: state,
          );
          if (index < 0) {
            _activities.add(activity);
          } else {
            _activities[index] = activity;
          }
          final completed = _activities.where((item) => item.completed).length;
          _agentStatus = 'Multi-agent $completed/${prompts.length} selesai';
        });
      },
      runner: (task, worktree) async {
        WorkspaceTurnChanges? pending;
        final agent = AgentService(
          baseUrl: _baseUrl,
          apiKey: _apiKey,
          model: _model,
          workspace: worktree,
          requestPermission: (title, _) async =>
              title.toLowerCase().contains('sensitif')
              ? PermissionDecision.reject
              : PermissionDecision.allowOnce,
          onToolActivity: (_, _, _, _) {},
          onStatus: (status) {
            if (!mounted) return;
            _updateState(() {
              final index = _activities.indexWhere(
                (activity) => activity.id == task.id,
              );
              if (index >= 0) {
                _activities[index] = _AgentActivity(
                  id: task.id,
                  name: 'multi_agent',
                  detail: '${task.prompt}\n$status',
                  state: 'berjalan',
                );
              }
            });
          },
          allowWrite: true,
          allowTerminal: false,
          approvalMode: ApprovalMode.approveForMe,
          environment: environment,
          timeoutMs: _timeoutMs,
          headers: headers,
          addonInstructions: instructions,
          onChanges: (changes) => pending = changes,
          onInsight:
              ({reasoning, promptTokens, completionTokens, totalTokens}) {
                if (mounted && totalTokens != null) {
                  _updateState(() => _sessionTokens += totalTokens);
                }
                _recordProviderUsage(
                  baseUrl: _baseUrl,
                  model: _model,
                  promptTokens: promptTokens,
                  completionTokens: completionTokens,
                  totalTokens: totalTokens,
                );
              },
        );
        try {
          final answer = await agent.send(task.prompt);
          final applied = pending == null
              ? null
              : await agent.applyPendingChanges();
          if (_qualityGateEnabled && applied != null) {
            final quality = await _qualityGateService.run(
              worktree,
              applied.files.map((file) => file.path),
            );
            if (!quality.passed && !quality.skipped) {
              final failed = quality.checks.last;
              throw StateError('${failed.check.label} gagal: ${failed.output}');
            }
          }
          return applied == null
              ? answer
              : '$answer\n\n${applied.files.length} file diterapkan di '
                    '${task.branch}.';
        } finally {
          await agent.dispose();
        }
      },
    );
    List<AgentTask> tasks;
    try {
      tasks = await orchestrator.run(prompts);
    } finally {
      if (mounted) {
        _updateState(() {
          _busy = false;
          _lastTurnDuration = _turnStartedAt == null
              ? Duration.zero
              : DateTime.now().difference(_turnStartedAt!);
        });
      }
    }
    if (!mounted) return;
    final failed = tasks.where((task) => task.status == AgentTaskStatus.failed);
    _updateState(() {
      _turnState = failed.isEmpty
          ? _AgentTurnState.success
          : _AgentTurnState.failed;
      _agentStatus = failed.isEmpty
          ? '${tasks.length} agent selesai'
          : '${failed.length} agent gagal';
      _executionSummaryVisible = true;
    });
    await showDialog<void>(
      context: context,
      builder: (context) => _MultiAgentResultsDialog(tasks: tasks),
    );
  }

  Future<void> _openUsageDashboard() async {
    final records = await _providerUsageStore.load(_workspace);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _ProviderUsageDialog(
        records: records,
        monthlyTokenBudget: _monthlyTokenBudget,
        onClear: () async {
          await _providerUsageStore.clear(_workspace);
          if (mounted) {
            _updateState(() {
              _sessionTokens = 0;
              _budgetWarningShown = false;
            });
          }
        },
      ),
    );
  }

  Future<void> _findSymbolReferences(String symbol) async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum mencari simbol.');
      return;
    }
    if (symbol.isEmpty) {
      _showMessage('Gunakan /symbol NamaSimbol.');
      return;
    }
    final service = _codeIntelligence ?? CodeIntelligenceService(_workspace);
    _codeIntelligence = service;
    _updateState(() {
      _searchMode = true;
      _imageGenerationMode = false;
      _browserMode = false;
      _searchBusy = true;
      _searchController.text = symbol;
    });
    try {
      final results = await service.references(symbol, limit: 500);
      if (!mounted) return;
      _updateState(() {
        _searchResults = results.map((item) => item.displayLine).toList();
      });
    } catch (error) {
      if (mounted) _showMessage('Pencarian simbol gagal: $error');
    } finally {
      if (mounted) _updateState(() => _searchBusy = false);
    }
  }

  Future<void> _runGraphify(String argument) async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum menjalankan Graphify.');
      return;
    }
    if (!_workspaceTrusted && !await _trustCurrentWorkspace()) return;
    _updateState(() => _terminalVisible = true);
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
        _updateState(
          () => _terminalOutput.add('[Graphify exited with $exitCode]'),
        );
      }
    } catch (error) {
      if (mounted) {
        _updateState(() => _terminalOutput.add('[Graphify error: $error]'));
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
    _updateState(() {
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
    _updateState(() {
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
      _updateState(() => _gitStatus = status);
    }
  }

  Future<void> _showGitDetails() async {
    if (!_gitStatus.isRepository) {
      _showMessage('Workspace bukan repository Git.');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _GitDialog(
        service: _gitService,
        workspace: _workspace,
        onChanged: _refreshGit,
        onOpenFile: (relativePath) =>
            _openFile('$_workspace${Platform.pathSeparator}$relativePath'),
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
      case 'images':
        _openImageGeneration();
      case 'browser':
        _openBrowser();
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
    const maxCombinedCharacters = 320000;
    for (final filePath in _contextFiles) {
      if (context.length >= maxCombinedCharacters) {
        context.write(
          '\n\n[Context tambahan dipotong karena terlalu panjang.]',
        );
        break;
      }
      final safePath = await _trustService.resolveContainedFile(
        _workspace,
        filePath,
      );
      if (safePath == null) continue;
      final file = File(safePath);
      if (await file.length() > _documentExtractionService.maxFileBytes) {
        continue;
      }
      final revalidated = await _trustService.resolveContainedFile(
        _workspace,
        safePath,
      );
      if (revalidated == null || revalidated != safePath) continue;
      final relative = safePath.replaceAll('\\', '/').split('/').last;
      try {
        final extracted = await _documentExtractionService.extract(revalidated);
        var content = SecretScanner.redact(extracted.text);
        final remaining = maxCombinedCharacters - context.length;
        if (content.length > remaining) {
          content =
              '${content.substring(0, remaining)}\n'
              '[Context dipotong karena batas gabungan tercapai.]';
        }
        context.write(
          '\n\n--- $relative (${extracted.kind.name}) ---\n$content',
        );
      } on DocumentExtractionException catch (error) {
        context.write('\n\n--- $relative ---\n[Gagal membaca file: $error]');
      }
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
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
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
        if (await File(safePath).length() <=
            _documentExtractionService.maxFileBytes) {
          files.add(safePath);
        }
      } on FileSystemException {
        continue;
      }
    }
    _updateState(() {
      for (final file in files) {
        if (!_contextFiles.contains(file)) _contextFiles.add(file);
      }
    });
  }
}
