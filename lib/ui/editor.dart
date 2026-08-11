part of '../main.dart';

// Code editor surface: open-document model, the workspace editor, and the
// integrated terminal view.

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
    required this.dapTimeoutMs,
  });

  final List<_OpenDocument> documents;
  final String activePath;
  final ValueChanged<String> onSelect;
  final ValueChanged<_OpenDocument> onClose;
  final Future<void> Function(_OpenDocument) onSave;
  final VoidCallback onShowChat;
  final String workspace;
  final bool trusted;

  /// Timeout (milliseconds) for the debug adapter startup handshake;
  /// configurable in Project Settings for slow machines.
  final int dapTimeoutMs;

  @override
  State<_WorkspaceEditor> createState() => _WorkspaceEditorState();
}

class _WorkspaceEditorState extends State<_WorkspaceEditor> {
  final _editorFocus = FocusNode();
  final _breakpoints = <String, Set<int>>{};
  final _debugOutput = <String>[];
  late final _debugAdapter = DebugAdapterService(
    timeout: Duration(milliseconds: widget.dapTimeoutMs),
  );
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
    if (event.name == 'diagnostics') {
      _appendDiagnostics(event.body);
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

  /// Renders the watchdog's 'diagnostics' event: why the session failed,
  /// the adapter's stderr tail, and which requests were still pending.
  void _appendDiagnostics(Map<String, dynamic> body) {
    if (!mounted) return;
    final lines = <String>[
      '── DEBUG SESSION DIAGNOSTICS ──',
      '${body['reason'] ?? 'Debug session failed.'}',
    ];
    final exitCode = body['exitCode'];
    if (exitCode != null) {
      lines.add('Adapter exit code: $exitCode');
    }
    final stderr = (body['stderr'] as List?)?.cast<String>() ?? const [];
    if (stderr.isEmpty) {
      lines.add('Adapter stderr: (none captured)');
    } else {
      lines.add('Adapter stderr (last ${stderr.length} lines):');
      lines.addAll(stderr.map((line) => '  $line'));
    }
    final pending = (body['pending'] as List?) ?? const [];
    if (pending.isEmpty) {
      lines.add('Requests pending at failure: none');
    } else {
      lines.add('Requests still pending at failure:');
      for (final request in pending) {
        final map = Map<String, dynamic>.from(request as Map);
        lines.add(
          '  ${map['command']} (seq ${map['seq']}, ${map['elapsedMs']}ms)',
        );
      }
    }
    setState(() => _debugOutput.addAll(lines));
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
        : const Color(0xFF0D1117);
    final editorChrome = light ? colors.surface : const Color(0xFF10151D);
    final editorGutter = light
        ? const Color(0xFFF1F4F8)
        : const Color(0xFF0F141C);
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
                    child: SilkyListView(
                      silkyConfig: _silkyHorizontalScrollConfig,
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
                                      ? Border(
                                          top: BorderSide(
                                            color: colors.primary,
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
                                          ? (light
                                                ? const Color(0xFFB7862A)
                                                : const Color(0xFFD7A544))
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
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'File sensitif lokal; agent AI tetap diblokir',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.shield_outlined,
                              size: 14,
                              color: light
                                  ? const Color(0xFFB7862A)
                                  : const Color(0xFFD7A544),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'LOCAL ONLY',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: light
                                    ? const Color(0xFFB7862A)
                                    : const Color(0xFFD7A544),
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
                          ? colors.primary
                          : colors.error,
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
                                            ? Icon(
                                                Icons.arrow_right,
                                                size: 18,
                                                color: colors.primary,
                                              )
                                            : points.contains(line)
                                            ? Icon(
                                                Icons.circle,
                                                size: 10,
                                                color: colors.error,
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
                                decoration: BoxDecoration(
                                  color: colors.errorContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
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
                                  style: TextStyle(
                                    fontFamily: 'Consolas',
                                    fontSize: 10,
                                    color: colors.onErrorContainer,
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
                      child: SilkyListView.builder(
                        silkyConfig: _silkyScrollConfig,
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
            child: SilkyListView.builder(
              silkyConfig: _silkyScrollConfig,
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
