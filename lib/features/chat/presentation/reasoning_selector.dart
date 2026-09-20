import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';

final class ChatReasoningChoice {
  const ChatReasoningChoice({
    required this.mode,
    required this.effort,
    required this.label,
    this.detail,
  });

  final ReasoningMode mode;
  final ReasoningEffort effort;
  final String label;
  final String? detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatReasoningChoice &&
          other.mode == mode &&
          other.effort == effort;

  @override
  int get hashCode => Object.hash(mode, effort);
}

List<ChatReasoningChoice> reasoningChoicesFor(LlmModel model) {
  final capabilities = model.capabilities;
  final choices = <ChatReasoningChoice>[];
  if (capabilities.canDisableReasoning) {
    choices.add(
      ChatReasoningChoice(
        mode: ReasoningMode.disabled,
        effort: ReasoningEffort.modelDefault,
        label: capabilities.supportsReasoning
            ? 'Без рассуждений'
            : 'По умолчанию',
        detail: 'Быстрый ответ',
      ),
    );
  }
  if (capabilities.supportsReasoning) {
    choices.add(
      const ChatReasoningChoice(
        mode: ReasoningMode.enabled,
        effort: ReasoningEffort.modelDefault,
        label: 'Авто',
        detail: 'Решение модели',
      ),
    );
    for (final effort in capabilities.selectableEfforts) {
      choices.add(
        ChatReasoningChoice(
          mode: ReasoningMode.enabled,
          effort: effort,
          label: _effortLabel(effort),
          detail: _effortDetail(effort),
        ),
      );
    }
  }
  return List<ChatReasoningChoice>.unmodifiable(choices);
}

class ChatReasoningSelector extends StatefulWidget {
  const ChatReasoningSelector({
    required this.model,
    required this.selection,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final LlmModel model;
  final AgentSessionSelection selection;
  final ValueChanged<ChatReasoningChoice> onSelected;
  final bool enabled;

  @override
  State<ChatReasoningSelector> createState() => _ChatReasoningSelectorState();
}

class _ChatReasoningSelectorState extends State<ChatReasoningSelector> {
  final _focusNode = FocusNode(debugLabel: 'reasoning-selector');

  List<ChatReasoningChoice> get _choices => reasoningChoicesFor(widget.model);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_choices.isEmpty) return const SizedBox.shrink();
    final selected = _choices.firstWhere(
      (choice) =>
          choice.mode == widget.selection.reasoningMode &&
          choice.effort == widget.selection.reasoningEffort,
      orElse: () => _choices.first,
    );
    final media = MediaQuery.of(context);
    final layout = resolveWorkspaceLayout(
      media.size,
      media.textScaler.scale(1),
    );
    return DomovoyQuietButton(
      key: const ValueKey('reasoning-selector'),
      focusNode: _focusNode,
      minSize: const Size(0, DomovoyDimensions.minimumTarget),
      onPressed: widget.enabled && _choices.length > 1
          ? () => layout.isDesktop ? _openPopover() : unawaited(_openSheet())
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(selected.label),
          const SizedBox(width: DomovoyDimensions.space2),
          const DomovoyIcon(DomovoyIconKind.chevron, size: 12),
        ],
      ),
    );
  }

  Future<void> _openPopover() async {
    await showDomovoyAnchoredPopover<void>(
      context: context,
      width: DomovoyDimensions.reasoningPopoverWidth,
      builder: (popoverContext) {
        return DomovoyPopoverCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: DomovoyDimensions.controlInsets,
                child: Text(
                  'Рассуждение',
                  style: Theme.of(popoverContext).textTheme.labelSmall,
                ),
              ),
              for (final choice in _choices)
                DomovoyQuietButton(
                  key: ValueKey(
                    'reasoning-option:${choice.mode.name}:${choice.effort.name}',
                  ),
                  expand: true,
                  tone: _isSelected(choice)
                      ? DomovoyButtonTone.accent
                      : DomovoyButtonTone.quiet,
                  onPressed: () {
                    Navigator.maybePop(popoverContext);
                    _select(choice);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(choice.label),
                      if (choice.detail != null)
                        Text(
                          choice.detail!,
                          style: Theme.of(popoverContext).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (mounted) _focusNode.requestFocus();
  }

  Future<void> _openSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.domovoyTheme.elevatedSurface,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const ValueKey('reasoning-selector-sheet'),
          shrinkWrap: true,
          padding: DomovoyDimensions.compactPageInsets,
          children: [
            for (final choice in _choices)
              DomovoyQuietButton(
                key: ValueKey(
                  'reasoning-option:${choice.mode.name}:${choice.effort.name}',
                ),
                expand: true,
                tone: _isSelected(choice)
                    ? DomovoyButtonTone.accent
                    : DomovoyButtonTone.quiet,
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _select(choice);
                },
                child: Text(choice.label),
              ),
          ],
        ),
      ),
    );
    if (mounted) _focusNode.requestFocus();
  }

  bool _isSelected(ChatReasoningChoice choice) =>
      choice.mode == widget.selection.reasoningMode &&
      choice.effort == widget.selection.reasoningEffort;

  void _select(ChatReasoningChoice choice) {
    widget.onSelected(choice);
    scheduleMicrotask(_focusNode.requestFocus);
  }
}

String _effortLabel(ReasoningEffort effort) => switch (effort) {
  ReasoningEffort.modelDefault => 'Авто',
  ReasoningEffort.low => 'Низкое',
  ReasoningEffort.medium => 'Среднее',
  ReasoningEffort.high => 'Высокое',
  ReasoningEffort.max => 'Максимальное',
};

String _effortDetail(ReasoningEffort effort) => switch (effort) {
  ReasoningEffort.modelDefault => 'Решение модели',
  ReasoningEffort.low => 'Быстрый разбор',
  ReasoningEffort.medium => 'Баланс глубины и скорости',
  ReasoningEffort.high => 'Больше времени на задачу',
  ReasoningEffort.max => 'Максимальная глубина',
};
