import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';
import '../../../infrastructure/llm/discovery/provider_model_catalog.dart';

class ChatModelSelector extends StatefulWidget {
  const ChatModelSelector({
    required this.groups,
    required this.selection,
    required this.onSelected,
    this.enabled = true,
    this.catalog,
    this.onRefreshModels,
    this.onManageProviders,
    super.key,
  });

  final List<LlmProviderGroup> groups;
  final AgentSessionSelection selection;
  final ValueChanged<AgentSessionSelection> onSelected;
  final bool enabled;
  final ProviderCatalogSnapshot? catalog;
  final Future<ProviderCatalogSnapshot?> Function()? onRefreshModels;
  final VoidCallback? onManageProviders;

  @override
  State<ChatModelSelector> createState() => _ChatModelSelectorState();
}

class _ChatModelSelectorState extends State<ChatModelSelector> {
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
    return DomovoyQuietButton(
      key: const ValueKey('model-selector'),
      focusNode: _focusNode,
      minSize: const Size(0, DomovoyDimensions.minimumTarget),
      onPressed: widget.enabled && widget.groups.isNotEmpty
          ? () => layout.isDesktop ? _openPopover() : unawaited(_openSheet())
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: DomovoyDimensions.space2),
          const DomovoyIcon(DomovoyIconKind.chevron, size: 12),
        ],
      ),
    );
  }

  Future<void> _openPopover() async {
    var activeProvider =
        modelForSelection(widget.groups, widget.selection)?.providerId.value ??
        widget.groups.first.providerId.value;
    var query = '';
    await showDomovoyAnchoredPopover<void>(
      context: context,
      width: DomovoyDimensions.modelsPopoverWidth,
      builder: (popoverContext) {
        return StatefulBuilder(
          builder: (popoverContext, setPopoverState) {
            final tokens = popoverContext.domovoyTheme;
            final group = widget.groups.firstWhere(
              (entry) => entry.providerId.value == activeProvider,
              orElse: () => widget.groups.first,
            );
            final models = [
              for (final model in group.models)
                if (query.isEmpty ||
                    '${group.displayName} ${model.name} ${model.id.value}'
                        .toLowerCase()
                        .contains(query))
                  model,
            ];
            return LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 360.0;
                return Material(
                  color: DomovoyPrimitiveTokens.transparent,
                  child: SizedBox(
                    height: height,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: DomovoyDimensions.providerMenuWidth,
                          child: DomovoyPopoverCard(
                            child: ListView(
                              children: [
                                for (final entry in widget.groups)
                                  DomovoyQuietButton(
                                    key: ValueKey(
                                      'model-provider:${entry.providerId.value}',
                                    ),
                                    expand: true,
                                    tone:
                                        entry.providerId.value == activeProvider
                                        ? DomovoyButtonTone.accent
                                        : DomovoyButtonTone.quiet,
                                    onPressed: () => setPopoverState(
                                      () => activeProvider =
                                          entry.providerId.value,
                                    ),
                                    child: Text(entry.displayName),
                                  ),
                                Divider(color: tokens.border),
                                DomovoyQuietButton(
                                  expand: true,
                                  tone: DomovoyButtonTone.muted,
                                  onPressed: () {
                                    Navigator.maybePop(popoverContext);
                                    widget.onManageProviders?.call();
                                  },
                                  child: const Text('Настроить провайдеров'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: DomovoyDimensions.space2),
                        Expanded(
                          child: DomovoyPopoverCard(
                            child: Column(
                              children: [
                                TextField(
                                  key: const ValueKey('model-search'),
                                  decoration: const InputDecoration(
                                    hintText: 'Поиск',
                                    isDense: true,
                                  ),
                                  onChanged: (value) => setPopoverState(
                                    () => query = value.trim().toLowerCase(),
                                  ),
                                ),
                                const SizedBox(
                                  height: DomovoyDimensions.space2,
                                ),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      for (final model in models)
                                        DomovoyQuietButton(
                                          key: ValueKey(
                                            'model-option:${model.providerId.value}:${model.id.value}',
                                          ),
                                          expand: true,
                                          tone:
                                              model.ref ==
                                                  widget.selection.model
                                              ? DomovoyButtonTone.accent
                                              : DomovoyButtonTone.quiet,
                                          onPressed: () {
                                            Navigator.maybePop(popoverContext);
                                            _select(model);
                                          },
                                          child: Text(model.name),
                                        ),
                                    ],
                                  ),
                                ),
                                if (widget.catalog != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: DomovoyDimensions.space2,
                                    ),
                                    child: Text(
                                      'Каталог: ${widget.catalog!.models.length} · ${widget.catalog!.source}'
                                      '${widget.catalog!.stale ? ' · частично/офлайн' : ''}',
                                      style: Theme.of(popoverContext)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: tokens.textMuted),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
    if (mounted) _focusNode.requestFocus();
  }

  Future<void> _openSheet() async {
    var query = '';
    final search = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.domovoyTheme.elevatedSurface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final entries = <(LlmProviderGroup, LlmModel)>[
            for (final group in widget.groups)
              for (final model in group.models)
                if (query.isEmpty ||
                    '${group.displayName} ${model.name} ${model.id.value}'
                        .toLowerCase()
                        .contains(query))
                  (group, model),
          ];
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.75,
              child: Column(
                children: [
                  Padding(
                    padding: DomovoyDimensions.compactPageInsets,
                    child: TextField(
                      key: const ValueKey('model-search'),
                      controller: search,
                      decoration: const InputDecoration(
                        labelText: 'Поиск модели или провайдера',
                      ),
                      onChanged: (value) => setSheetState(
                        () => query = value.trim().toLowerCase(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: const ValueKey('model-selector-sheet'),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final (group, model) = entries[index];
                        return DomovoyQuietButton(
                          key: ValueKey(
                            'model-option:${model.providerId.value}:${model.id.value}',
                          ),
                          expand: true,
                          tone: model.ref == widget.selection.model
                              ? DomovoyButtonTone.accent
                              : DomovoyButtonTone.quiet,
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _select(model);
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(model.name),
                              Text(
                                group.displayName,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    if (mounted) _focusNode.requestFocus();
  }

  void _select(LlmModel model) {
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
