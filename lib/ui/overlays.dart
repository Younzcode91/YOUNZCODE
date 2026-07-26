part of '../main.dart';

// Transient overlays: notifications, onboarding, execution summary, and the
// animated agent-working card.

class _AppNotification {
  const _AppNotification({
    required this.title,
    required this.body,
    required this.createdAt,
    required this.error,
  });

  final String title;
  final String body;
  final DateTime createdAt;
  final bool error;
}

class _NotificationDialog extends StatefulWidget {
  const _NotificationDialog({
    required this.notifications,
    required this.revision,
    required this.onDelete,
    required this.onClear,
  });

  final List<_AppNotification> notifications;
  final Listenable revision;
  final ValueChanged<_AppNotification> onDelete;
  final VoidCallback onClear;

  @override
  State<_NotificationDialog> createState() => _NotificationDialogState();
}

class _NotificationDialogState extends State<_NotificationDialog> {
  _AppNotification? _selected;

  void _delete(_AppNotification notification) {
    widget.onDelete(notification);
    setState(() {
      if (identical(_selected, notification)) _selected = null;
    });
  }

  void _clear() {
    widget.onClear();
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.revision,
    builder: (context, _) => AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Notifications')),
          if (widget.notifications.isNotEmpty)
            TextButton(
              key: const ValueKey('clear-all-notifications'),
              onPressed: _clear,
              child: const Text('CLEAR ALL'),
            ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: widget.notifications.isEmpty
            ? const Center(child: Text('No notifications.'))
            : Column(
                children: [
                  if (_selected != null)
                    Container(
                      key: const ValueKey('notification-detail'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selected!.title,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(_selected!.body),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.notifications.length,
                      itemBuilder: (context, index) {
                        final item = widget.notifications[index];
                        return ListTile(
                          key: ValueKey('notification-item-$index'),
                          selected: identical(_selected, item),
                          onTap: () => setState(() => _selected = item),
                          leading: Icon(
                            item.error
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            color: item.error
                                ? Theme.of(context).colorScheme.error
                                : (Theme.of(context).brightness ==
                                          Brightness.light
                                      ? const Color(0xFF2F9E69)
                                      : const Color(0xFF57C08A)),
                          ),
                          title: Text(item.title),
                          subtitle: Text(
                            item.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',
                              ),
                              IconButton(
                                key: ValueKey('delete-notification-$index'),
                                tooltip: 'Delete notification',
                                onPressed: () => _delete(item),
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    ),
  );
}

class _OnboardingDialog extends StatelessWidget {
  const _OnboardingDialog({
    required this.workspaceConfigured,
    required this.providerConfigured,
    required this.model,
    required this.onWorkspace,
    required this.onProvider,
  });

  final bool workspaceConfigured;
  final bool providerConfigured;
  final String model;
  final Future<void> Function() onWorkspace;
  final Future<void> Function() onProvider;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.rocket_launch_outlined),
    title: const Text('Set Up YOUNZCODE'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _OnboardingStep(
              number: 1,
              title: 'Choose workspace',
              complete: workspaceConfigured,
              onTap: onWorkspace,
            ),
            _OnboardingStep(
              number: 2,
              title: 'Configure provider and test connection',
              complete: providerConfigured,
              onTap: onProvider,
            ),
            _OnboardingStep(
              number: 3,
              title: 'Selected model: $model',
              complete: true,
              onTap: onProvider,
            ),
            const _OnboardingStep(
              number: 4,
              title: 'Send your first prompt',
              complete: false,
            ),
            const SizedBox(height: 8),
            const Text(
              'Compatible templates: OpenAI, Ollama, LM Studio, and 9router through MODEL SETTINGS.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('START CODING'),
      ),
    ],
  );
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.number,
    required this.title,
    required this.complete,
    this.onTap,
  });

  final int number;
  final String title;
  final bool complete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(
      child: complete ? const Icon(Icons.check, size: 17) : Text('$number'),
    ),
    title: Text(title),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _ExecutionSummary extends StatelessWidget {
  const _ExecutionSummary({
    required this.activities,
    required this.turnState,
    this.onRetry,
    required this.duration,
    required this.pendingChanges,
    required this.canRevert,
    this.onReviewChanges,
    this.onRevert,
    required this.onHide,
  });

  final List<_AgentActivity> activities;
  final _AgentTurnState turnState;
  final VoidCallback? onRetry;
  final Duration duration;
  final WorkspaceTurnChanges? pendingChanges;
  final bool canRevert;
  final VoidCallback? onReviewChanges;
  final VoidCallback? onRevert;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    // Semantic state colours, kept distinct from the single blue accent.
    final good = light ? const Color(0xFF2F9E69) : const Color(0xFF57C08A);
    final warn = light ? const Color(0xFFB7862A) : const Color(0xFFD7A544);
    final bad = cs.error;
    final complete = activities.where((item) => item.completed).length;
    final failedTools = activities.where((item) => item.failed).length;
    final warningTools = activities.where((item) => item.warning).length;
    final toolIssues = failedTools + warningTools;
    final activityOutcome = turnState == _AgentTurnState.success
        ? toolIssues == 0
              ? ''
              : ' · $toolIssues tool warning${toolIssues == 1 ? '' : 's'}'
        : '${failedTools == 0 ? '' : ' · $failedTools failed'}'
              '${warningTools == 0 ? '' : ' · $warningTools skipped'}';
    final status = switch (turnState) {
      _AgentTurnState.success => ('STATUS: SUCCESS', Icons.check_circle, good),
      _AgentTurnState.cancelled => (
        'STATUS: CANCELLED',
        Icons.stop_circle_outlined,
        warn,
      ),
      _AgentTurnState.timedOut => (
        'STATUS: TIMED OUT',
        Icons.timer_off_outlined,
        bad,
      ),
      _AgentTurnState.paused => (
        'STATUS: CHECKPOINT SAVED',
        Icons.pause_circle_outline,
        warn,
      ),
      _AgentTurnState.failed => ('STATUS: FAILED', Icons.error_outline, bad),
      _ => ('STATUS: COMPLETED WITH ERRORS', Icons.error_outline, bad),
    };
    final canRetry =
        onRetry != null &&
        {
          _AgentTurnState.cancelled,
          _AgentTurnState.timedOut,
          _AgentTurnState.paused,
          _AgentTurnState.failed,
        }.contains(turnState);
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(status.$2, color: status.$3, size: 18),
              const SizedBox(width: 8),
              const Text(
                'EXECUTION SUMMARY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('hide-execution-summary'),
                tooltip: 'Hide execution summary',
                onPressed: onHide,
                icon: const Icon(Icons.expand_more, size: 18),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Text(
                status.$1,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 9,
                  color: status.$3,
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Text(
            '${activities.length} tool events · $complete completed'
            '$activityOutcome · '
            '${duration.inSeconds}s',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (activities.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final activity in activities)
              Container(
                key: ValueKey('completed-tool-${activity.id}'),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: activity.failed
                          ? bad
                          : activity.warning
                          ? warn
                          : good,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 58,
                      child: Text(
                        activity.label,
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: cs.primary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        activity.detail,
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                          height: 1.4,
                          color: activity.failed
                              ? bad
                              : activity.warning
                              ? warn
                              : cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (pendingChanges != null || canRevert) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (pendingChanges != null)
                  FilledButton.icon(
                    key: const ValueKey('summary-review-changes'),
                    onPressed: onReviewChanges,
                    icon: const Icon(Icons.difference_outlined, size: 16),
                    label: Text('REVIEW ${pendingChanges!.files.length} FILES'),
                  ),
                if (canRevert)
                  OutlinedButton.icon(
                    key: const ValueKey('summary-revert-turn'),
                    onPressed: onRevert,
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('REVERT TURN'),
                  ),
              ],
            ),
          ],
          if (canRetry) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('continue-from-checkpoint'),
              onPressed: onRetry,
              icon: const Icon(Icons.replay, size: 16),
              label: const Text('CONTINUE FROM CHECKPOINT'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExecutionSummaryToggle extends StatelessWidget {
  const _ExecutionSummaryToggle({
    required this.turnState,
    required this.duration,
    required this.onShow,
  });

  final _AgentTurnState turnState;
  final Duration duration;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final color = turnState == _AgentTurnState.success
        ? (light ? const Color(0xFF2F9E69) : const Color(0xFF57C08A))
        : turnState == _AgentTurnState.cancelled ||
              turnState == _AgentTurnState.paused
        ? (light ? const Color(0xFFB7862A) : const Color(0xFFD7A544))
        : theme.colorScheme.error;
    final label = turnState == _AgentTurnState.success
        ? 'SUCCESS'
        : turnState.name.toUpperCase();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('show-execution-summary'),
        onPressed: onShow,
        icon: Icon(Icons.expand_less, size: 17, color: color),
        label: Text(
          'SHOW EXECUTION SUMMARY  ·  $label  ·  ${duration.inSeconds}s',
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _AgentWorkingCard extends StatefulWidget {
  const _AgentWorkingCard({required this.status, required this.activities});

  final String status;
  final List<_AgentActivity> activities;

  @override
  State<_AgentWorkingCard> createState() => _AgentWorkingCardState();
}

class _AgentWorkingCardState extends State<_AgentWorkingCard>
    with SingleTickerProviderStateMixin {
  final _elapsed = Stopwatch()..start();
  late final Timer _elapsedTimer;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _elapsedTimer.cancel();
    _elapsed.stop();
    _controller.dispose();
    super.dispose();
  }

  String get _elapsedLabel {
    final totalSeconds = _elapsed.elapsed.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AgentWorkingPalette.fromTheme(Theme.of(context));
    return TweenAnimationBuilder<double>(
      duration: _mediumMotion,
      curve: _motionCurve,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey('agent-working-card'),
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: palette.background,
            border: Border.all(color: palette.border),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomRight: Radius.circular(12),
              bottomLeft: Radius.circular(3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final activity in widget.activities)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 18,
                        child: activity.succeeded
                            ? Icon(Icons.check, size: 14, color: palette.accent)
                            : activity.failed
                            ? Icon(Icons.close, size: 14, color: palette.error)
                            : activity.warning
                            ? Icon(
                                Icons.remove,
                                size: 14,
                                color: palette.mutedText,
                              )
                            : SizedBox(
                                width: 14,
                                height: 14,
                                child: AnimatedBuilder(
                                  animation: _controller,
                                  builder: (context, _) => CustomPaint(
                                    painter: _AgentOrbitPainter(
                                      _controller.value,
                                      orbitColor: palette.orbit,
                                      dotColor: palette.accent,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 54,
                        child: Text(
                          activity.label,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: palette.activity,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Tooltip(
                          message: activity.detail,
                          child: Text(
                            activity.detail,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                              height: 1.35,
                              color: activity.failed
                                  ? palette.error
                                  : activity.warning
                                  ? palette.mutedText
                                  : palette.primaryText,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.activities.isNotEmpty) const Divider(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    key: const ValueKey('response-loading-animation'),
                    width: 120,
                    height: 86,
                    child: Lottie.asset(
                      'assets/younzcode_cat_loading.lottie',
                      decoder: decodeDotLottie,
                      fit: BoxFit.contain,
                      repeat: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: SizedBox(
                      width: 64,
                      child: Text(
                        'Thinking',
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: palette.accent,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSwitcher(
                            duration: _fastMotion,
                            child: Text(
                              widget.status,
                              key: ValueKey(widget.status),
                              style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                color: palette.secondaryText,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_elapsedLabel  ·  '
                            '${widget.activities.where((item) => item.completed).length} '
                            'of ${widget.activities.length} actions completed',
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 10,
                              color: palette.mutedText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentOrbitPainter extends CustomPainter {
  const _AgentOrbitPainter(
    this.progress, {
    required this.orbitColor,
    required this.dotColor,
  });

  final double progress;
  final Color orbitColor;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final orbit = Paint()
      ..color = orbitColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final dot = Paint()..color = dotColor;
    canvas.drawCircle(center, size.shortestSide * 0.34, orbit);
    final angle = progress * 6.283185307179586;
    final radius = size.shortestSide * 0.34;
    canvas.drawCircle(
      center + Offset(radius * math.cos(angle), radius * math.sin(angle)),
      3,
      dot,
    );
  }

  @override
  bool shouldRepaint(covariant _AgentOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.orbitColor != orbitColor ||
      oldDelegate.dotColor != dotColor;
}
