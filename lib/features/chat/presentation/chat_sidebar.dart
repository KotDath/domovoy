import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../design_system/design_system.dart';

class ChatSidebar extends StatelessWidget {
  const ChatSidebar({
    required this.chats,
    required this.selectedId,
    required this.modelLabelFor,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onOpenSettings,
    required this.enabled,
    this.issueCount = 0,
    this.newChatFocusNode,
    this.aboveChats,
    this.onOpenUsage,
    this.themeMode,
    this.onThemeModeChanged,
    this.usageSelected = false,
    this.providersSelected = false,
    super.key,
  });

  final List<AgentSessionSummary> chats;
  final AgentSessionId? selectedId;
  final String Function(AgentSessionSummary summary) modelLabelFor;
  final VoidCallback? onNewChat;
  final ValueChanged<AgentSessionId>? onSelectChat;
  final VoidCallback? onOpenSettings;
  final bool enabled;
  final int issueCount;
  final FocusNode? newChatFocusNode;
  final Widget? aboveChats;
  final VoidCallback? onOpenUsage;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final bool usageSelected;
  final bool providersSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final nested = aboveChats != null;
    return DomovoySurface(
      role: DomovoySurfaceRole.sidebar,
      child: SafeArea(
        child: Padding(
          padding: DomovoyDimensions.sidebarInsets,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DomovoyDimensions.space3,
                  DomovoyDimensions.zero,
                  DomovoyDimensions.space3,
                  DomovoyDimensions.space5,
                ),
                child: Text(
                  'domovoy',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: DomovoyQuietButton(
                  key: const ValueKey('chat-new'),
                  focusNode: newChatFocusNode,
                  onPressed: enabled ? onNewChat : null,
                  expand: true,
                  child: const Row(
                    children: [
                      DomovoyIcon(DomovoyIconKind.compose),
                      SizedBox(width: DomovoyDimensions.space3),
                      Expanded(
                        child: Text(
                          'Новый чат',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (nested) ...[
                Expanded(child: SingleChildScrollView(child: aboveChats)),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DomovoyDimensions.space3,
                    DomovoyDimensions.space4,
                    DomovoyDimensions.space3,
                    DomovoyDimensions.space2,
                  ),
                  child: Text(
                    'Чаты',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    key: const ValueKey('chat-list'),
                    itemCount: chats.length,
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      final selected = chat.id == selectedId;
                      return FocusTraversalOrder(
                        order: NumericFocusOrder(index + 2),
                        child: Padding(
                          padding: const EdgeInsets.only(
                            bottom: DomovoyDimensions.space1,
                          ),
                          child: Semantics(
                            selected: selected,
                            button: true,
                            label:
                                '${chat.title ?? 'Новый чат'}, ${modelLabelFor(chat)}',
                            child: DomovoyQuietButton(
                              key: ValueKey('chat-row:${chat.id.value}'),
                              tone: selected
                                  ? DomovoyButtonTone.selected
                                  : DomovoyButtonTone.quiet,
                              onPressed: enabled && onSelectChat != null
                                  ? () => onSelectChat!(chat.id)
                                  : null,
                              padding: DomovoyDimensions.controlInsets,
                              child: Text(
                                chat.title ?? 'Новый чат',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      fontSize: DomovoyDimensions.chatRowSize,
                                      color: selected
                                          ? tokens.textPrimary
                                          : tokens.textSecondary,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (issueCount > 0)
                Padding(
                  padding: DomovoyDimensions.listInsets,
                  child: DomovoyStatusChip(
                    key: const ValueKey('catalog-warning'),
                    label: 'Некоторые чаты недоступны',
                    tone: DomovoyStatusTone.warning,
                  ),
                ),
              const SizedBox(height: DomovoyDimensions.space6),
              FocusTraversalOrder(
                order: const NumericFocusOrder(98),
                child: DomovoyQuietButton(
                  key: const ValueKey('open-usage'),
                  tone: usageSelected
                      ? DomovoyButtonTone.selected
                      : DomovoyButtonTone.quiet,
                  onPressed: onOpenUsage,
                  expand: true,
                  child: const Row(
                    children: [
                      DomovoyIcon(DomovoyIconKind.usage),
                      SizedBox(width: DomovoyDimensions.space3),
                      Expanded(
                        child: Text(
                          'Использование',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(100),
                child: DomovoyQuietButton(
                  key: const ValueKey('open-settings'),
                  tone: providersSelected
                      ? DomovoyButtonTone.selected
                      : DomovoyButtonTone.quiet,
                  onPressed: onOpenSettings,
                  expand: true,
                  child: const Row(
                    children: [
                      DomovoyIcon(DomovoyIconKind.providers),
                      SizedBox(width: DomovoyDimensions.space3),
                      Expanded(
                        child: Text(
                          'Провайдеры',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (onThemeModeChanged != null) ...[
                const SizedBox(height: DomovoyDimensions.space3),
                Row(
                  children: [
                    Text('Тема', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: DomovoyDimensions.space3),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<ThemeMode>(
                          isExpanded: true,
                          key: const ValueKey('theme-mode'),
                          value: themeMode ?? ThemeMode.system,
                          isDense: true,
                          borderRadius: BorderRadius.circular(
                            DomovoyDimensions.radiusSmall,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: ThemeMode.system,
                              child: Text('Системная'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.dark,
                              child: Text('Тёмная'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.light,
                              child: Text('Светлая'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) onThemeModeChanged!(value);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
