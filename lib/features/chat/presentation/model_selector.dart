import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';

class ChatModelSelector extends StatefulWidget {
  const ChatModelSelector({
    required this.groups,
    required this.selection,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<LlmProviderGroup> groups;
  final AgentSessionSelection selection;
  final ValueChanged<AgentSessionSelection> onSelected;
  final bool enabled;

  @override
  State<ChatModelSelector> createState() => _ChatModelSelectorState();
}

class _ChatModelSelectorState extends State<ChatModelSelector> {
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'model-selector');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = modelForSelection(widget.groups, widget.selection);
    final label = model?.name ?? 'Модель недоступна';
    final media = MediaQuery.of(context);
    final layout = resolveWorkspaceLayout(
      media.size,
      media.textScaler.scale(1),
    );
    final trigger = _trigger(
      label,
      layout.isDesktop ? _toggleMenu : _openSheet,
    );
    if (!layout.isDesktop) return trigger;
    return MenuAnchor(
      controller: _menuController,
      menuChildren: _desktopRows(context),
      builder: (context, controller, child) => trigger,
    );
  }

  Widget _trigger(String label, VoidCallback activate) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: DomovoyDimensions.minimumTarget,
    ),
    child: OutlinedButton.icon(
      key: const ValueKey('model-selector'),
      focusNode: _focusNode,
      onPressed: widget.enabled && widget.groups.isNotEmpty ? activate : null,
      icon: const Icon(Icons.auto_awesome_outlined),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
    }
  }

  List<Widget> _desktopRows(BuildContext context) => <Widget>[
    for (final group in widget.groups) ...[
      Padding(
        key: ValueKey('model-provider:${group.providerId.value}'),
        padding: DomovoyDimensions.controlInsets,
        child: Text(
          group.displayName,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: context.domovoyTheme.textSecondary,
          ),
        ),
      ),
      for (final model in group.models)
        MenuItemButton(
          key: ValueKey(
            'model-option:${model.providerId.value}:${model.id.value}',
          ),
          leadingIcon: Icon(
            model.ref == widget.selection.model
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
          ),
          onPressed: () => _select(model),
          child: Text(model.name),
        ),
    ],
  ];

  Future<void> _openSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const ValueKey('model-selector-sheet'),
          shrinkWrap: true,
          padding: DomovoyDimensions.compactPageInsets,
          children: [
            for (final group in widget.groups) ...[
              Padding(
                key: ValueKey('model-provider:${group.providerId.value}'),
                padding: DomovoyDimensions.controlInsets,
                child: Text(
                  group.displayName,
                  style: Theme.of(sheetContext).textTheme.labelLarge,
                ),
              ),
              for (final model in group.models)
                ListTile(
                  key: ValueKey(
                    'model-option:${model.providerId.value}:${model.id.value}',
                  ),
                  leading: Icon(
                    model.ref == widget.selection.model
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                  ),
                  title: Text(model.name),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _select(model);
                  },
                ),
            ],
          ],
        ),
      ),
    );
    if (mounted) _focusNode.requestFocus();
  }

  void _select(LlmModel model) {
    _menuController.close();
    widget.onSelected(selectionForTargetModel(widget.selection, model));
    scheduleMicrotask(_focusNode.requestFocus);
  }
}

LlmModel? modelForSelection(
  List<LlmProviderGroup> groups,
  AgentSessionSelection selection,
) {
  for (final group in groups) {
    for (final model in group.models) {
      if (model.ref == selection.model) return model;
    }
  }
  return null;
}

AgentSessionSelection selectionForTargetModel(
  AgentSessionSelection current,
  LlmModel target,
) {
  if (_isReasoningPairValid(
    target.capabilities,
    current.reasoningMode,
    current.reasoningEffort,
  )) {
    return AgentSessionSelection(
      model: target.ref,
      reasoningMode: current.reasoningMode,
      reasoningEffort: current.reasoningEffort,
    );
  }
  final mode =
      target.capabilities.reasoning == ModelReasoningCapability.unsupported
      ? ReasoningMode.disabled
      : ReasoningMode.enabled;
  return AgentSessionSelection(
    model: target.ref,
    reasoningMode: mode,
    reasoningEffort: ReasoningEffort.modelDefault,
  );
}

bool _isReasoningPairValid(
  ModelCapabilities capabilities,
  ReasoningMode mode,
  ReasoningEffort effort,
) {
  switch (capabilities.reasoning) {
    case ModelReasoningCapability.unsupported:
      return mode == ReasoningMode.disabled &&
          effort == ReasoningEffort.modelDefault;
    case ModelReasoningCapability.required:
      return mode == ReasoningMode.enabled &&
          (!effort.isExplicit ||
              capabilities.selectableEfforts.contains(effort));
    case ModelReasoningCapability.optional:
      if (mode == ReasoningMode.disabled) {
        return effort == ReasoningEffort.modelDefault;
      }
      return !effort.isExplicit ||
          capabilities.selectableEfforts.contains(effort);
  }
}
