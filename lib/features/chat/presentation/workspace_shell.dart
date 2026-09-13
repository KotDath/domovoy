import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/agents/agents.dart';
import '../../../design_system/design_system.dart';
import '../application/chat_token_presenter.dart';
import 'chat_sidebar.dart';
import 'token_details.dart';

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

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

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
                      const VerticalDivider(
                        width: DomovoyDimensions.hairline,
                        thickness: DomovoyDimensions.hairline,
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
    final media = MediaQuery.of(context);
    final compactHeader = media.size.width < DomovoyDimensions.compactWidth;
    final highTextScale =
        media.textScaler.scale(1) >= DomovoyDimensions.highTextScale;
    return SafeArea(
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DomovoyDimensions.headerHeight,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  bottom: BorderSide(
                    color: tokens.divider,
                    width: DomovoyDimensions.hairline,
                  ),
                ),
              ),
              child: Padding(
                padding: DomovoyDimensions.listInsets,
                child: Row(
                  children: [
                    if (!layout.isDesktop) ...[
                      DomovoyIconAction(
                        key: const ValueKey('chat-list-open'),
                        icon: Icons.menu_rounded,
                        label: 'Открыть список чатов',
                        onPressed: () =>
                            _scaffoldKey.currentState?.openDrawer(),
                      ),
                      const SizedBox(width: DomovoyDimensions.space2),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (widget.selectedId != null && !highTextScale)
                            Text(
                              widget.modelLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ChatTokenSummary(
                        projection: widget.tokenProjection,
                        onPressed: widget.onOpenTokens,
                        compact: compactHeader,
                      ),
                    ),
                    const SizedBox(width: DomovoyDimensions.space2),
                    DomovoyIconAction(
                      key: const ValueKey('chat-delete'),
                      icon: Icons.more_horiz_rounded,
                      label: 'Удалить выбранный чат',
                      focusNode: widget.deleteFocusNode,
                      onPressed: widget.selectedId == null
                          ? null
                          : widget.onDeleteChat,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: layout.timelineMaxWidth),
                child: widget.body,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              layout.contentInsets.left,
              DomovoyDimensions.space3,
              layout.contentInsets.right,
              DomovoyDimensions.space5 +
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.composerMaxWidth),
              child: widget.composer,
            ),
          ),
        ],
      ),
    );
  }

  void _newChat() {
    if (widget.enabled) widget.onNewChat?.call();
  }

  void _openSettings() => widget.onOpenSettings?.call();

  void _dismissTopmost() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.maybePop(context);
    }
  }
}
