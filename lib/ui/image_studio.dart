part of '../main.dart';

class _ImageGenerationView extends StatefulWidget {
  const _ImageGenerationView({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    required this.selectedModel,
    required this.headers,
    required this.timeoutMs,
    required this.onManageModels,
  });

  final String baseUrl;
  final String apiKey;
  final List<String> models;
  final String selectedModel;
  final Map<String, String> headers;
  final int timeoutMs;
  final VoidCallback onManageModels;

  @override
  State<_ImageGenerationView> createState() => _ImageGenerationViewState();
}

class _ImageGenerationViewState extends State<_ImageGenerationView> {
  final _promptController = TextEditingController();
  final _referenceController = TextEditingController();
  final _service = ImageGenerationService();

  late String _model = _initialModel();
  String _size = 'auto';
  String _quality = 'auto';
  String _background = 'auto';
  String _imageDetail = 'high';
  String _outputFormat = 'png';
  bool _running = false;
  String? _error;
  ImageGenerationResult? _result;

  String _initialModel() {
    if (widget.selectedModel.toLowerCase().contains('image')) {
      return widget.selectedModel;
    }
    final imageModel = widget.models.where(
      (model) => model.toLowerCase().contains('image'),
    );
    if (imageModel.isNotEmpty) return imageModel.first;
    if (normalizeProviderBaseUrl(widget.baseUrl).contains(':20128')) {
      return 'cx/gpt-5.5-image';
    }
    return 'gpt-image-1';
  }

  List<String> get _models => {
    _model,
    ...widget.models,
    normalizeProviderBaseUrl(widget.baseUrl).contains(':20128')
        ? 'cx/gpt-5.5-image'
        : 'gpt-image-1',
  }.toList();

  ImageGenerationRequest get _request => ImageGenerationRequest(
    model: _model,
    prompt: _promptController.text.trim(),
    referenceImageUrl: _referenceController.text.trim(),
    size: _size,
    quality: _quality,
    background: _background,
    imageDetail: _imageDetail,
    outputFormat: _outputFormat,
  );

  String get _requestPreview {
    final body = jsonEncode(_request.toJson());
    return 'curl -X POST "${imageGenerationEndpoint(widget.baseUrl)}" \\\n'
        '  -H "Content-Type: application/json" \\\n'
        '${widget.apiKey.isEmpty ? '' : '  -H "Authorization: Bearer <API_KEY>" \\\\\n'}'
        "  -d '$body'";
  }

