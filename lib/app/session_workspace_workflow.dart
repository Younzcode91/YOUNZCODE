part of '../main.dart';

extension _SessionWorkspaceWorkflow on _AgentHomePageState {
  Future<void> _clearChat() async {
    if (_busy) {
      _showMessage('Tunggu agent selesai sebelum memulai chat baru.');
      return;
    }
    await _persistActiveChat();
    _updateState(() {
      _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
      _entries.clear();
      _activities.clear();
      _agentCheckpoint.clear();
      _goal = null;
      _turnState = _AgentTurnState.idle;
      _agent?.clear();
      _searchMode = false;
      _imageGenerationMode = false;
      _browserMode = false;
    });
  }

  Future<void> _persistActiveChat({
    String? expectedChatId,
    String? expectedWorkspace,
  }) async {
    if (_entries.isEmpty && _goal == null) return;
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
      goal: _goal,
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
    if (mounted) _updateState(() {});
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
          _updateState(() {
            _chatSessions.removeWhere((item) => item.id == session.id);
            if (session.id == _activeChatId) {
              _activeChatId = DateTime.now().microsecondsSinceEpoch.toString();
              _entries.clear();
              _activities.clear();
              _agentCheckpoint.clear();
              _goal = null;
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
    _updateState(() {
      _activeChatId = session.id;
      _sessionTokens = 0;
      _entries
        ..clear()
        ..addAll(session.entries);
      _agentCheckpoint
        ..clear()
        ..addAll(session.agentMessages);
      _goal = _goalRestoredFromSession(session.goal);
      _activities.clear();
      _turnState = _AgentTurnState.idle;
      _searchMode = false;
      _activeFile = null;
      _imageGenerationMode = false;
      _browserMode = false;
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
      _updateState(() {
        _activeFile = filePath;
        _searchMode = false;
        _imageGenerationMode = false;
        _browserMode = false;
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
      document.controller.workspaceIdentifiers =
          _codeIntelligence?.symbolNames ?? const {};
      document.controller.addListener(() {
        if (mounted) _updateState(() {});
      });
      _updateState(() {
        _documents.add(document);
        _activeFile = filePath;
        _searchMode = false;
        _imageGenerationMode = false;
        _browserMode = false;
      });
    } catch (error) {
      _showMessage('File tidak dapat dibuka: $error');
    }
  }

  Future<void> _saveDocument(_OpenDocument document) async {
    try {
      await File(document.path).writeAsString(document.controller.text);
      _codeIntelligence?.invalidate();
      if (!mounted) return;
      _updateState(() => document.savedContent = document.controller.text);
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
    _updateState(() {
      _documents.remove(document);
      if (_activeFile == document.path) {
        _activeFile = _documents.isEmpty
            ? null
            : _documents[index.clamp(0, _documents.length - 1)].path;
      }
    });
    document.dispose();
  }

  void _showChat() => _updateState(() {
    _activeFile = null;
    _searchMode = false;
    _imageGenerationMode = false;
    _browserMode = false;
  });

  void _showEditor() {
    if (_documents.isNotEmpty) {
      _updateState(() {
        _activeFile = _documents.last.path;
        _searchMode = false;
        _imageGenerationMode = false;
        _browserMode = false;
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
    await _disposeAgent();
    _updateState(() => _workspaceTrusted = true);
    _notify(
      'Workspace trusted',
      'Terminal, file changes, Agent Browser, local add-ons, and MCP tools '
          'are enabled.',
    );
    _showMessage(
      'Workspace dipercaya. Terminal, browser agent, dan tool lokal '
      'diaktifkan.',
    );
    return true;
  }

  Future<void> _toggleTerminal() async {
    if (_workspace.isEmpty) {
      _showMessage('Pilih workspace sebelum membuka terminal.');
      return;
    }
    if (!_workspaceTrusted && !await _trustCurrentWorkspace()) return;
    _updateState(() => _terminalVisible = !_terminalVisible);
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
      _updateState(() => _terminalOutput.clear());
      return;
    }
    _updateState(() {
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
        _updateState(() {
          _terminalOutput.add('[exit $exitCode]');
          _terminalOutput.add('');
        });
      }
    } catch (error) {
      if (mounted) _updateState(() => _terminalOutput.add('Error: $error\n'));
    } finally {
      if (mounted) _updateState(() => _terminalBusy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_terminalScrollController.hasClients) {
          _terminalScrollController.jumpTo(
            _terminalScrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }
}
