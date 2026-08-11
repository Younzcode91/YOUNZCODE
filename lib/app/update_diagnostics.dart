part of '../main.dart';

/// Diagnostics for release engineers: the trusted signing keys, which key
/// verified the last update check, and how long that check took. Opened via
/// `/update-status` and the UPDATE DIAGNOSTICS button in Model Settings.
class _UpdateDiagnosticsDialog extends StatelessWidget {
  const _UpdateDiagnosticsDialog({
    required this.appVersion,
    required this.channel,
    required this.manifestUrl,
    required this.allowedHosts,
    required this.trustedKeys,
    required this.lastCheckAt,
    required this.lastCheckResult,
    required this.lastVerifiedKey,
    required this.lastCheckMs,
  });

  final String appVersion;
  final String channel;
  final String manifestUrl;
  final List<String> allowedHosts;
  final List<String> trustedKeys;
  final String? lastCheckAt;
  final String? lastCheckResult;
  final String? lastVerifiedKey;
  final int? lastCheckMs;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const mono = TextStyle(fontFamily: 'Consolas', fontSize: 12);
    return AlertDialog(
      icon: const Icon(Icons.verified_user_outlined),
      title: const Text('UPDATE & SIGNING DIAGNOSTICS'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FieldLabel('BUILD'),
              Text('YOUNZCODE $appVersion  ·  channel $channel', style: mono),
              const SizedBox(height: 14),
              const _FieldLabel('MANIFEST'),
              SelectableText(manifestUrl, style: mono),
              const SizedBox(height: 4),
              Text(
                'Allowed hosts: ${allowedHosts.join(', ')}',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('LAST UPDATE CHECK'),
              if (lastCheckAt == null)
                Text(
                  'Belum ada pemeriksaan update di sesi ini.',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                )
              else ...[
                Text('$lastCheckAt  ·  $lastCheckResult', style: mono),
                const SizedBox(height: 4),
                Text(
                  'Latency: ${lastCheckMs == null ? '—' : '$lastCheckMs ms'}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Verified by: ${lastVerifiedKey ?? 'tidak ada (enforcement mati)'}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    color: lastVerifiedKey == null
                        ? colors.onSurfaceVariant
                        : colors.primary,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _FieldLabel('TRUSTED SIGNING KEYS (${trustedKeys.length})'),
              for (final key in trustedKeys) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      key == lastVerifiedKey
                          ? Icons.check_circle
                          : Icons.vpn_key_outlined,
                      size: 14,
                      color: key == lastVerifiedKey
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: SelectableText(key, style: mono)),
                    if (key == lastVerifiedKey) ...[
                      const SizedBox(width: 8),
                      Text(
                        'VERIFIED LAST',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}