  @override
  void didUpdateWidget(covariant _ImageGenerationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.models.contains(_model) &&
        oldWidget.baseUrl != widget.baseUrl) {
      _model = _initialModel();
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _referenceController.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_promptController.text.trim().isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await _service.generate(
        baseUrl: widget.baseUrl,
        apiKey: widget.apiKey,
        headers: widget.headers,
        request: _request,
        timeout: Duration(milliseconds: widget.timeoutMs),
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _error =
              'Request melewati batas waktu. Naikkan timeout di Project Settings > API.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _copyRequest() async {
    await Clipboard.setData(ClipboardData(text: _requestPreview));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Request disalin.')));
  }

  Future<void> _saveImage() async {
    final result = _result;
    if (result == null) return;
    try {
      final bytes =
          result.imageBytes ??
          (result.imageUrl == null
              ? null
              : await _service.download(result.imageUrl!));
      if (bytes == null) return;
      final target = await FilePicker.platform.saveFile(
        dialogTitle: 'Simpan gambar',
        fileName:
            'younzcode-${DateTime.now().millisecondsSinceEpoch}.$_outputFormat',
        type: FileType.custom,
        allowedExtensions: [_outputFormat],
      );
      if (target == null) return;
      await File(target).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gambar disimpan ke $target')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan gambar: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ColoredBox(
      key: const ValueKey('image-generation-view'),
      color: colors.surfaceContainerLowest,
      child: SilkySingleChildScrollView(
        silkyConfig: _silkyScrollConfig,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.image_outlined, color: colors.primary),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'IMAGE GENERATION',
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'OpenAI-compatible /images/generations playground',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: widget.onManageModels,
                      icon: const Icon(Icons.settings_outlined, size: 17),
                      label: const Text('MANAGE MODELS'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _StudioPanel(
                  title: 'REQUEST',
                  child: Column(
                    children: [
                      _StudioFieldRow(
                        label: 'MODEL',
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('image-model'),
                          initialValue: _model,
                          items: [
                            for (final model in _models)
                              DropdownMenuItem(
                                value: model,
                                child: Text(
                                  model,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _running
                              ? null
                              : (value) => setState(() => _model = value!),
                        ),
                      ),
                      _StudioFieldRow(
                        label: 'ENDPOINT',
                        child: TextFormField(
                          key: const ValueKey('image-endpoint'),
                          initialValue: imageGenerationEndpoint(widget.baseUrl),
                          readOnly: true,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      _StudioFieldRow(
                        label: 'API KEY',
                        child: Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: widget.apiKey.isEmpty
                                    ? 'Belum diatur'
                                    : '••••••••••••••••',
                                readOnly: true,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.outlined(
                              tooltip: 'Atur koneksi model',
                              onPressed: widget.onManageModels,
                              icon: const Icon(Icons.tune, size: 18),
                            ),
                          ],
                        ),
                      ),
                      _StudioFieldRow(
                        label: 'CONNECTION',
                        child: InputDecorator(
                          decoration: const InputDecoration(),
                          child: Text(
                            'Auto · ${normalizeProviderBaseUrl(widget.baseUrl)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      _StudioFieldRow(
                        label: 'PROMPT',
                        topAligned: true,
                        child: TextField(
                          key: const ValueKey('image-prompt'),
                          controller: _promptController,
                          minLines: 2,
                          maxLines: 5,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText:
                                'Describe the image you want to create...',
                            suffixIcon: _promptController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Hapus prompt',
                                    onPressed: () => setState(
                                      () => _promptController.clear(),
                                    ),
                                    icon: const Icon(Icons.close, size: 18),
                                  ),
                          ),
                        ),
                      ),
                      _StudioFieldRow(
                        label: 'REF IMAGE',
                        child: TextField(
                          controller: _referenceController,
                          enabled: !_running,
                          decoration: const InputDecoration(
                            hintText:
                                'https://example.com/source.png (optional)',
                          ),
                        ),
                      ),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final stacked = constraints.maxWidth < 720;
                          final fields = [
                            _StudioSelect(
                              label: 'SIZE',
                              value: _size,
                              values: const [
                                'auto',
                                '1024x1024',
                                '1536x1024',
                                '1024x1536',
                              ],
                              onChanged: (value) =>
                                  setState(() => _size = value),
                            ),
                            _StudioSelect(
                              label: 'QUALITY',
                              value: _quality,
                              values: const ['auto', 'low', 'medium', 'high'],
                              onChanged: (value) =>
                                  setState(() => _quality = value),
                            ),
                            _StudioSelect(
                              label: 'BACKGROUND',
                              value: _background,
                              values: const ['auto', 'transparent', 'opaque'],
                              onChanged: (value) =>
                                  setState(() => _background = value),
                            ),
                            _StudioSelect(
                              label: 'DETAIL',
                              value: _imageDetail,
                              values: const ['auto', 'low', 'high'],
                              onChanged: (value) =>
                                  setState(() => _imageDetail = value),
                            ),
                            _StudioSelect(
                              label: 'CODEC',
                              value: _outputFormat,
                              values: const ['png', 'jpeg', 'webp'],
                              onChanged: (value) =>
                                  setState(() => _outputFormat = value),
                            ),
                          ];
                          if (stacked) {
                            return Column(
                              children: [
                                for (final field in fields)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: field,
                                  ),
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var index = 0;
                                index < fields.length;
                                index++
                              )
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      right: index == fields.length - 1 ? 0 : 8,
                                    ),
                                    child: fields[index],
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const _StudioFieldRow(
                        label: 'OUTPUT',
                        child: InputDecorator(
                          decoration: InputDecoration(),
                          child: Text('JSON (Base64 / URL)'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _StudioPanel(
                  title: 'REQUEST PREVIEW',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('copy-image-request'),
                        onPressed: _copyRequest,
                        icon: const Icon(Icons.copy_outlined, size: 17),
                        label: const Text('COPY'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const ValueKey('image-run'),
                        onPressed:
                            _running || _promptController.text.trim().isEmpty
                            ? null
                            : _generate,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow, size: 18),
                        label: Text(_running ? 'GENERATING' : 'RUN'),
                      ),
                    ],
                  ),
                  child: SelectableText(
                    _requestPreview,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11.5,
                      height: 1.55,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _StudioPanel(
                  title: 'RESPONSE',
                  trailing: _result?.hasImage == true
                      ? OutlinedButton.icon(
                          key: const ValueKey('save-generated-image'),
                          onPressed: _saveImage,
                          icon: const Icon(Icons.download_outlined, size: 17),
                          label: const Text('SAVE IMAGE'),
                        )
                      : null,
                  child: _buildResponse(colors),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResponse(ColorScheme colors) {
    if (_error != null) {
      return Container(
        key: const ValueKey('image-generation-error'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colors.error, size: 19),
            const SizedBox(width: 9),
            Expanded(child: SelectableText(_error!)),
          ],
        ),
      );
    }
    final result = _result;
    if (result == null) {
      return const SizedBox(
        height: 92,
        child: Center(
          child: Text(
            'Generated image and provider response will appear here.',
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final image = ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: ColoredBox(
            color: colors.onSurface.withValues(alpha: 0.04),
            child: AspectRatio(
              aspectRatio: 1,
              child: result.imageBytes != null
                  ? Image.memory(result.imageBytes!, fit: BoxFit.contain)
                  : Image.network(
                      result.imageUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, _) => Center(
                        child: Text('Preview URL gagal dimuat: $error'),
                      ),
                    ),
            ),
          ),
        );
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (result.revisedPrompt?.isNotEmpty == true) ...[
              const _FieldLabel('REVISED PROMPT'),
              const SizedBox(height: 6),
              SelectableText(result.revisedPrompt!),
              const SizedBox(height: 14),
            ],
            const _FieldLabel('JSON'),
            const SizedBox(height: 6),
            Container(
              key: const ValueKey('image-response-preview'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.035),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                result.responsePreview,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
          ],
        );
        if (constraints.maxWidth < 720) {
          return Column(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: image,
              ),
              const SizedBox(height: 16),
              details,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: image),
            const SizedBox(width: 18),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

class _StudioPanel extends StatelessWidget {
  const _StudioPanel({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _StudioFieldRow extends StatelessWidget {
  const _StudioFieldRow({
    required this.label,
    required this.child,
    this.topAligned = false,
  });

  final String label;
  final Widget child;
  final bool topAligned;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [_FieldLabel(label), const SizedBox(height: 6), child],
            );
          }
          return Row(
            crossAxisAlignment: topAligned
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 116,
                child: Padding(
                  padding: EdgeInsets.only(top: topAligned ? 13 : 0),
                  child: _FieldLabel(label),
                ),
              ),
              Expanded(child: child),
            ],
          );
        },
      ),
    );
  }
}

class _StudioSelect extends StatelessWidget {
  const _StudioSelect({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: value,
          items: [
            for (final option in values)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ],
    );
  }
}
