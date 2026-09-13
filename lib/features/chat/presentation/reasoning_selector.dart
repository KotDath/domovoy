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
  });

  final ReasoningMode mode;
  final ReasoningEffort effort;
  final String label;

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
      ),
    );
  }
  if (capabilities.supportsReasoning) {
    choices.add(
      const ChatReasoningChoice(
        mode: ReasoningMode.enabled,
        effort: ReasoningEffort.modelDefault,
        label: 'Авто',
      ),
    );
    for (final effort in capabilities.selectableEfforts) {
      choices.add(
        ChatReasoningChoice(
          mode: ReasoningMode.enabled,
          effort: effort,
          label: _effortLabel(effort),
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
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'reasoning-selector');

  List<ChatReasoningChoice> get _choices => reasoningChoicesFor(widget.model);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    final trigger = _trigger(
      selected.label,
      layout.isDesktop ? _toggleMenu : _openSheet,
    );
    if (!layout.isDesktop) return trigger;
    return MenuAnchor(
      controller: _menuController,
      menuChildren: [for (final choice in _choices) _desktopRow(choice)],
      builder: (context, controller, child) => trigger,
    );
  }

  Widget _trigger(String label, VoidCallback activate) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: DomovoyDimensions.minimumTarget,
    ),
    child: OutlinedButton.icon(
      key: const ValueKey('reasoning-selector'),
      focusNode: _focusNode,
      onPressed: widget.enabled && _choices.length > 1 ? activate : null,
      icon: const Icon(Icons.psychology_outlined),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  Widget _desktopRow(ChatReasoningChoice choice) => MenuItemButton(
    key: ValueKey('reasoning-option:${choice.mode.name}:${choice.effort.name}'),
    leadingIcon: Icon(
      _isSelected(choice)
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
    ),
    onPressed: () => _select(choice),
    child: Text(choice.label),
  );

  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
    }
  }

  Future<void> _openSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const ValueKey('reasoning-selector-sheet'),
          shrinkWrap: true,
          padding: DomovoyDimensions.compactPageInsets,
          children: [
            for (final choice in _choices)
              ListTile(
                key: ValueKey(
                  'reasoning-option:${choice.mode.name}:${choice.effort.name}',
                ),
                leading: Icon(
                  _isSelected(choice)
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                ),
                title: Text(choice.label),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _select(choice);
                },
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
    _menuController.close();
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
