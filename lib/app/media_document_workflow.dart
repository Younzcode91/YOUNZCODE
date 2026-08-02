part of '../main.dart';

extension _MediaDocumentWorkflow on _AgentHomePageState {
  Future<void> _downloadMediaFromChat(
    MediaDownloadIntent intent, {
    required String userInput,
  }) async {
    if (_busy) {
      _showMessage('Tunggu operasi saat ini selesai.');
      return;
    }
    if (_workspace.isEmpty || !Directory(_workspace).existsSync()) {
      _showMessage('Pilih workspace yang valid sebelum mengunduh media.');
      return;
    }
    if (!_workspaceTrusted && !await _trustCurrentWorkspace()) return;
    if (!mounted) return;

    final destination = '$_workspace${Platform.pathSeparator}downloads';
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Download media?'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(intent.url.toString()),
              const SizedBox(height: 12),
              Text('Tujuan: $destination'),
              const SizedBox(height: 12),
              const Text(
                'Lanjutkan hanya jika Anda memiliki hak atau izin untuk '
                'mengunduh konten ini. Fitur ini tidak melewati DRM, login, '
                'atau pembatasan akses platform.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('I HAVE PERMISSION'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    _updateState(() {
      _busy = true;
      _turnState = _AgentTurnState.running;
      _agentStatus = 'Memeriksa URL dan yt-dlp';
      _turnStartedAt = DateTime.now();
      _entries.add(ChatEntry(role: ChatRole.user, content: userInput));
    });
    await _persistActiveChat();
    _scrollToBottom();

    try {
      final result = await _mediaDownloadService.download(
        url: intent.url,
        workspace: _workspace,
        onProgress: (progress) {
          if (!mounted) return;
          final details = <String>[
            progress.message,
            if (progress.speed != null && progress.speed!.isNotEmpty)
              progress.speed!,
            if (progress.eta != null &&
                progress.eta!.isNotEmpty &&
                progress.eta != 'NA')
              'ETA ${progress.eta}',
          ];
          _updateState(() => _agentStatus = details.join(' · '));
        },
      );
      if (!mounted) return;
      final location = result.filePath ?? result.outputDirectory;
      _updateState(() {
        _turnState = _AgentTurnState.success;
        _entries.add(
          ChatEntry(
            role: ChatRole.assistant,
            content: 'Unduhan selesai.\n\nLokasi: $location',
          ),
        );
      });
      _notify('Media downloaded', location);
      await _persistActiveChat();
    } on MediaDownloadCancelledException catch (error) {
      if (!mounted) return;
      _updateState(() {
        _turnState = _AgentTurnState.cancelled;
        _entries.add(ChatEntry(role: ChatRole.assistant, content: '$error'));
      });
      await _persistActiveChat();
    } catch (error) {
      if (!mounted) return;
      final message = error is MediaDownloadException
          ? error.message
          : 'Unduhan gagal: $error';
      _updateState(() {
        _turnState = _AgentTurnState.failed;
        _entries.add(ChatEntry(role: ChatRole.error, content: message));
      });
      _notify('Media download failed', message, error: true);
      await _persistActiveChat();
    } finally {
      if (mounted) {
        _updateState(() {
          _busy = false;
          _agentStatus = 'Siap menerima tugas';
          _lastTurnDuration = _turnStartedAt == null
              ? Duration.zero
              : DateTime.now().difference(_turnStartedAt!);
        });
        _scrollToBottom();
      }
    }
  }
}
