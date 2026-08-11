part of '../main.dart';

extension _UpdateWorkflow on _AgentHomePageState {
  /// Checks the release manifest for a newer signed release and offers to
  /// download and install it. Invoked from `/update` and the CHECK FOR UPDATES
  /// button in Model Settings.
  Future<void> _checkForUpdates() async {
    if (_updateChecking) return;
    _updateState(() => _updateChecking = true);
    _showMessage('Memeriksa pembaruan...');
    try {
      final update = await _updateService.check(currentVersion: _appVersion);
      if (!mounted) return;
      if (update == null) {
        _showMessage('YOUNZCODE $_appVersion sudah versi terbaru.');
        return;
      }
      final install = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _UpdateAvailableDialog(
          update: update,
          currentVersion: _appVersion,
        ),
      );
      if (install == true && mounted) await _downloadUpdate(update);
    } catch (error) {
      if (mounted) _showMessage('Gagal memeriksa pembaruan: $error');
      _notify('Update check gagal', '$error', error: true);
    } finally {
      if (mounted) _updateState(() => _updateChecking = false);
    }
  }

  /// Downloads the installer, verifies its Ed25519 signature and SHA-256
  /// checksum, then offers to launch it.
  Future<void> _downloadUpdate(AppUpdate update) async {
    final directory =
        '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}YOUNZCODE'
        '${Platform.pathSeparator}updates';
    await Directory(directory).create(recursive: true);
    final destination =
        '$directory${Platform.pathSeparator}YOUNZCODE-Setup-${update.version}.exe';
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _UpdateProgressDialog(),
    );
    File? installer;
    try {
      installer = await _updateService.downloadAndVerify(update, destination);
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
        _showMessage('Gagal mengunduh pembaruan: $error');
        _notify('Update gagal diunduh', '$error', error: true);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop();
    final runInstaller = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: Text('YOUNZCODE ${update.version} siap diinstal'),
        content: const Text(
          'Installer berhasil diunduh dan diverifikasi '
          '(tanda tangan Ed25519 dan checksum SHA-256 cocok).\n\n'
          'Jalankan installer sekarang? Installer akan mengganti aplikasi '
          'yang sedang berjalan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('LATER'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('RUN INSTALLER'),
          ),
        ],
      ),
    );
    if (runInstaller == true && mounted) {
      final process = await Process.start(installer.path, const []);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      _showMessage('Installer ${update.version} diluncurkan.');
    }
    _notify('Update ${update.version} siap', installer.path);
  }
}

class _UpdateAvailableDialog extends StatelessWidget {
  const _UpdateAvailableDialog({
    required this.update,
    required this.currentVersion,
  });

  final AppUpdate update;
  final String currentVersion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.system_update_alt),
      title: Text('YOUNZCODE ${update.version} tersedia'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terpasang: $currentVersion  ·  Tersedia: ${update.version}'
              ' (${update.channel})',
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            const _FieldLabel('RELEASE NOTES'),
            const SizedBox(height: 6),
            SelectableText(
              update.notes.isEmpty ? 'Tidak ada catatan rilis.' : update.notes,
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.verified_outlined, size: 17, color: colors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Manifest ditandatangani Ed25519; installer diverifikasi '
                    'ulang dengan checksum SHA-256 sebelum dijalankan.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('LATER'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('DOWNLOAD & INSTALL'),
        ),
      ],
    );
  }
}

class _UpdateProgressDialog extends StatelessWidget {
  const _UpdateProgressDialog();

  @override
  Widget build(BuildContext context) => const AlertDialog(
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        SizedBox(width: 16),
        Flexible(child: Text('Mengunduh dan memverifikasi pembaruan...')),
      ],
    ),
  );
}
