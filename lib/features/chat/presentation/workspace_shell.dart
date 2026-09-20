import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/agents/agents.dart';
import '../../../design_system/design_system.dart';
import '../application/chat_token_presenter.dart';
import 'chat_sidebar.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    required this.chats,
    required this.selectedId,
    required this.title,
    required this.modelLabel,
    required this.modelLabelFor,
    required this.body,
    required this.composer,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onOpenSettings,
    required this.enabled,
    this.issueCount = 0,
    this.tokenProjection,
    this.onOpenTokens,
    this.onDeleteChat,
    this.deleteFocusNode,
    this.newChatFocusNode,
    this.aboveChats,
    this.onOpenUsage,
    this.themeMode,
    this.onThemeModeChanged,
    this.usageSelected = false,
    this.providersSelected = false,
    this.projectName,
    this.projectRoot,
    this.showComposer = true,
    this.memoryPanel,
    this.onOpenMemory,
    this.memorySelected = false,
    super.key,
  });

  final List<AgentSessionSummary> chats;
  final AgentSessionId? selectedId;
  final String title;
  final String modelLabel;
  final String Function(AgentSessionSummary summary) modelLabelFor;
  final Widget body;
  final Widget composer;
  final VoidCallback? onNewChat;
  final ValueChanged<AgentSessionId>? onSelectChat;
  final VoidCallback? onOpenSettings;
  final bool enabled;
  final int issueCount;
  final ChatTokenProjection? tokenProjection;
  final VoidCallback? onOpenTokens;
  final VoidCallback? onDeleteChat;
  final FocusNode? deleteFocusNode;
  final FocusNode? newChatFocusNode;
  final Widget? aboveChats;
  final VoidCallback? onOpenUsage;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final bool usageSelected;
  final bool providersSelected;
  final String? projectName;
  final String? projectRoot;
  final bool showComposer;
  final Widget? memoryPanel;
  final VoidCallback? onOpenMemory;
  final bool memorySelected;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  var _panelOpen = false;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final layout = resolveWorkspaceLayout(
      media.size,
      media.textScaler.scale(1),
    );
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newChat,
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newChat,
      const SingleActivator(LogicalKeyboardKey.comma, control: true):
          _openSettings,
      const SingleActivator(LogicalKeyboardKey.comma, meta: true):
          _openSettings,
      const SingleActivator(LogicalKeyboardKey.escape): _dismissTopmost,
    };
    final sidebar = ChatSidebar(
      chats: widget.chats,
      selectedId: widget.selectedId,
      modelLabelFor: widget.modelLabelFor,
      onNewChat: widget.onNewChat,
      onSelectChat: (id) {
        widget.onSelectChat?.call(id);
        if (!layout.isDesktop) Navigator.maybePop(context);
      },
      onOpenSettings: widget.onOpenSettings,
      enabled: widget.enabled,
      issueCount: widget.issueCount,
      newChatFocusNode: widget.newChatFocusNode,
      aboveChats: widget.aboveChats,
      onOpenUsage: widget.onOpenUsage,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      usageSelected: widget.usageSelected,
      providersSelected: widget.providersSelected,
    );
    return CallbackShortcuts(
      bindings: shortcuts,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Scaffold(
          key: _scaffoldKey,
          drawer: layout.isDesktop
              ? null
              : SizedBox(width: DomovoyDimensions.sidebarWidth, child: sidebar),
          body: DomovoySurface(
            role: DomovoySurfaceRole.canvas,
            child: layout.isDesktop
                ? Row(
                    key: const ValueKey('workspace-wide'),
                    children: [
                      SizedBox(width: layout.sidebarWidth, child: sidebar),
                      VerticalDivider(
                        width: DomovoyDimensions.hairline,
                        thickness: DomovoyDimensions.hairline,
                        color: context.domovoyTheme.border,
                      ),
                      Expanded(child: _content(context, layout)),
                    ],
                  )
                : KeyedSubtree(
                    key: const ValueKey('workspace-narrow'),
                    child: _content(context, layout),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, WorkspaceLayoutSpec layout) {
    final tokens = context.domovoyTheme;
    return SafeArea(
      child: Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: layout.isDesktop
                  ? DomovoyDimensions.headerHeight
                  : DomovoyDimensions.narrowHeaderHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DomovoyDimensions.space4,
              ),
              child: Row(
                children: [
                  if (!layout.isDesktop) ...[
                    DomovoyQuietButton(
                      key: const ValueKey('chat-list-open'),
                      minSize: const Size.square(
                        DomovoyDimensions.minimumTarget,
                      ),
                      alignment: Alignment.center,
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      child: const Text('☰'),
                    ),
                    const SizedBox(width: DomovoyDimensions.space2),
                  ],
                  Builder(
                    builder: (buttonContext) => DomovoyQuietButton(
                      key: const ValueKey('folder-button'),
                      minSize: const Size.square(
                        DomovoyDimensions.minimumTarget,
                      ),
                      alignment: Alignment.center,
                      onPressed: () => _openFolder(buttonContext),
                      tooltip: 'Папка текущего проекта',
                      child: DomovoyIcon(
                        DomovoyIconKind.folder,
                        size: DomovoyDimensions.iconMedium,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: DomovoyDimensions.space3),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (widget.memoryPanel != null || widget.onOpenMemory != null)
                    DomovoyQuietButton(
                      key: const ValueKey('memory-open'),
                      minSize: const Size.square(
                        DomovoyDimensions.minimumTarget,
                      ),
                      alignment: Alignment.center,
                      tooltip: 'Память',
                      tone: _panelOpen || widget.memorySelected
                          ? DomovoyButtonTone.selected
                          : DomovoyButtonTone.quiet,
                      onPressed: () => _openMemory(layout),
                      child: const Icon(
                        Icons.psychology_outlined,
                        size: DomovoyDimensions.iconMedium,
                      ),
                    ),
                  if (widget.onDeleteChat != null) ...[
                    const SizedBox(width: DomovoyDimensions.space1),
                    DomovoyQuietButton(
                      key: const ValueKey('chat-delete'),
                      minSize: const Size.square(
                        DomovoyDimensions.minimumTarget,
                      ),
                      alignment: Alignment.center,
                      focusNode: widget.deleteFocusNode,
                      onPressed: widget.onDeleteChat,
                      tooltip: 'Удалить текущий чат',
                      child: Icon(
                        Icons.delete_outline_rounded,
                        size: DomovoyDimensions.iconMedium,
                        color: tokens.danger,
                      ),
                    ),
                  ] else
                    const SizedBox.shrink(key: ValueKey('chat-delete')),
                ],
              ),
            ),
          ),
          Expanded(
            child: layout.isDesktop && widget.memoryPanel != null && _panelOpen
                ? Row(
                    key: const ValueKey('workspace-memory-pane'),
                    children: [
                      Expanded(child: _bodyArea(context, layout, tokens)),
                      VerticalDivider(
                        width: DomovoyDimensions.hairline,
                        thickness: DomovoyDimensions.hairline,
                        color: tokens.border,
                      ),
                      SizedBox(
                        width: DomovoyDimensions.memoryPanelWidth,
                        child: widget.memoryPanel,
                      ),
                    ],
                  )
                : _bodyArea(context, layout, tokens),
          ),
        ],
      ),
    );
  }

  Widget _bodyArea(
    BuildContext context,
    WorkspaceLayoutSpec layout,
    DomovoyThemeTokens tokens,
  ) {
    return Stack(
      children: [
        Positioned.fill(child: widget.body),
        if (widget.showComposer)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              color: tokens.canvas,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  layout.contentInsets.left,
                  DomovoyDimensions.space4,
                  layout.contentInsets.right,
                  DomovoyDimensions.space5 +
                      MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: layout.composerMaxWidth,
                    ),
                    child: widget.composer,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openMemory(WorkspaceLayoutSpec layout) {
    if (layout.isDesktop && widget.memoryPanel != null) {
      setState(() => _panelOpen = !_panelOpen);
      return;
    }
    widget.onOpenMemory?.call();
  }

  void _newChat() {
    if (widget.enabled) widget.onNewChat?.call();
  }

  void _openSettings() => widget.onOpenSettings?.call();

  void _openFolder(BuildContext buttonContext) {
    final name = widget.projectName ?? 'Без проекта';
    final root = widget.projectRoot ?? '—';
    unawaitedFolder(buttonContext, name, root);
  }

  void unawaitedFolder(BuildContext buttonContext, String name, String root) {
    showDomovoyAnchoredPopover<void>(
      context: buttonContext,
      width: DomovoyDimensions.folderPopoverWidth,
      builder: (popoverContext) {
        final tokens = popoverContext.domovoyTheme;
        return DomovoyPopoverCard(
          padding: DomovoyDimensions.panelInsets,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: Theme.of(popoverContext).textTheme.titleSmall),
              const SizedBox(height: DomovoyDimensions.space2),
              Text(
                root,
                style: Theme.of(popoverContext).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: DomovoyDimensions.space3),
              Text(
                'Доступ к файлам определяется разрешениями проекта.',
                style: Theme.of(
                  popoverContext,
                ).textTheme.labelSmall?.copyWith(color: tokens.textMuted),
              ),
            ],
          ),
        );
      },
    );
  }

  void _dismissTopmost() {
    if (_panelOpen && widget.memoryPanel != null) {
      setState(() => _panelOpen = false);
      return;
    }
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.maybePop(context);
    }
  }
}
