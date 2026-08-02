import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:webview_windows/webview_windows.dart';

import '../services/browser_agent_service.dart';

class AgentBrowserPanel extends StatefulWidget {
  const AgentBrowserPanel({
    super.key,
    required this.service,
    required this.workspace,
    required this.onClose,
    required this.onMessage,
    this.initialUrl,
  });

  final BrowserAgentService service;
  final String workspace;
  final VoidCallback onClose;
  final ValueChanged<String> onMessage;
  final String? initialUrl;

  @override
  State<AgentBrowserPanel> createState() => _AgentBrowserPanelState();
}

class _AgentBrowserPanelState extends State<AgentBrowserPanel> {
  late final TextEditingController _urlController;
  final FocusNode _urlFocus = FocusNode();
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: widget.initialUrl?.trim().isNotEmpty == true
          ? widget.initialUrl!.trim()
          : widget.service.currentUrl,
    );
    widget.service.addListener(_syncUrl);
    _initialize();
  }

  @override
  void didUpdateWidget(covariant AgentBrowserPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_syncUrl);
      widget.service.addListener(_syncUrl);
    }
    final initialUrl = widget.initialUrl?.trim();
    if (initialUrl != null &&
        initialUrl.isNotEmpty &&
        initialUrl != oldWidget.initialUrl) {
      _urlController.text = initialUrl;
      _open(initialUrl);
    }
  }

  Future<void> _initialize() async {
    try {
      await widget.service.initialize();
      final initialUrl = widget.initialUrl?.trim();
      if (initialUrl != null && initialUrl.isNotEmpty) {
        await _open(initialUrl);
      }
    } catch (error) {
      widget.onMessage('$error');
    }
  }

  void _syncUrl() {
    if (!mounted || _urlFocus.hasFocus) return;
    final value = widget.service.currentUrl;
    if (value.isEmpty || value == _urlController.text) return;
    _urlController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _open([String? value]) async {
    if (_opening) return;
    final url = (value ?? _urlController.text).trim();
    if (url.isEmpty) return;
    setState(() => _opening = true);
    try {
      final downloadDirectory = widget.workspace.isEmpty
          ? null
          : path.join(widget.workspace, 'downloads');
      await widget.service.openUrl(url, downloadDirectory: downloadDirectory);
      if (!_urlFocus.hasFocus) _syncUrl();
    } catch (error) {
      widget.onMessage('$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _takeScreenshot({required bool fullPage}) async {
    if (widget.workspace.isEmpty) {
      widget.onMessage('Pilih workspace sebelum menyimpan screenshot browser.');
      return;
    }
    try {
      final result = await widget.service.takeScreenshot(
        path.join(widget.workspace, 'screenshots'),
        fullPage: fullPage,
      );
      widget.onMessage('Screenshot disimpan: $result');
    } catch (error) {
      widget.onMessage('$error');
    }
  }

  Future<void> _showReadablePage() async {
    try {
      final snapshot = await widget.service.readPage(maxCharacters: 16000);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(snapshot.title.isEmpty ? 'Isi halaman' : snapshot.title),
          content: SizedBox(
            width: 720,
            height: 480,
            child: SelectionArea(
              child: SingleChildScrollView(
                child: Text(
                  snapshot.toToolText(),
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('TUTUP'),
            ),
          ],
        ),
      );
    } catch (error) {
      widget.onMessage('$error');
    }
  }

  Future<void> _clearBrowserData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus data Agent Browser?'),
        content: const Text(
          'Cookie dan cache profil browser khusus YOUNZCODE akan dihapus. '
          'Anda dapat keluar dari situs yang sedang login.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('BATAL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('HAPUS'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.service.clearBrowserData();
      widget.onMessage('Cookie dan cache Agent Browser telah dihapus.');
    } catch (error) {
      widget.onMessage('$error');
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_syncUrl);
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        final controller = widget.service.controller;
        return ColoredBox(
          color: colors.surface,
          child: Column(
            children: [
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Kembali',
                      onPressed: state.canGoBack
                          ? () => widget.service.goBack()
                          : null,
                      icon: const Icon(Icons.arrow_back, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Maju',
                      onPressed: state.canGoForward
                          ? () => widget.service.goForward()
                          : null,
                      icon: const Icon(Icons.arrow_forward, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Muat ulang',
                      onPressed: state.initialized
                          ? () => widget.service.reload()
                          : null,
                      icon: const Icon(Icons.refresh, size: 19),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: SizedBox(
                        height: 34,
                        child: TextField(
                          key: const ValueKey('browser-url-field'),
                          controller: _urlController,
                          focusNode: _urlFocus,
                          textInputAction: TextInputAction.go,
                          onSubmitted: _open,
                          decoration: InputDecoration(
                            hintText:
                                'https://example.com atau http://localhost:3000',
                            prefixIcon: Icon(
                              _isSecureUrl(state.url)
                                  ? Icons.lock_outline
                                  : Icons.language,
                              size: 16,
                            ),
                            suffixIcon: _opening || state.loading
                                ? const Padding(
                                    padding: EdgeInsets.all(9),
                                    child: SizedBox.square(
                                      dimension: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    tooltip: 'Buka',
                                    onPressed: _open,
                                    icon: const Icon(Icons.arrow_outward),
                                  ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Baca halaman seperti agent',
                      onPressed: state.initialized ? _showReadablePage : null,
                      icon: const Icon(Icons.subject_outlined, size: 19),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Screenshot',
                      enabled: state.initialized,
                      icon: const Icon(Icons.screenshot_monitor, size: 19),
                      onSelected: (value) =>
                          _takeScreenshot(fullPage: value == 'full'),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'viewport',
                          child: Text('Screenshot viewport'),
                        ),
                        PopupMenuItem(
                          value: 'full',
                          child: Text('Screenshot seluruh halaman'),
                        ),
                      ],
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Opsi browser',
                      onSelected: (value) {
                        if (value == 'devtools') {
                          widget.service.openDevTools();
                        } else if (value == 'clear') {
                          _clearBrowserData();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'devtools',
                          child: Text('Buka DevTools'),
                        ),
                        PopupMenuItem(
                          value: 'clear',
                          child: Text('Hapus cookie dan cache'),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Tutup Agent Browser',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, size: 19),
                    ),
                  ],
                ),
              ),
              if (state.error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  color: colors.errorContainer,
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: colors.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: controller != null && state.initialized
                    ? Webview(
                        controller,
                        permissionRequested:
                            (url, permissionKind, isUserInitiated) async {
                              widget.onMessage(
                                'Izin browser "$permissionKind" ditolak untuk '
                                '$url.',
                              );
                              return WebviewPermissionDecision.deny;
                            },
                      )
                    : _BrowserLoadingState(
                        error: state.error,
                        loading: state.loading,
                      ),
              ),
              Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 15,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Agent Browser · profil terisolasi · upload/delete memakai approval',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        state.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static bool _isSecureUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    return uri?.scheme.toLowerCase() == 'https';
  }
}

class _BrowserLoadingState extends StatelessWidget {
  const _BrowserLoadingState({required this.error, required this.loading});

  final String? error;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const CircularProgressIndicator()
              else
                Icon(
                  Icons.travel_explore,
                  size: 52,
                  color: colors.onSurfaceVariant,
                ),
              const SizedBox(height: 18),
              Text(
                error ??
                    (Platform.isWindows
                        ? 'Menyiapkan Microsoft Edge WebView2…'
                        : 'Agent Browser tersedia untuk build Windows.'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
