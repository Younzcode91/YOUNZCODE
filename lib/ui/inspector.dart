part of '../main.dart';

// Inspector + conversation widgets: activity/plan/files panels, metrics,
// message cards, model bar, composer, suggestions, and status bar.

class _AgentActivity {
  const _AgentActivity({
    required this.id,
    required this.name,
    required this.detail,
    required this.state,
  });

  final String id;
  final String name;
  final String detail;
  final String state;

  String get label => switch (name) {
    'run_command' => 'Shell',
    'read_file' => 'Read',
    'write_file' => 'Write',
    'replace_text' => 'Edit',
    'list_files' => 'Glob',
    'search_text' => 'Grep',
    _ when name.startsWith('mcp_') => 'MCP',
    _ => name,
  };

  bool get running => state == 'berjalan';
  bool get completed => !running;
  bool get succeeded => state == 'selesai';
  bool get failed => state == 'gagal';
  bool get warning => state == 'ditolak' || state == 'dibatalkan';
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({
    super.key,
    required this.activities,
    required this.busy,
    required this.status,
    required this.onHide,
    required this.section,
    required this.onSectionChanged,
    required this.pendingChanges,
    required this.changeHistory,
    required this.onReviewChanges,
    this.onRevert,
  });

  final List<_AgentActivity> activities;
  final bool busy;
  final String status;
  final VoidCallback onHide;
  final _InspectorSection section;
  final ValueChanged<_InspectorSection> onSectionChanged;
  final WorkspaceTurnChanges? pendingChanges;
  final List<WorkspaceTurnChanges> changeHistory;
  final VoidCallback onReviewChanges;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final last = activities.isEmpty ? null : activities.last;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 52,
            child: Stack(
              children: [
                Row(
                  children: [
                    _InspectorTab(
                      label: 'ACTIVITY',
                      active: section == _InspectorSection.activity,
                      onTap: () => onSectionChanged(_InspectorSection.activity),
                    ),
                    _InspectorTab(
                      label: 'PLAN',
                      active: section == _InspectorSection.plan,
                      onTap: () => onSectionChanged(_InspectorSection.plan),
                    ),
                    _InspectorTab(
                      label: pendingChanges == null
                          ? 'FILES'
                          : 'FILES ${pendingChanges!.files.length}',
                      active: section == _InspectorSection.files,
                      onTap: () => onSectionChanged(_InspectorSection.files),
                    ),
                  ],
                ),
                Positioned(
                  right: 2,
                  top: 13,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      key: const ValueKey('hide-activity-panel'),
                      onPressed: onHide,
                      tooltip: 'Hide tool activity',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.chevron_right, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: section == _InspectorSection.files
                ? _InspectorFiles(
                    changes: pendingChanges,
                    history: changeHistory,
                    onReview: onReviewChanges,
                    onRevert: onRevert,
                  )
                : section == _InspectorSection.plan
                ? _InspectorPlan(activities: activities, busy: busy)
                : ListView(
                    padding: const EdgeInsets.all(18),
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: busy
                                  ? colors.primary
                                  : (Theme.of(context).brightness ==
                                            Brightness.light
                                        ? const Color(0xFF2F9E69)
                                        : const Color(0xFF57C08A)),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              busy
                                  ? 'AGENT: ${status.toUpperCase()}'
                                  : 'AGENT: IDLE',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: Column(
                          children: [
                            _InspectorMetric(
                              label: 'Last tool:',
                              value: last?.label ?? 'none',
                              accent: true,
                            ),
                            const SizedBox(height: 12),
                            _InspectorMetric(
                              label: 'Status:',
                              value:
                                  last?.state ?? (busy ? 'Running' : 'Ready'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      const _InspectorHeading('SYSTEM LOAD'),
                      const SizedBox(height: 12),
                      _LoadBar(label: 'COMPUTE', value: busy ? 0.72 : 0.12),
                      const SizedBox(height: 14),
                      _LoadBar(
                        label: 'CONTEXT',
                        value: activities.isEmpty ? 0.04 : 0.28,
                        tertiary: true,
                      ),
                      const SizedBox(height: 28),
                      const _InspectorHeading('NOTIFICATIONS'),
                      const SizedBox(height: 12),
                      if (activities.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.06),
                            border: Border(
                              left: BorderSide(color: colors.primary),
                            ),
                          ),
                          child: Text(
                            'NO ACTIVITY DETECTED',
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        for (final activity in activities.reversed)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: colors.primary),
                              ),
                              color: colors.primary.withValues(alpha: 0.05),
                            ),
                            child: Text(
                              '${activity.label}\n${activity.detail}\n${activity.state.toUpperCase()}',
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 10,
                                height: 1.4,
                              ),
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

class _InspectorPlan extends StatelessWidget {
  const _InspectorPlan({required this.activities, required this.busy});

  final List<_AgentActivity> activities;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (activities.isEmpty) {
      return Center(
        child: Text(
          busy ? 'MENYIAPKAN RENCANA...' : 'BELUM ADA RENCANA',
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(18),
      itemCount: activities.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final activity = activities[index];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}.',
                style: TextStyle(fontFamily: 'Consolas', color: colors.primary),
              ),
            ),
            Expanded(
              child: Text(
                '${activity.label}\n${activity.detail}',
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InspectorFiles extends StatelessWidget {
  const _InspectorFiles({
    required this.changes,
    required this.history,
    required this.onReview,
    this.onRevert,
  });

  final WorkspaceTurnChanges? changes;
  final List<WorkspaceTurnChanges> history;
  final VoidCallback onReview;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final files = changes?.files ?? const <WorkspaceFileChange>[];
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (files.isEmpty)
          Text(
            'TIDAK ADA PERUBAHAN TERTUNDA',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: colors.onSurfaceVariant,
            ),
          )
        else ...[
          for (final file in files)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Text(
                file.status,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.w700,
                  color: colors.primary,
                ),
              ),
              title: Text(
                file.path,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
              ),
              subtitle: Text('${file.hunks.length} hunk'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onReview,
            child: const Text('REVIEW CHANGES'),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            '${history.length} TURN TERSIMPAN',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 10,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (onRevert != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRevert,
            child: const Text('REVERT LAST TURN'),
          ),
        ],
      ],
    );
  }
}

class _ChangesReviewDialog extends StatefulWidget {
  const _ChangesReviewDialog({required this.changes});

  final WorkspaceTurnChanges changes;

  @override
  State<_ChangesReviewDialog> createState() => _ChangesReviewDialogState();
}

class _ChangesReviewDialogState extends State<_ChangesReviewDialog> {
  late final Set<String> _selected = {
    for (final file in widget.changes.files)
      for (final hunk in file.hunks) hunk.id,
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review agent changes'),
    content: SizedBox(
      width: 760,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final file in widget.changes.files) ...[
            Text(
              '${file.status}  ${file.path}',
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final hunk in file.hunks)
              CheckboxListTile(
                value: _selected.contains(hunk.id),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _selected.add(hunk.id);
                  } else {
                    _selected.remove(hunk.id);
                  }
                }),
                title: Text(
                  hunk.unified,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('CANCEL'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, <String>{}),
        child: const Text('REJECT ALL'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, Set<String>.of(_selected)),
        child: Text('APPLY ${_selected.length} HUNKS'),
      ),
    ],
  );
}

class _InspectorTab extends StatelessWidget {
  const _InspectorTab({
    required this.label,
    this.active = false,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: active
                ? Border(bottom: BorderSide(color: colors.primary, width: 2))
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: active ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorMetric extends StatelessWidget {
  const _InspectorMetric({
    required this.label,
    required this.value,
    this.accent = false,
  });
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: colors.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 11,
            color: accent ? colors.primary : colors.onSurface,
          ),
        ),
      ],
    );
  }
}

class _InspectorHeading extends StatelessWidget {
  const _InspectorHeading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      fontFamily: 'Consolas',
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _LoadBar extends StatelessWidget {
  const _LoadBar({
    required this.label,
    required this.value,
    this.tertiary = false,
  });
  final String label;
  final double value;
  final bool tertiary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 9),
            ),
            const Spacer(),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 9),
            ),
          ],
        ),
        const SizedBox(height: 5),
        LinearProgressIndicator(
          value: value,
          minHeight: 2,
          color: tertiary ? colors.tertiary : colors.primary,
          backgroundColor: colors.onSurface.withValues(alpha: 0.12),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final horizontalPadding = compact ? 20.0 : 32.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 28,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 720,
                minHeight: math.max(0, constraints.maxHeight - 56),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: 0.18,
                    child: Container(
                      width: compact ? 88 : 112,
                      height: compact ? 88 : 112,
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      child: Image.asset(
                        'assets/younzcode_logo_new.png',
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 20 : 28),
                  Text(
                    'What are we building?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 27 : 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Select a workspace or describe a task to begin. I can help '
                    'with architecture, debugging, or test automation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                  SizedBox(height: compact ? 22 : 30),
                  GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: compact ? 1 : 2,
                    mainAxisExtent: 82,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _SuggestionCard(
                        icon: Icons.bolt_outlined,
                        title: 'Generate Feature',
                        subtitle: 'Bootstrap new module',
                        onTap: () => onSuggestion(
                          'Buat fitur baru dengan mengikuti pola kode yang sudah ada.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.bug_report_outlined,
                        title: 'Fix Logic Bug',
                        subtitle: 'Trace and repair errors',
                        onTap: () => onSuggestion(
                          'Bantu saya menganalisis dan memperbaiki bug pada proyek ini.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.checklist_rtl_outlined,
                        title: 'Write Test Suite',
                        subtitle: 'Unit & integration coverage',
                        onTap: () => onSuggestion(
                          'Jalankan semua test dan perbaiki kegagalan yang ditemukan.',
                        ),
                      ),
                      _SuggestionCard(
                        icon: Icons.menu_book_outlined,
                        title: 'Explain Codebase',
                        subtitle: 'Analyze relationships',
                        onTap: () => onSuggestion(
                          'Jelaskan arsitektur proyek ini dan modul-modul utamanya.',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({super.key, required this.entry});

  final ChatEntry entry;

  Future<void> _copyResponse(BuildContext context, String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Respons disalin.'),
          duration: Duration(seconds: 1),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final user = entry.role == ChatRole.user;
    final error = entry.role == ChatRole.error;
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final displayedContent = user
        ? entry.content
        : formatAgentResponse(entry.content);
    return TweenAnimationBuilder<double>(
      duration: _mediumMotion,
      curve: _motionCurve,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset((user ? 12 : -12) * (1 - value), 6 * (1 - value)),
          child: child,
        ),
      ),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: user
                ? theme.colorScheme.primary.withValues(
                    alpha: light ? 0.07 : 0.13,
                  )
                : theme.colorScheme.surface,
            border: Border.all(
              color: error
                  ? Theme.of(context).colorScheme.error
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(user ? 12 : 3),
              bottomRight: Radius.circular(user ? 3 : 12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    user
                        ? 'YOU'
                        : error
                        ? 'ERROR'
                        : 'AGENT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: error
                          ? Theme.of(context).colorScheme.error
                          : user
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                    ),
                  ),
                  if (!user) ...[
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('copy-agent-response'),
                      tooltip: 'Salin respons',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () => _copyResponse(context, displayedContent),
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                displayedContent,
                style: TextStyle(
                  height: user ? 1.55 : 1.65,
                  fontSize: user ? 13.5 : 14,
                ),
              ),
              if (!user) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('copy-agent-response-bottom'),
                    onPressed: () => _copyResponse(context, displayedContent),
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    label: const Text('COPY RESPONSE'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelBar extends StatelessWidget {
  const _ModelBar({
    required this.models,
    required this.selectedModel,
    required this.busy,
    required this.planMode,
    required this.onSelected,
    required this.onManage,
    required this.onPlanModeChanged,
  });

  final List<String> models;
  final String selectedModel;
  final bool busy;
  final bool planMode;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage;
  final ValueChanged<bool> onPlanModeChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final modelControls = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.06),
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: colors.onSurface,
                  ),
                  const SizedBox(width: 7),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('model-selector'),
                      value: selectedModel,
                      borderRadius: BorderRadius.circular(8),
                      dropdownColor: colors.surface,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                        color: colors.onSurface,
                      ),
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value != null) onSelected(value);
                            },
                      items: [
                        for (final model in models)
                          DropdownMenuItem(value: model, child: Text(model)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: busy ? null : onManage,
              icon: const Icon(Icons.description_outlined, size: 15),
              label: const Text('MANAGE MODELS'),
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                side: BorderSide(color: colors.primary.withValues(alpha: 0.45)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        );
        final planControl = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: const ValueKey('agent-mode-selector'),
              value: planMode,
              onChanged: busy ? null : onPlanModeChanged,
            ),
            const SizedBox(width: 6),
            Text(
              'Plan Mode',
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 11,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        );
        return Container(
          height: compact ? 112 : 56,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: compact
              ? Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: modelControls,
                    ),
                    const Spacer(),
                    Align(alignment: Alignment.centerRight, child: planControl),
                  ],
                )
              : Row(children: [modelControls, const Spacer(), planControl]),
        );
      },
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.planMode,
    required this.onPlanModeChanged,
    required this.contextFiles,
    required this.onAttachContext,
    required this.onRemoveContext,
    required this.onClearContext,
    required this.slashCommands,
    required this.onSlashCommand,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool planMode;
  final ValueChanged<bool> onPlanModeChanged;
  final List<String> contextFiles;
  final VoidCallback onAttachContext;
  final ValueChanged<String> onRemoveContext;
  final VoidCallback onClearContext;
  final List<_SlashCommand> slashCommands;
  final Future<void> Function(String command) onSlashCommand;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _hasText = false;
  List<_SlashCommand> _matchingCommands = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncText);
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncText);
      widget.controller.addListener(_syncText);
      _syncText();
    }
  }

  void _syncText() {
    final text = widget.controller.text.trim();
    final hasText = text.isNotEmpty;
    final matchingCommands = text.startsWith('/') && !text.contains(' ')
        ? widget.slashCommands
              .where((item) => item.command.startsWith(text.toLowerCase()))
              .toList()
        : const <_SlashCommand>[];
    if (mounted) {
      setState(() {
        _hasText = hasText;
        _matchingCommands = matchingCommands;
      });
    }
  }

  Future<void> _selectCommand(_SlashCommand command) async {
    widget.controller.clear();
    await widget.onSlashCommand(command.command);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncText);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_matchingCommands.isNotEmpty)
            Container(
              key: const ValueKey('slash-command-menu'),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height >= 700 ? 440 : 280,
              ),
              margin: const EdgeInsets.only(bottom: 6),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 480 ? 2 : 1;
                    final itemWidth = constraints.maxWidth / columns;
                    return Wrap(
                      children: [
                        for (final command in _matchingCommands)
                          SizedBox(
                            width: itemWidth,
                            child: ListTile(
                              key: ValueKey(
                                'slash-command-${command.command.substring(1)}',
                              ),
                              dense: true,
                              minTileHeight: 52,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(
                                command.icon,
                                size: 17,
                                color: colors.primary,
                              ),
                              title: Text(
                                command.command,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                command.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: widget.busy
                                  ? null
                                  : () => _selectCommand(command),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          if (widget.contextFiles.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '${widget.contextFiles.length} files · ~${_estimatedTokens()} tokens',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 10,
                    color: colors.primary,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('clear-context'),
                  onPressed: widget.busy ? null : widget.onClearContext,
                  child: const Text('CLEAR CONTEXT'),
                ),
              ],
            ),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.contextFiles.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final file = widget.contextFiles[index];
                  return InputChip(
                    label: Text(
                      file.replaceAll('\\', '/').split('/').last,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                      ),
                    ),
                    onDeleted: widget.busy
                        ? null
                        : () => widget.onRemoveContext(file),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): () {
                    if (!widget.busy && _hasText) widget.onSend();
                  },
                },
                child: TextField(
                  key: const ValueKey('prompt-field'),
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 4,
                  maxLines: 7,
                  enabled: !widget.busy,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                  decoration: const InputDecoration(
                    hintText: 'Describe a task or type / for commands...',
                    contentPadding: EdgeInsets.fromLTRB(16, 16, 64, 24),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: FilledButton(
                    key: ValueKey(widget.busy ? 'stop-agent' : 'send-agent'),
                    onPressed: widget.busy
                        ? widget.onStop
                        : !_hasText
                        ? null
                        : widget.onSend,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: widget.busy
                          ? colors.error
                          : colors.primary,
                    ),
                    child: Icon(
                      widget.busy ? Icons.stop_rounded : Icons.send_rounded,
                      color: colors.onPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              TextButton.icon(
                key: const ValueKey('attach-context'),
                onPressed: widget.busy ? null : widget.onAttachContext,
                icon: const Icon(Icons.attach_file, size: 14),
                label: Text('${widget.contextFiles.length} FILES'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.planMode
                      ? 'READ-ONLY · Enter to send · Shift+Enter for new line'
                      : 'Enter to send · Shift+Enter for new line',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 9,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _estimatedTokens() {
    var bytes = 0;
    for (final file in widget.contextFiles) {
      try {
        bytes += File(file).lengthSync();
      } catch (_) {}
    }
    return (bytes / 4).ceil();
  }
}

class _SuggestionCard extends StatefulWidget {
  const _SuggestionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<_SuggestionCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: AnimatedScale(
        duration: _fastMotion,
        curve: _motionCurve,
        scale: _pressed ? 0.975 : 1,
        child: AnimatedContainer(
          duration: _fastMotion,
          curve: _motionCurve,
          transform: Matrix4.translationValues(0, _pressed ? 2 : 0, 0),
          decoration: BoxDecoration(
            color: _pressed
                ? colors.primary.withValues(alpha: light ? 0.10 : 0.16)
                : _hovered
                ? colors.primary.withValues(alpha: light ? 0.06 : 0.10)
                : colors.surface,
            border: Border.all(
              color: _hovered ? colors.primary : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: _hovered && !_pressed
                ? const [
                    BoxShadow(
                      color: Color(0x24000000),
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: widget.onTap,
              onHighlightChanged: (pressed) =>
                  setState(() => _pressed = pressed),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: _fastMotion,
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _hovered
                            ? colors.primary.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Icon(widget.icon, size: 19, color: colors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 9,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedSlide(
                      duration: _fastMotion,
                      offset: _hovered ? Offset.zero : const Offset(-0.25, 0),
                      child: AnimatedOpacity(
                        duration: _fastMotion,
                        opacity: _hovered ? 1 : 0.35,
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          size: 17,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.connected,
    required this.configured,
    required this.busy,
    required this.model,
    required this.status,
    required this.tokens,
    required this.gitStatus,
    required this.onGit,
    required this.workspaceTrusted,
    required this.onTrustWorkspace,
  });

  final bool connected;
  final bool configured;
  final bool busy;
  final String model;
  final String status;
  final int tokens;
  final GitStatus gitStatus;
  final VoidCallback onGit;
  final bool workspaceTrusted;
  final VoidCallback onTrustWorkspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final state = busy
        ? status.toUpperCase()
        : connected
        ? 'API CONNECTED'
        : configured
        ? 'API CONFIGURED · NOT VERIFIED'
        : 'OFFLINE';
    final color = connected
        ? colors.primary
        : configured
        ? (light ? const Color(0xFFB7862A) : const Color(0xFFD7A544))
        : colors.onSurfaceVariant;
    return Container(
      key: const ValueKey('status-bar'),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Environment: Windows  |  Model: $model  |  Build: v$_appVersion'
              '${tokens > 0 ? '  |  Tokens: $tokens' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 10,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (gitStatus.isRepository) ...[
            const SizedBox(width: 16),
            InkWell(
              onTap: onGit,
              child: Text(
                '${gitStatus.branch}${gitStatus.dirty ? ' *' : ''}',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 10,
                  color: gitStatus.dirty ? colors.tertiary : colors.primary,
                ),
              ),
            ),
          ],
          if (!workspaceTrusted) ...[
            const SizedBox(width: 16),
            InkWell(
              key: const ValueKey('restricted-mode-action'),
              onTap: onTrustWorkspace,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'RESTRICTED MODE · TRUST WORKSPACE',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: colors.tertiary,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            connected ? 'SYNCED' : state,
            style: TextStyle(fontFamily: 'Consolas', fontSize: 9, color: color),
          ),
        ],
      ),
    );
  }
}
