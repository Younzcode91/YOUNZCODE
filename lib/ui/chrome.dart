part of '../main.dart';

// Window chrome: resize handle, command rail, workspace bar/tabs, project
// panel, and the file tree.

class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: AnimatedContainer(
              duration: _fastMotion,
              width: _hovered ? 3 : 1,
              color: _hovered ? colors.primary : Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandRail extends StatelessWidget {
  const _CommandRail({
    required this.onNewChat,
    required this.onChat,
    required this.onFiles,
    required this.onSearch,
    required this.onHistory,
    required this.onAddons,
    required this.onTerminal,
    required this.onSettings,
  });

  final VoidCallback onNewChat;
  final VoidCallback onChat;
  final VoidCallback onFiles;
  final VoidCallback onSearch;
  final VoidCallback onHistory;
  final VoidCallback onAddons;
  final VoidCallback onTerminal;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 560;
    return Container(
      key: const ValueKey('command-rail'),
      width: 72,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          SizedBox(height: compact ? 6 : 16),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(2)),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/younzcode_logo_new.png',
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'v$_appVersion',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: compact ? 5 : 22),
          _RailAction(
            icon: Icons.add_comment_outlined,
            label: 'NEW CHAT',
            onTap: onNewChat,
          ),
          _RailAction(
            icon: Icons.chat_bubble_outline,
            label: 'CHAT',
            selected: true,
            onTap: onChat,
          ),
          _RailAction(
            icon: Icons.folder_outlined,
            label: 'FILES',
            onTap: onFiles,
          ),
          _RailAction(icon: Icons.search, label: 'SEARCH', onTap: onSearch),
          _RailAction(icon: Icons.history, label: 'HISTORY', onTap: onHistory),
          _RailAction(
            icon: Icons.extension_outlined,
            label: 'ADD-ONS',
            onTap: onAddons,
          ),
          const Spacer(),
          _RailAction(
            icon: Icons.terminal,
            label: 'TERMINAL',
            onTap: onTerminal,
          ),
          _RailAction(
            icon: Icons.settings_outlined,
            label: 'SETTINGS',
            onTap: onSettings,
          ),
          SizedBox(height: compact ? 4 : 14),
        ],
      ),
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 560;
    return Tooltip(
      message: label,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 0 : 2),
        child: Material(
          color: selected
              ? colors.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              key: ValueKey('rail-${label.toLowerCase().replaceAll(' ', '-')}'),
              width: 48,
              height: compact ? 36 : 42,
              decoration: BoxDecoration(
                border: selected
                    ? Border(left: BorderSide(color: colors.primary, width: 2))
                    : null,
              ),
              child: Icon(
                icon,
                size: 21,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopWorkspaceBar extends StatelessWidget {
  const _TopWorkspaceBar({
    required this.activeFile,
    required this.searchMode,
    required this.terminalVisible,
    required this.inspectorVisible,
    required this.lightMode,
    required this.onExplorer,
    required this.onEditor,
    required this.onTerminal,
    required this.onInspector,
    required this.onToggleTheme,
    required this.onNotifications,
    required this.notificationCount,
  });

  final String? activeFile;
  final bool searchMode;
  final bool terminalVisible;
  final bool inspectorVisible;
  final bool lightMode;
  final VoidCallback onExplorer;
  final VoidCallback? onEditor;
  final VoidCallback onTerminal;
  final VoidCallback onInspector;
  final VoidCallback onToggleTheme;
  final VoidCallback onNotifications;
  final int notificationCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('top-workspace-bar'),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            'YOUNZCODE',
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(width: 20),
          _WorkspaceTab(
            label: 'Explorer',
            active: activeFile == null && !searchMode && !terminalVisible,
            onTap: onExplorer,
          ),
          _WorkspaceTab(
            label: 'Editor',
            active: activeFile != null,
            onTap: onEditor,
          ),
          _WorkspaceTab(
            label: 'Terminal',
            active: terminalVisible,
            onTap: onTerminal,
          ),
          _WorkspaceTab(
            key: const ValueKey('show-activity-panel'),
            label: 'Inspector',
            active: inspectorVisible,
            onTap: onInspector,
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('theme-toggle'),
            tooltip: lightMode ? 'Gunakan mode gelap' : 'Gunakan mode terang',
            onPressed: onToggleTheme,
            icon: Icon(
              lightMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              size: 20,
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 1000)
            IconButton(
              tooltip: 'Project settings',
              onPressed: onInspector,
              icon: const Icon(Icons.account_tree_outlined, size: 20),
            ),
          IconButton(
            key: const ValueKey('notifications-button'),
            tooltip: 'Notifications',
            onPressed: onNotifications,
            icon: Badge(
              isLabelVisible: notificationCount > 0,
              label: Text('${notificationCount.clamp(0, 99)}'),
              child: const Icon(Icons.notifications_none, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTab extends StatelessWidget {
  const _WorkspaceTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        margin: const EdgeInsets.only(right: 12),
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
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ProjectPanel extends StatefulWidget {
  const _ProjectPanel({
    required this.workspace,
    required this.onOpenFile,
    required this.onChoose,
    required this.onNewChat,
    required this.onChat,
    required this.onTerminal,
    required this.onHistory,
    required this.onAddons,
    required this.onSettings,
    required this.onSearch,
    required this.onHide,
  });

  final String workspace;
  final ValueChanged<String> onOpenFile;
  final VoidCallback onChoose;
  final VoidCallback onNewChat;
  final VoidCallback onChat;
  final VoidCallback onTerminal;
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final VoidCallback onHistory;
  final VoidCallback onAddons;
  final VoidCallback onHide;

  @override
  State<_ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<_ProjectPanel> {
  int _treeRevision = 0;
  bool _treeExpanded = true;
  final _filterController = TextEditingController();

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ProjectPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) _treeRevision++;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = Theme.of(context).colorScheme;
    final folderName = widget.workspace.isEmpty
        ? 'Belum dipilih'
        : widget.workspace.replaceAll('\\', '/').split('/').last;
    return Container(
      key: const ValueKey('workspace-explorer'),
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'WORKSPACE',
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onChoose,
                  tooltip: 'Choose workspace',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_horiz, size: 18),
                ),
                IconButton(
                  key: const ValueKey('hide-explorer-panel'),
                  onPressed: widget.onHide,
                  tooltip: 'Hide Explorer',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: InkWell(
              onTap: widget.onChoose,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                color: colors.primary.withValues(alpha: 0.12),
                child: Text(
                  widget.workspace.isEmpty
                      ? '/select/a/project'
                      : widget.workspace,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: SizedBox(
              height: 38,
              child: TextField(
                key: const ValueKey('file-filter'),
                controller: _filterController,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Filter files...',
                  prefixIcon: Icon(Icons.search, size: 18),
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
          if (widget.workspace.isNotEmpty) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('workspace-tree-root-toggle'),
                onTap: () => setState(() => _treeExpanded = !_treeExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _treeExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 17,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.folder_outlined,
                        size: 18,
                        color: colors.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          folderName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => setState(() => _treeRevision++),
                        tooltip: 'Refresh file tree',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 15),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_treeExpanded)
              Expanded(
                child: _WorkspaceTree(
                  key: ValueKey('${widget.workspace}:$_treeRevision'),
                  root: widget.workspace,
                  filter: _filterController.text,
                  onOpenFile: widget.onOpenFile,
                ),
              )
            else
              const Spacer(),
          ] else
            Expanded(
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: widget.onChoose,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('SELECT WORKSPACE'),
                ),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RECENT',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.workspace.isEmpty
                      ? 'No workspace history'
                      : 'History is available from the command rail',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
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

class _WorkspaceTree extends StatefulWidget {
  const _WorkspaceTree({
    super.key,
    required this.root,
    this.filter = '',
    required this.onOpenFile,
  });

  final String root;
  final String filter;
  final ValueChanged<String> onOpenFile;

  @override
  State<_WorkspaceTree> createState() => _WorkspaceTreeState();
}

class _WorkspaceTreeState extends State<_WorkspaceTree> {
  late Future<List<FileSystemEntity>> _entries = _readDirectory(widget.root);

  static Future<List<FileSystemEntity>> _readDirectory(String directory) async {
    final entries = await Directory(
      directory,
    ).list(followLinks: false).toList();
    entries.sort((left, right) {
      final leftDirectory = left is Directory;
      final rightDirectory = right is Directory;
      if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
      return _entityName(
        left,
      ).toLowerCase().compareTo(_entityName(right).toLowerCase());
    });
    return entries;
  }

  static String _entityName(FileSystemEntity entity) =>
      entity.path.replaceAll('\\', '/').split('/').last;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FileSystemEntity>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          );
        }
        if (snapshot.hasError) {
          return _TreeMessage(
            icon: Icons.error_outline,
            message: 'Gagal membaca folder',
            onRetry: () =>
                setState(() => _entries = _readDirectory(widget.root)),
          );
        }
        final query = widget.filter.trim().toLowerCase();
        final entries = query.isEmpty
            ? snapshot.data!
            : snapshot.data!
                  .where(
                    (entry) => _entityName(entry).toLowerCase().contains(query),
                  )
                  .toList();
        if (entries.isEmpty) {
          return const _TreeMessage(
            icon: Icons.folder_off_outlined,
            message: 'Folder kosong',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          itemCount: entries.length,
          itemBuilder: (context, index) => _FileTreeEntry(
            key: ValueKey(entries[index].path),
            entity: entries[index],
            depth: 0,
            onOpenFile: widget.onOpenFile,
          ),
        );
      },
    );
  }
}

class _FileTreeEntry extends StatefulWidget {
  const _FileTreeEntry({
    super.key,
    required this.entity,
    required this.depth,
    required this.onOpenFile,
  });

  final FileSystemEntity entity;
  final int depth;
  final ValueChanged<String> onOpenFile;

  @override
  State<_FileTreeEntry> createState() => _FileTreeEntryState();
}

class _FileTreeEntryState extends State<_FileTreeEntry> {
  bool _expanded = false;
  Future<List<FileSystemEntity>>? _children;

  bool get _isDirectory => widget.entity is Directory;

  void _toggle() {
    if (!_isDirectory) return;
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _children ??= _WorkspaceTreeState._readDirectory(widget.entity.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = _WorkspaceTreeState._entityName(widget.entity);
    final icon = _isDirectory
        ? (_expanded ? Icons.folder_open : Icons.folder)
        : _fileIcon(name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: widget.entity.path,
          waitDuration: const Duration(milliseconds: 650),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              onTap: _isDirectory
                  ? _toggle
                  : () => widget.onOpenFile(widget.entity.path),
              highlightColor: const Color(0x3379D6CD),
              splashColor: const Color(0x4479D6CD),
              child: SizedBox(
                height: 28,
                child: Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        child: _isDirectory
                            ? Icon(
                                _expanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                size: 15,
                                color: colors.onSurfaceVariant,
                              )
                            : null,
                      ),
                      Icon(
                        icon,
                        size: 15,
                        color: _isDirectory
                            ? colors.secondary
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w500,
                            color: _isDirectory
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
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
        if (_expanded && _children != null)
          FutureBuilder<List<FileSystemEntity>>(
            future: _children,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.2),
                  ),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: Text(
                    'Tidak dapat dibaca',
                    style: TextStyle(fontSize: 9, color: colors.error),
                  ),
                );
              }
              final children = snapshot.data!;
              if (children.isEmpty) {
                return Padding(
                  padding: EdgeInsets.only(left: widget.depth * 14.0 + 34),
                  child: Text(
                    'Folder kosong',
                    style: TextStyle(
                      fontSize: 9,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final child in children)
                    _FileTreeEntry(
                      key: ValueKey(child.path),
                      entity: child,
                      depth: widget.depth + 1,
                      onOpenFile: widget.onOpenFile,
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  IconData _fileIcon(String name) {
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    return switch (extension) {
      'dart' => Icons.flutter_dash,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object,
      'md' || 'txt' => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'ico' => Icons.image_outlined,
      'exe' || 'dll' => Icons.memory,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

class _TreeMessage extends StatelessWidget {
  const _TreeMessage({required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onRetry,
        icon: Icon(icon, size: 16),
        label: Text(message, style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}
