part of '../main.dart';

// Modal dialogs: model settings, permission prompts, project settings,
// add-on manager, chat history, search, quick-open, command palette, git.

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
        borderRadius: BorderRadius.circular(14),
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
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
    final cs = Theme.of(context).colorScheme;
    final command = title.toLowerCase().contains('perintah');
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cs.outline),
        borderRadius: BorderRadius.circular(14),
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
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      color: cs.primary,
                      size: 28,
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
                          style: TextStyle(color: cs.onSurfaceVariant),
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
                color: cs.onSurface.withValues(alpha: 0.04),
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  detail,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.5,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.03),
                border: Border(top: BorderSide(color: cs.outline)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, PermissionDecision.reject),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      side: BorderSide(color: cs.outline),
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
    final cs = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    final warning = light ? const Color(0xFFB7862A) : const Color(0xFFD7A544);
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cs.outline),
        borderRadius: BorderRadius.circular(14),
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
                    decoration: BoxDecoration(
                      color: warning.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.shield, color: warning, size: 30),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ALLOW TERMINAL COMMAND?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The AI agent is requesting permission to execute this command in the project workspace.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.45),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.04),
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.terminal, size: 19, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      detail,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 13,
                        color: cs.primary,
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
                  Icon(
                    Icons.info_outline,
                    size: 13,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Working Directory: $workspace',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
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
                  VerticalDivider(width: 1, color: cs.outline),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        PermissionDecision.allowAlways,
                      ),
                      child: const Text('ALLOW ALWAYS'),
                    ),
                  ),
                  VerticalDivider(width: 1, color: cs.outline),
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
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cs.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        width: 460,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: cs.error, size: 34),
                  const SizedBox(width: 14),
                  Text(
                    'CONNECTION FAILED',
                    style: TextStyle(
                      color: cs.error,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
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
                  color: cs.onSurface.withValues(alpha: 0.04),
                  border: Border.all(color: cs.outline),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  detail,
                  maxLines: 5,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'TROUBLESHOOTING',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '1. Check your internet connection\n'
                '2. Verify the API key in Model Settings\n'
                '3. Ensure the Base URL and model are valid',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  height: 1.65,
                  color: cs.onSurfaceVariant,
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
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
                            highlightColor: colors.primary.withValues(
                              alpha: 0.10,
                            ),
                            splashColor: colors.primary.withValues(alpha: 0.16),
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

  Widget _environmentTab() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ENVIRONMENT VARIABLES', style: _SettingsHeading.style),
        const SizedBox(height: 8),
        Text(
          'Variables are kept in memory for this session and are never written to disk.',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        for (final entry in _environment.entries)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.key,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '•' * entry.value.length.clamp(4, 18),
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      setState(() => _environment.remove(entry.key)),
                  icon: Icon(Icons.delete_outline, size: 17, color: cs.error),
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
                          _environment[value.text.trim()] =
                              _valueController.text;
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
  }

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

  Widget _apiTab() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('API CONFIGURATION', style: _SettingsHeading.style),
        const SizedBox(height: 8),
        Text(
          'Configure the OpenAI-compatible connection used by the agent.',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 11,
                color: cs.primary,
              ),
            ),
            subtitle: Text(
              entry.value,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
            ),
            trailing: IconButton(
              onPressed: () => setState(() => _headers.remove(entry.key)),
              icon: Icon(Icons.delete_outline, color: cs.error),
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
                    ? (Theme.of(context).brightness == Brightness.light
                          ? const Color(0xFF2F9E69)
                          : const Color(0xFF57C08A))
                    : cs.error,
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
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              method,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 9,
                color: colors.primary,
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
    final cs = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    final warning = light ? const Color(0xFFB7862A) : const Color(0xFFD7A544);
    return Dialog(
      backgroundColor: cs.surface,
      child: SizedBox(
        width: 760,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.extension_outlined, color: cs.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'ADD-ON MANAGER',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: Text(
                'Supported: YOUNZCODE plugins, OpenCode/Claude SKILL.md, MCP JSON, and VSIX. Imported code is never executed during installation.',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: _addons.isEmpty
                  ? Center(
                      child: Text(
                        'No add-ons installed',
                        style: TextStyle(color: cs.onSurfaceVariant),
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
                            color: cs.onSurface.withValues(alpha: 0.04),
                            border: Border.all(color: cs.outline),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(_addonIcon(addon.kind), color: cs.primary),
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
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      _addonStatus(addon),
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 9,
                                        color: warning,
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
    final cs = Theme.of(context).colorScheme;
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
            ? Center(
                child: Text(
                  'Belum ada percakapan tersimpan di workspace ini.',
                  style: TextStyle(color: cs.onSurfaceVariant),
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
                      color: active ? cs.primary : cs.onSurfaceVariant,
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
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          color: cs.onSurface.withValues(alpha: 0.04),
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
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
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
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.04),
                          border: Border(
                            left: BorderSide(color: cs.primary, width: 2),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 220,
                              child: Text(
                                path,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 10,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 42,
                              child: Text(
                                number,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 10,
                                  color: cs.onSurfaceVariant,
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
