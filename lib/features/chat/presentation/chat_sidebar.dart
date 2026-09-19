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

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return DomovoySurface(
      role: DomovoySurfaceRole.sidebar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: DomovoyDimensions.panelInsets,
              child: Row(
                children: [
                  Icon(
                    Icons.blur_on_rounded,
                    color: tokens.accent,
                    size: DomovoyDimensions.iconLarge,
                  ),
                  const SizedBox(width: DomovoyDimensions.space3),
                  Expanded(
                    child: Text(
                      'Domovoy',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: DomovoyDimensions.listInsets,
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FilledButton.tonalIcon(
                  key: const ValueKey('chat-new'),
                  autofocus: true,
                  focusNode: newChatFocusNode,
                  onPressed: enabled ? onNewChat : null,
                  icon: const Icon(Icons.add_rounded),
                  label: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Новый чат'),
                  ),
                ),
              ),
            ),
            ?aboveChats,
            Padding(
              padding: DomovoyDimensions.listInsets,
              child: Text(
                'НЕДАВНИЕ',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('chat-list'),
                padding: DomovoyDimensions.listInsets,
                itemCount: chats.length,
                itemBuilder: (context, index) {
                  final chat = chats[index];
                  final selected = chat.id == selectedId;
                  return FocusTraversalOrder(
                    order: NumericFocusOrder(index + 2),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        bottom: DomovoyDimensions.space2,
                      ),
                      child: Semantics(
                        selected: selected,
                        button: true,
                        label: chat.title ?? 'Новый чат',
                        child: Material(
                          color: selected
                              ? tokens.selectedSurface
                              : tokens.sidebar,
                          borderRadius: BorderRadius.circular(
                            DomovoyDimensions.radiusMedium,
                          ),
                          child: InkWell(
                            key: ValueKey('chat-row:${chat.id.value}'),
                            borderRadius: BorderRadius.circular(
                              DomovoyDimensions.radiusMedium,
                            ),
                            onTap: enabled && onSelectChat != null
                                ? () => onSelectChat!(chat.id)
                                : null,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: DomovoyDimensions.minimumTarget,
                              ),
                              child: Padding(
                                padding: DomovoyDimensions.controlInsets,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      chat.title ?? 'Новый чат',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(
                                      height: DomovoyDimensions.space1,
                                    ),
                                    Text(
                                      modelLabelFor(chat),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (issueCount > 0)
              Padding(
                padding: DomovoyDimensions.listInsets,
                child: DomovoyStatusChip(
                  key: const ValueKey('catalog-warning'),
                  label: 'Некоторые чаты недоступны',
                  tone: DomovoyStatusTone.warning,
                  icon: Icons.warning_amber_rounded,
                ),
              ),
            Divider(height: DomovoyDimensions.hairline, color: tokens.divider),
            Padding(
              padding: DomovoyDimensions.listInsets,
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(100),
                child: TextButton.icon(
                  key: const ValueKey('open-settings'),
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Настройки API-ключа'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
