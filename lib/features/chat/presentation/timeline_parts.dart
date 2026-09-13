import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/chat_timeline_projector.dart';

class ChatTimelinePart extends StatelessWidget {
  const ChatTimelinePart({
    required this.item,
    required this.reasoningExpanded,
    required this.onReasoningToggle,
    this.onOpenSettings,
    super.key,
  });

  final ChatTimelineItem item;
  final bool reasoningExpanded;
  final VoidCallback onReasoningToggle;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => switch (item) {
    ChatUserItem value => _MessageBubble(
      itemKey: value.key,
      text: value.text,
      user: true,
    ),
    ChatAssistantItem value => _MessageBubble(
      itemKey: value.key,
      text: value.text,
      partial: value.isPartial,
    ),
    ChatReasoningItem value => _ReasoningPart(
      item: value,
      expanded: reasoningExpanded,
      onToggle: onReasoningToggle,
    ),
    ChatToolItem value => _ToolPart(item: value),
    ChatCompactionItem value => _CompactionPart(item: value),
    ChatErrorItem value => _ErrorPart(
      item: value,
      onOpenSettings: onOpenSettings,
    ),
    ChatUnsupportedPartItem value => _UnsupportedPart(item: value),
  };
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.itemKey,
    required this.text,
    this.user = false,
    this.partial = false,
  });

  final String itemKey;
  final String text;
  final bool user;
  final bool partial;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Align(
      key: ValueKey(itemKey),
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DomovoyDimensions.messageMaxWidth,
        ),
        child: DomovoySurface(
          role: user
              ? DomovoySurfaceRole.selected
              : DomovoySurfaceRole.elevated,
          border: true,
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMessage),
          padding: DomovoyDimensions.panelInsets,
          child: Semantics(
            label: user
                ? 'Сообщение пользователя'
                : partial
                ? 'Частичный ответ ассистента'
                : 'Ответ ассистента',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(text),
                if (partial) ...[
                  const SizedBox(height: DomovoyDimensions.space3),
                  Text(
                    'Формируется…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasoningPart extends StatelessWidget {
  const _ReasoningPart({
    required this.item,
    required this.expanded,
    required this.onToggle,
  });

  final ChatReasoningItem item;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return DomovoySurface(
      key: ValueKey(item.key),
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label: expanded ? 'Скрыть рассуждение' : 'Показать рассуждение',
            child: InkWell(
              key: ValueKey('${item.key}:toggle'),
              borderRadius: BorderRadius.circular(
                DomovoyDimensions.radiusMedium,
              ),
              onTap: onToggle,
              child: Padding(
                padding: DomovoyDimensions.panelInsets,
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      color: tokens.accent,
                      size: DomovoyDimensions.iconMedium,
                    ),
                    const SizedBox(width: DomovoyDimensions.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Рассуждение'),
                          if (!expanded)
                            Text(
                              item.isPartial ? 'Формируется, скрыто' : 'Скрыто',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: tokens.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: DomovoyDimensions.panelInsets,
              child: SelectableText(item.text),
            ),
        ],
      ),
    );
  }
}

class _ToolPart extends StatefulWidget {
  const _ToolPart({required this.item});

  final ChatToolItem item;

  @override
  State<_ToolPart> createState() => _ToolPartState();
}

class _ToolPartState extends State<_ToolPart> {
  final _focusNode = FocusNode(debugLabel: 'tool-disclosure');
  var _expanded = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tone = switch (item.status) {
      ChatToolStatus.succeeded => DomovoyStatusTone.success,
      ChatToolStatus.failed => DomovoyStatusTone.danger,
      ChatToolStatus.awaitingPermission => DomovoyStatusTone.warning,
      ChatToolStatus.assembled ||
      ChatToolStatus.running => DomovoyStatusTone.neutral,
    };
    return DomovoySurface(
      key: ValueKey(item.key),
      role: DomovoySurfaceRole.elevated,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: _expanded
                ? 'Скрыть содержимое инструмента ${item.name}'
                : 'Показать содержимое инструмента ${item.name}',
            child: InkWell(
              key: ValueKey('${item.key}:disclosure'),
              focusNode: _focusNode,
              borderRadius: BorderRadius.circular(
                DomovoyDimensions.radiusLarge,
              ),
              onTap: () {
                _focusNode.requestFocus();
                setState(() => _expanded = !_expanded);
              },
              child: Padding(
                padding: DomovoyDimensions.panelInsets,
                child: Row(
                  children: [
                    const Icon(Icons.terminal_rounded),
                    const SizedBox(width: DomovoyDimensions.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.name),
                          if (item.progress != null)
                            Text(
                              item.progress!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    DomovoyStatusChip(
                      label: _toolStatusLabel(item.status),
                      tone: tone,
                    ),
                    const SizedBox(width: DomovoyDimensions.space3),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: DomovoyDimensions.panelInsets,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (item.displayArguments.isNotEmpty)
                    _ToolContent(
                      label: 'Аргументы',
                      content: item.displayArguments,
                    ),
                  if (item.displayResult != null) ...[
                    const SizedBox(height: DomovoyDimensions.space4),
                    _ToolContent(
                      label: 'Результат',
                      content: item.displayResult!,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolContent extends StatelessWidget {
  const _ToolContent({required this.label, required this.content});

  final String label;
  final String content;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: DomovoyDimensions.space2),
      DomovoySurface(
        role: DomovoySurfaceRole.canvas,
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusSmall),
        padding: DomovoyDimensions.controlInsets,
        child: SelectableText(
          content,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}

class _CompactionPart extends StatelessWidget {
  const _CompactionPart({required this.item});

  final ChatCompactionItem item;

  @override
  Widget build(BuildContext context) => DomovoySurface(
    key: ValueKey(item.key),
    role: DomovoySurfaceRole.surface,
    border: true,
    borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
    padding: DomovoyDimensions.panelInsets,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.compress_rounded),
        const SizedBox(width: DomovoyDimensions.space3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${item.reasonLabel}: ${_compactionLabel(item.status)}'),
              Text(
                '${item.strategyLabel} · ${item.beforeEstimate}'
                '${item.afterEstimate == null ? '' : ' → ${item.afterEstimate}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ErrorPart extends StatelessWidget {
  const _ErrorPart({required this.item, this.onOpenSettings});

  final ChatErrorItem item;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Semantics(
      key: ValueKey(item.key),
      label: 'Статус ответа: ${item.message}',
      child: Container(
        padding: DomovoyDimensions.panelInsets,
        decoration: BoxDecoration(
          color: tokens.dangerSurface,
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
          border: Border.all(color: tokens.danger),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: tokens.danger),
            const SizedBox(width: DomovoyDimensions.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(item.message),
                  if (item.offersSettings && onOpenSettings != null)
                    TextButton(
                      key: const ValueKey('timeline-open-settings'),
                      onPressed: onOpenSettings,
                      child: const Text('Открыть настройки'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedPart extends StatelessWidget {
  const _UnsupportedPart({required this.item});

  final ChatUnsupportedPartItem item;

  @override
  Widget build(BuildContext context) => DomovoySurface(
    key: ValueKey(item.key),
    role: DomovoySurfaceRole.surface,
    border: true,
    borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
    padding: DomovoyDimensions.panelInsets,
    child: SelectableText(item.label),
  );
}

String _toolStatusLabel(ChatToolStatus status) => switch (status) {
  ChatToolStatus.assembled => 'Подготовлен',
  ChatToolStatus.awaitingPermission => 'Ожидает',
  ChatToolStatus.running => 'Выполняется',
  ChatToolStatus.succeeded => 'Готово',
  ChatToolStatus.failed => 'Ошибка',
};

String _compactionLabel(ChatCompactionStatus status) => switch (status) {
  ChatCompactionStatus.running => 'выполняется',
  ChatCompactionStatus.succeeded => 'готово',
  ChatCompactionStatus.unchanged => 'не требуется',
  ChatCompactionStatus.failed => 'ошибка',
  ChatCompactionStatus.cancelled => 'остановлено',
};
