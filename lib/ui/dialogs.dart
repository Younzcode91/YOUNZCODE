part of '../main.dart';

// Modal dialogs: model settings, permission prompts, project settings,
// add-on manager, chat history, search, quick-open, command palette, git.

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    required this.selectedModel,
    required this.fallbackBaseUrls,
    required this.inputCostPerMillion,
    required this.outputCostPerMillion,
    required this.monthlyTokenBudget,
  });

  final String baseUrl;
  final String apiKey;
  final List<String> models;
  final String selectedModel;
  final List<String> fallbackBaseUrls;
  final double inputCostPerMillion;
  final double outputCostPerMillion;
  final int monthlyTokenBudget;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late final _baseController = TextEditingController(text: widget.baseUrl);
  late final _keyController = TextEditingController(text: widget.apiKey);
  final _newModelController = TextEditingController();
  late final _fallbackController = TextEditingController(
    text: widget.fallbackBaseUrls.join('\n'),
  );
  late final _inputCostController = TextEditingController(
    text: '${widget.inputCostPerMillion}',
  );
  late final _outputCostController = TextEditingController(
    text: '${widget.outputCostPerMillion}',
  );
  late final _budgetController = TextEditingController(
    text: '${widget.monthlyTokenBudget}',
  );
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
    _fallbackController.dispose();
    _inputCostController.dispose();
    _outputCostController.dispose();
    _budgetController.dispose();
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
    final apiKey = _keyController.text.trim();
    final uri = Uri.tryParse(baseUrl);
    final localProvider =
        uri != null &&
        {'localhost', '127.0.0.1', '::1'}.contains(uri.host.toLowerCase());
    if (apiKey.isEmpty && !localProvider) {
      setState(() {
        _fetchError =
            'Isi API KEY terlebih dahulu. Provider internet biasanya menolak '
            'endpoint /models tanpa Authorization.';
      });
      return;
    }
    setState(() {
      _fetchingModels = true;
      _fetchError = null;
    });
    try {
      final fetched = await fetchProviderModels(baseUrl, apiKey);
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
        fallbackBaseUrls: _fallbackController.text
            .split(RegExp(r'\r?\n'))
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(),
        inputCostPerMillion:
            double.tryParse(_inputCostController.text.trim()) ?? 0,
        outputCostPerMillion:
            double.tryParse(_outputCostController.text.trim()) ?? 0,
        monthlyTokenBudget: int.tryParse(_budgetController.text.trim()) ?? 0,
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
        key: const ValueKey('model-dialog-panel'),
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height - 64,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            Flexible(
              child: SilkySingleChildScrollView(
                key: const ValueKey('model-dialog-scroll'),
                silkyConfig: _silkyScrollConfig,
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
                    const _FieldLabel('FALLBACK BASE URLS'),
                    TextField(
                      controller: _fallbackController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'One HTTPS or loopback URL per line',
                        helperText:
                            'Used in order after retryable provider failures.',
                      ),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
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
                      'Isi API key sebelum Fetch. Key hanya disimpan di memori '
                      'dan tidak ditulis ke disk.',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: colors.onSurfaceVariant,
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
                      child: SilkyListView.separated(
                        silkyConfig: _silkyScrollConfig,
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
                    const _FieldLabel('USAGE & COST ESTIMATION'),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputCostController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Input USD / 1M',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _outputCostController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Output USD / 1M',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _budgetController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Monthly token budget (0 = unlimited)',
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
    required this.fallbackBaseUrls,
    required this.inputCostPerMillion,
    required this.outputCostPerMillion,
    required this.monthlyTokenBudget,
  });

  final String baseUrl;
  final String apiKey;
  final List<String> models;
  final String selectedModel;
  final List<String> fallbackBaseUrls;
  final double inputCostPerMillion;
  final double outputCostPerMillion;
  final int monthlyTokenBudget;
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
              child: SilkySingleChildScrollView(
                silkyConfig: _silkyScrollConfig,
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
    required this.qualityGateEnabled,
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
  final bool qualityGateEnabled;
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
    bool qualityGateEnabled,
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
  late bool _qualityGateEnabled = widget.qualityGateEnabled;
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
      _qualityGateEnabled,
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
                child: SilkySingleChildScrollView(
                  key: ValueKey(_tab),
                  silkyConfig: _silkyScrollConfig,
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
      _PermissionSetting(
        title: 'AUTOMATIC QUALITY GATE',
        description:
            'Run language checks and relevant tests after accepted agent changes.',
        value: _qualityGateEnabled,
        onChanged: (value) => setState(() => _qualityGateEnabled = value),
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
    required this.onCheckMcp,
    required this.toolPermissionPolicies,
    required this.onToolPermissionChanged,
  });

  final List<Addon> addons;
  final Future<void> Function() onImportFile;
  final Future<void> Function() onImportFolder;
  final Future<void> Function(Addon addon, bool enabled) onToggle;
  final Future<void> Function(Addon addon) onRemove;
  final Future<List<McpHealth>> Function(Addon addon) onCheckMcp;
  final Map<String, ToolPermissionPolicy> toolPermissionPolicies;
  final Future<void> Function(String pattern, ToolPermissionPolicy policy)
  onToolPermissionChanged;

  @override
  State<_AddonManagerDialog> createState() => _AddonManagerDialogState();
}

class _AddonManagerDialogState extends State<_AddonManagerDialog> {
  late final List<Addon> _addons = [...widget.addons];
  final _checkingMcp = <String>{};

  Future<void> _showMcpHealth(Addon addon) async {
    setState(() => _checkingMcp.add(addon.id));
    try {
      final health = await widget.onCheckMcp(addon);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _McpHealthDialog(
          health: health,
          policies: widget.toolPermissionPolicies,
          onPermissionChanged: widget.onToolPermissionChanged,
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingMcp.remove(addon.id));
    }
  }

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
                  : SilkyListView.separated(
                      silkyConfig: _silkyScrollConfig,
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
                              if (addon.kind == AddonKind.mcpServer)
                                IconButton(
                                  tooltip: 'MCP health and permissions',
                                  onPressed: _checkingMcp.contains(addon.id)
                                      ? null
                                      : () => _showMcpHealth(addon),
                                  icon: _checkingMcp.contains(addon.id)
                                      ? const SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.monitor_heart_outlined,
                                          size: 18,
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

class _McpHealthDialog extends StatefulWidget {
  const _McpHealthDialog({
    required this.health,
    required this.policies,
    required this.onPermissionChanged,
  });

  final List<McpHealth> health;
  final Map<String, ToolPermissionPolicy> policies;
  final Future<void> Function(String pattern, ToolPermissionPolicy policy)
  onPermissionChanged;

  @override
  State<_McpHealthDialog> createState() => _McpHealthDialogState();
}

class _McpHealthDialogState extends State<_McpHealthDialog> {
  late final Map<String, ToolPermissionPolicy> _policies = {...widget.policies};

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 620,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: const Text('MCP HEALTH & PERMISSIONS'),
              subtitle: const Text(
                'Policies are stored per workspace and tool.',
              ),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SilkyListView(
                silkyConfig: _silkyScrollConfig,
                padding: const EdgeInsets.all(16),
                children: [
                  for (final server in widget.health) ...[
                    Row(
                      children: [
                        Icon(
                          server.healthy
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: server.healthy
                              ? const Color(0xFF2F9E69)
                              : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            server.serverName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Text(
                          '${server.transport.name.toUpperCase()} · '
                          '${server.latency.inMilliseconds} ms · '
                          '${server.tools.length} tools',
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    if (server.error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          server.error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    for (final tool in server.tools)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.build_outlined, size: 16),
                        title: Text(
                          tool.name,
                          style: const TextStyle(fontFamily: 'Consolas'),
                        ),
                        subtitle: Text(
                          tool.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: DropdownButton<ToolPermissionPolicy>(
                          value:
                              _policies['mcp:${server.serverName}/${tool.name}'] ??
                              ToolPermissionPolicy.ask,
                          items: const [
                            DropdownMenuItem(
                              value: ToolPermissionPolicy.ask,
                              child: Text('ASK'),
                            ),
                            DropdownMenuItem(
                              value: ToolPermissionPolicy.allow,
                              child: Text('ALLOW'),
                            ),
                            DropdownMenuItem(
                              value: ToolPermissionPolicy.deny,
                              child: Text('DENY'),
                            ),
                          ],
                          onChanged: (policy) async {
                            if (policy == null) return;
                            final pattern =
                                'mcp:${server.serverName}/${tool.name}';
                            await widget.onPermissionChanged(pattern, policy);
                            if (mounted) {
                              setState(() => _policies[pattern] = policy);
                            }
                          },
                        ),
                      ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'CONNECTION LOG',
                        style: TextStyle(fontSize: 10),
                      ),
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: SelectableText(
                            server.logs.isEmpty
                                ? 'No log entries.'
                                : server.logs.join('\n'),
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
            : SilkyListView.separated(
                silkyConfig: _silkyScrollConfig,
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
                  const SizedBox(width: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(
                        'HYBRID INDEX',
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
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
              : SilkyListView.builder(
                  silkyConfig: _silkyScrollConfig,
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
              child: SilkyListView.builder(
                silkyConfig: _silkyScrollConfig,
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
      ('images', Icons.image_outlined, 'Image Generation'),
      ('browser', Icons.travel_explore, 'Agent Browser'),
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
    required this.service,
    required this.workspace,
    required this.onChanged,
    required this.onOpenFile,
  });

  final GitService service;
  final String workspace;
  final Future<void> Function() onChanged;
  final ValueChanged<String> onOpenFile;

  @override
  State<_GitDialog> createState() => _GitDialogState();
}

class _GitDialogState extends State<_GitDialog> {
  final _branchController = TextEditingController();
  final _commitController = TextEditingController();
  GitStatus _status = const GitStatus(isRepository: true);
  List<String> _branches = const [];
  List<GitWorktree> _worktrees = const [];
  String _diff = '';
  String _history = '';
  String? _branchError;
  String? _operationError;
  bool _loading = true;
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _branchController.dispose();
    _commitController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final values = await Future.wait([
        widget.service.status(widget.workspace),
        widget.service.diff(widget.workspace),
        widget.service.history(widget.workspace),
        widget.service.branches(widget.workspace),
        widget.service.worktrees(widget.workspace),
      ]);
      if (!mounted) return;
      setState(() {
        _status = values[0] as GitStatus;
        _diff = values[1] as String;
        _history = values[2] as String;
        _branches = values[3] as List<String>;
        _worktrees = values[4] as List<GitWorktree>;
        _loading = false;
        _operationError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _operationError = '$error';
        });
      }
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool clearCommit = false,
  }) async {
    if (_mutating) return;
    setState(() {
      _mutating = true;
      _operationError = null;
    });
    try {
      await action();
      if (clearCommit) _commitController.clear();
      await widget.onChanged();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _operationError = '$error');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _discard(GitFileStatus entry) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard file changes?'),
        content: Text(
          entry.untracked
              ? '${entry.path} akan dihapus permanen.'
              : '${entry.path} akan dikembalikan ke versi repository.',
        ),
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
    if (approved == true) {
      await _run(() => widget.service.discard(widget.workspace, entry));
    }
  }

  Future<void> _push() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Push branch?'),
        content: Text(
          'Push "${_status.branch}" ke remote "origin"? Ini mengubah '
          'repository remote.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('PUSH'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await _run(() => widget.service.pushCurrent(widget.workspace));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 980,
        height: 720,
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(_status.branch.isEmpty ? 'Git' : _status.branch),
                subtitle: Text(
                  _status.dirty
                      ? '${_status.entries.length} changed files'
                      : 'Working tree clean',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _mutating ? null : _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: 'Push current branch',
                      onPressed: _mutating ? null : _push,
                      icon: const Icon(Icons.cloud_upload_outlined),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_operationError != null)
                Container(
                  width: double.infinity,
                  color: colors.error.withValues(alpha: 0.12),
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _operationError!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.error),
                  ),
                ),
              const TabBar(
                tabs: [
                  Tab(text: 'CHANGES'),
                  Tab(text: 'DIFF'),
                  Tab(text: 'HISTORY'),
                  Tab(text: 'BRANCHES'),
                ],
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(
                        children: [
                          _changesTab(),
                          _CodeOutput(_diff.isEmpty ? 'No diff.' : _diff),
                          _CodeOutput(
                            _history.isEmpty ? 'No commits.' : _history,
                          ),
                          _branchesTab(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _changesTab() {
    return SilkyListView(
      silkyConfig: _silkyScrollConfig,
      padding: const EdgeInsets.all(16),
      children: [
        if (_status.entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('WORKING TREE CLEAN')),
          ),
        for (final entry in _status.entries)
          ListTile(
            dense: true,
            leading: SizedBox(
              width: 30,
              child: Text(
                '${entry.indexStatus}${entry.workTreeStatus}',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.bold,
                  color: entry.conflicted
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            title: Text(
              entry.path,
              style: const TextStyle(fontFamily: 'Consolas'),
            ),
            subtitle: entry.conflicted
                ? const Text(
                    'CONFLICT — edit file, lalu stage sebagai resolved',
                  )
                : Text(entry.staged ? 'STAGED' : 'UNSTAGED'),
            onTap: () => widget.onOpenFile(entry.path),
            trailing: Wrap(
              spacing: 2,
              children: [
                IconButton(
                  tooltip: entry.staged ? 'Unstage' : 'Stage',
                  onPressed: _mutating
                      ? null
                      : () => _run(
                          () => entry.staged
                              ? widget.service.unstage(widget.workspace, [
                                  entry.path,
                                ])
                              : widget.service.stage(widget.workspace, [
                                  entry.path,
                                ]),
                        ),
                  icon: Icon(
                    entry.staged
                        ? Icons.remove_circle_outline
                        : Icons.add_circle_outline,
                  ),
                ),
                IconButton(
                  tooltip: 'Discard',
                  onPressed: _mutating ? null : () => _discard(entry),
                  icon: const Icon(Icons.undo),
                ),
              ],
            ),
          ),
        if (_status.entries.isNotEmpty) ...[
          const Divider(),
          Row(
            children: [
              OutlinedButton(
                onPressed: _mutating
                    ? null
                    : () => _run(
                        () => widget.service.stage(
                          widget.workspace,
                          _status.entries.map((entry) => entry.path),
                        ),
                      ),
                child: const Text('STAGE ALL'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _mutating || !_status.hasStaged
                    ? null
                    : () => _run(
                        () => widget.service.unstage(
                          widget.workspace,
                          _status.entries
                              .where((entry) => entry.staged)
                              .map((entry) => entry.path),
                        ),
                      ),
                child: const Text('UNSTAGE ALL'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commitController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Commit message',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _mutating || !_status.hasStaged
                    ? null
                    : () => _run(
                        () => widget.service.commit(
                          widget.workspace,
                          _commitController.text,
                        ),
                        clearCommit: true,
                      ),
                icon: const Icon(Icons.commit),
                label: const Text('COMMIT'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _branchesTab() {
    return SilkyListView(
      silkyConfig: _silkyScrollConfig,
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _branchController,
          decoration: InputDecoration(
            labelText: 'Branch name',
            errorText: _branchError,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _mutating
                  ? null
                  : () => _run(
                      () => widget.service.createBranch(
                        widget.workspace,
                        _branchController.text.trim(),
                      ),
                    ),
              child: const Text('CREATE'),
            ),
            OutlinedButton(
              onPressed: _mutating
                  ? null
                  : () => _run(
                      () => widget.service.switchBranch(
                        widget.workspace,
                        _branchController.text.trim(),
                      ),
                    ),
              child: const Text('SWITCH'),
            ),
            OutlinedButton(
              onPressed: _mutating
                  ? null
                  : () => _run(
                      () => widget.service.mergeBranch(
                        widget.workspace,
                        _branchController.text.trim(),
                      ),
                    ),
              child: const Text('MERGE INTO CURRENT'),
            ),
            if (_status.conflicts.isNotEmpty)
              TextButton(
                onPressed: _mutating
                    ? null
                    : () => _run(
                        () => widget.service.abortMerge(widget.workspace),
                      ),
                child: const Text('ABORT MERGE'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'LOCAL BRANCHES',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
        for (final branch in _branches)
          ListTile(
            dense: true,
            leading: Icon(
              branch == _status.branch
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
            ),
            title: Text(branch, style: const TextStyle(fontFamily: 'Consolas')),
            onTap: branch == _status.branch
                ? null
                : () {
                    _branchController.text = branch;
                  },
          ),
        const Divider(),
        const Text(
          'WORKTREES',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
        for (final worktree in _worktrees)
          ListTile(
            dense: true,
            leading: const Icon(Icons.account_tree, size: 16),
            title: Text(
              worktree.branch.isEmpty ? worktree.head : worktree.branch,
              style: const TextStyle(fontFamily: 'Consolas'),
            ),
            subtitle: Text(
              worktree.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing:
                worktree.path == widget.workspace ||
                    !worktree.branch.startsWith('codex/agent-')
                ? null
                : IconButton(
                    tooltip: 'Remove agent worktree',
                    onPressed: _mutating
                        ? null
                        : () => _run(
                            () => widget.service.removeWorktree(
                              widget.workspace,
                              worktree,
                            ),
                          ),
                    icon: const Icon(Icons.delete_outline),
                  ),
          ),
      ],
    );
  }
}

class _CodeOutput extends StatelessWidget {
  const _CodeOutput(this.value);
  final String value;

  @override
  Widget build(BuildContext context) => SilkySingleChildScrollView(
    silkyConfig: _silkyScrollConfig,
    padding: const EdgeInsets.all(16),
    child: SelectableText(
      value,
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.4),
    ),
  );
}

class _ProviderUsageDialog extends StatelessWidget {
  const _ProviderUsageDialog({
    required this.records,
    required this.monthlyTokenBudget,
    required this.onClear,
  });

  final List<ProviderUsageRecord> records;
  final int monthlyTokenBudget;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final monthly = ProviderUsageStore.summarize(
      records,
      since: DateTime(now.year, now.month),
    );
    final allTime = ProviderUsageStore.summarize(records);
    final budgetProgress = monthlyTokenBudget <= 0
        ? 0.0
        : (monthly.totalTokens / monthlyTokenBudget).clamp(0.0, 1.0);
    return Dialog(
      child: SizedBox(
        width: 840,
        height: 650,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.query_stats),
              title: const Text('PROVIDER USAGE'),
              subtitle: const Text(
                'Cost is an estimate based on the rates in Model Settings.',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: records.isEmpty
                        ? null
                        : () async {
                            final approved = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Clear usage history?'),
                                content: const Text(
                                  'Semua riwayat token untuk workspace ini '
                                  'akan dihapus.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('CANCEL'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('CLEAR'),
                                  ),
                                ],
                              ),
                            );
                            if (approved == true) {
                              await onClear();
                              if (context.mounted) Navigator.pop(context);
                            }
                          },
                    child: const Text('CLEAR'),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SilkyListView(
                silkyConfig: _silkyScrollConfig,
                padding: const EdgeInsets.all(18),
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _UsageMetric(
                        label: 'THIS MONTH',
                        value: '${monthly.totalTokens} tokens',
                      ),
                      _UsageMetric(
                        label: 'INPUT / OUTPUT',
                        value:
                            '${monthly.promptTokens} / '
                            '${monthly.completionTokens}',
                      ),
                      _UsageMetric(
                        label: 'ESTIMATED COST',
                        value:
                            '\$${monthly.estimatedCostUsd.toStringAsFixed(4)}',
                      ),
                      _UsageMetric(
                        label: 'ALL TIME',
                        value: '${allTime.totalTokens} tokens',
                      ),
                    ],
                  ),
                  if (monthlyTokenBudget > 0) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Text(
                          'MONTHLY BUDGET',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${monthly.totalTokens} / $monthlyTokenBudget',
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: budgetProgress,
                      color: budgetProgress >= 0.8
                          ? colors.error
                          : colors.primary,
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    'USAGE BY ROUTE',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  for (final entry in monthly.byRoute.entries)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.key),
                      trailing: Text(
                        '${entry.value}',
                        style: const TextStyle(fontFamily: 'Consolas'),
                      ),
                    ),
                  const Divider(height: 28),
                  const Text(
                    'RECENT REQUESTS',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  for (final record in records.take(100))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${record.model} · '
                        '${Uri.tryParse(record.baseUrl)?.host ?? record.baseUrl}',
                      ),
                      subtitle: Text(
                        record.timestamp.toLocal().toString(),
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                        ),
                      ),
                      trailing: Text(
                        '${record.totalTokens} · '
                        '\$${record.estimatedCostUsd.toStringAsFixed(4)}',
                        style: const TextStyle(fontFamily: 'Consolas'),
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

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: 185,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04),
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9)),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'Consolas',
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}

class _QualityGateDialog extends StatelessWidget {
  const _QualityGateDialog({required this.result});

  final QualityGateResult result;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.rule_folder_outlined, color: colors.error),
      title: const Text('Quality gate failed'),
      content: SizedBox(
        width: 760,
        height: 460,
        child: SilkyListView(
          silkyConfig: _silkyScrollConfig,
          children: [
            const Text(
              'Perubahan sudah diterapkan dan memiliki checkpoint. '
              'Tinjau hasil berikut sebelum memilih keep atau revert.',
            ),
            const SizedBox(height: 14),
            for (final check in result.checks) ...[
              Row(
                children: [
                  Icon(
                    check.passed
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: check.passed
                        ? const Color(0xFF2F9E69)
                        : colors.error,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      check.check.label,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    check.timedOut
                        ? 'TIMEOUT'
                        : '${check.duration.inSeconds}s · exit ${check.exitCode}',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              if (check.output.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8, bottom: 14),
                  padding: const EdgeInsets.all(10),
                  color: colors.onSurface.withValues(alpha: 0.04),
                  child: SelectableText(
                    check.output,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('KEEP CHANGES'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('REVERT TURN'),
        ),
      ],
    );
  }
}

class _MultiAgentResultsDialog extends StatelessWidget {
  const _MultiAgentResultsDialog({required this.tasks});

  final List<AgentTask> tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 860,
        height: 620,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.groups_2_outlined),
              title: const Text('MULTI-AGENT RESULTS'),
              subtitle: Text(
                '${tasks.where((task) => task.status == AgentTaskStatus.completed).length}'
                '/${tasks.length} completed',
              ),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SilkyListView.separated(
                silkyConfig: _silkyScrollConfig,
                padding: const EdgeInsets.all(16),
                itemCount: tasks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final succeeded = task.status == AgentTaskStatus.completed;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: 0.04),
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                succeeded
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                color: succeeded
                                    ? const Color(0xFF2F9E69)
                                    : colors.error,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  task.prompt,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            task.branch.isEmpty
                                ? task.error
                                : '${task.branch}\n${task.worktree}',
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                            ),
                          ),
                          if (task.result.isNotEmpty ||
                              task.error.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              task.error.isNotEmpty ? task.error : task.result,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
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
}
