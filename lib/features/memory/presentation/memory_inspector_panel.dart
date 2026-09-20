import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/memory/memory.dart';
import '../../../design_system/design_system.dart';
import '../application/memory_inspector_controller.dart';
import '../application/memory_inspector_state.dart';

/// Adaptive memory inspector content. It is embedded as a desktop/tablet pane
/// and shown inside a bottom sheet on phones.
class MemoryInspectorPanel extends StatelessWidget {
  const MemoryInspectorPanel({
    required this.controller,
    this.onClose,
    super.key,
  });

  final MemoryInspectorController controller;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final content = Focus(
      child: DomovoySurface(
        key: const ValueKey('memory-panel'),
        role: DomovoySurfaceRole.surface,
        border: true,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => _InspectorBody(
            controller: controller,
            state: controller.state,
            onClose: onClose,
          ),
        ),
      ),
    );
    final close = onClose;
    if (close == null) {
      return content;
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: content,
    );
  }
}

class _InspectorBody extends StatelessWidget {
  const _InspectorBody({
    required this.controller,
    required this.state,
    required this.onClose,
  });

  final MemoryInspectorController controller;
  final MemoryInspectorState state;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Padding(
      padding: DomovoyDimensions.panelInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, tokens),
          if (state.busy) ...[
            const SizedBox(height: DomovoyDimensions.space2),
            const LinearProgressIndicator(
              key: ValueKey('memory-busy'),
              minHeight: DomovoyDimensions.progressStroke,
            ),
          ],
          const SizedBox(height: DomovoyDimensions.space3),
          _toggles(context),
          const SizedBox(height: DomovoyDimensions.space2),
          _extraction(context),
          const SizedBox(height: DomovoyDimensions.space3),
          _layerSelector(context),
          const SizedBox(height: DomovoyDimensions.space3),
          if (state.error != null) ...[
            Text(
              state.error!,
              key: const ValueKey('memory-error'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.danger),
            ),
            const SizedBox(height: DomovoyDimensions.space2),
          ],
          Expanded(child: _layerList(context, tokens)),
          const SizedBox(height: DomovoyDimensions.space2),
          _trace(context, tokens),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, DomovoyThemeTokens tokens) {
    return Row(
      children: [
        Expanded(
          child: Text('Память', style: Theme.of(context).textTheme.titleSmall),
        ),
        if (onClose != null)
          DomovoyQuietButton(
            key: const ValueKey('memory-close'),
            minSize: const Size.square(DomovoyDimensions.minimumTarget),
            alignment: Alignment.center,
            tooltip: 'Закрыть',
            onPressed: onClose,
            child: const Icon(
              Icons.close_rounded,
              size: DomovoyDimensions.iconMedium,
            ),
          ),
      ],
    );
  }

  Widget _toggles(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _switchRow(
          context,
          key: const ValueKey('memory-toggle-working'),
          label: 'Рабочая память проекта',
          value: state.includeWorking,
          onChanged: controller.setIncludeWorking,
        ),
        _switchRow(
          context,
          key: const ValueKey('memory-toggle-longterm'),
          label: 'Долговременная память',
          value: state.includeLongTerm,
          onChanged: controller.setIncludeLongTerm,
        ),
      ],
    );
  }

  Widget _switchRow(
    BuildContext context, {
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Switch(key: key, value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _extraction(BuildContext context) {
    final tokens = context.domovoyTheme;
    final status = state.extractionStatus;
    return Row(
      children: [
        Expanded(
          child: Text(
            status == null
                ? 'Извлечение: ожидание'
                : 'Извлечение: ${_statusLabel(status)}',
            key: const ValueKey('memory-extraction-status'),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
          ),
        ),
        DomovoyQuietButton(
          key: const ValueKey('memory-analyze'),
          onPressed: controller.canAnalyze && !state.analysisBusy
              ? () => unawaited(controller.analyzeNow())
              : null,
          child: const Text('Анализировать'),
        ),
      ],
    );
  }

  Widget _layerSelector(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Wrap(
      spacing: DomovoyDimensions.space2,
      runSpacing: DomovoyDimensions.space2,
      children: <Widget>[
        for (final layer in MemoryLayerView.values)
          DomovoyQuietButton(
            key: ValueKey('memory-layer-${layer.name}'),
            tone: state.selectedLayer == layer
                ? DomovoyButtonTone.accent
                : DomovoyButtonTone.quiet,
            onPressed: () => controller.selectLayer(layer),
            child: Text(
              _layerLabel(layer),
              style: TextStyle(
                color: state.selectedLayer == layer
                    ? tokens.accentInk
                    : tokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _layerList(BuildContext context, DomovoyThemeTokens tokens) {
    if (state.isEmpty) {
      return Center(
        child: Text(
          'Здесь пока нет записей.',
          key: const ValueKey('memory-empty'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
        ),
      );
    }
    return ListView(
      key: const ValueKey('memory-list'),
      padding: EdgeInsets.zero,
      children: switch (state.selectedLayer) {
        MemoryLayerView.shortTerm => <Widget>[
          for (var index = 0; index < state.shortTerm.length; index += 1)
            _shortTermRow(context, tokens, state.shortTerm[index], index),
        ],
        MemoryLayerView.working => <Widget>[
          for (final entry in state.working) _entryRow(context, tokens, entry),
        ],
        MemoryLayerView.longTerm => <Widget>[
          for (final entry in state.longTerm) _entryRow(context, tokens, entry),
        ],
        MemoryLayerView.candidates => <Widget>[
          for (final candidate in state.candidates)
            _candidateRow(context, tokens, candidate),
        ],
      },
    );
  }

  Widget _shortTermRow(
    BuildContext context,
    DomovoyThemeTokens tokens,
    MemorySourcePreview preview,
    int index,
  ) {
    return Padding(
      key: ValueKey('memory-source-$index'),
      padding: const EdgeInsets.symmetric(vertical: DomovoyDimensions.space2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preview.role == MemoryTranscriptRole.user
                ? 'Пользователь'
                : 'Ассистент',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tokens.textMuted),
          ),
          Text(
            preview.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _entryRow(
    BuildContext context,
    DomovoyThemeTokens tokens,
    MemoryEntry entry,
  ) {
    return Padding(
      key: ValueKey('memory-entry-${entry.id.value}'),
      padding: const EdgeInsets.symmetric(vertical: DomovoyDimensions.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_kindLabel(entry.kind)} · rev ${entry.revision}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: tokens.textMuted),
                ),
                Text(
                  entry.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('memory-edit-entry-${entry.id.value}'),
            tooltip: 'Изменить',
            onPressed: state.busy
                ? null
                : () => unawaited(_editEntry(context, entry)),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            key: ValueKey('memory-forget-${entry.id.value}'),
            tooltip: 'Забыть',
            onPressed: state.busy
                ? null
                : () => unawaited(controller.forgetEntry(entry)),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  Widget _candidateRow(
    BuildContext context,
    DomovoyThemeTokens tokens,
    MemoryCandidate candidate,
  ) {
    return Padding(
      key: ValueKey('memory-candidate-${candidate.id.value}'),
      padding: const EdgeInsets.symmetric(vertical: DomovoyDimensions.space2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_operationLabel(candidate.operation)} · ${_layerKindLabel(candidate.layer, candidate.kind)}',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tokens.textMuted),
          ),
          Text(
            candidate.content ?? '',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: DomovoyDimensions.space2),
          Wrap(
            spacing: DomovoyDimensions.space2,
            children: [
              DomovoyQuietButton(
                key: ValueKey('memory-confirm-${candidate.id.value}'),
                tone: DomovoyButtonTone.accent,
                onPressed: state.busy
                    ? null
                    : () => unawaited(controller.confirmCandidate(candidate)),
                child: const Text('Подтвердить'),
              ),
              DomovoyQuietButton(
                key: ValueKey('memory-edit-${candidate.id.value}'),
                onPressed: state.busy
                    ? null
                    : () => unawaited(_editCandidate(context, candidate)),
                child: const Text('Изменить'),
              ),
              DomovoyQuietButton(
                key: ValueKey('memory-reject-${candidate.id.value}'),
                onPressed: state.busy
                    ? null
                    : () => unawaited(controller.rejectCandidate(candidate)),
                child: const Text('Отклонить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _trace(BuildContext context, DomovoyThemeTokens tokens) {
    final trace = state.trace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                key: const ValueKey('memory-trace-toggle'),
                onPressed: () =>
                    controller.setTraceVisible(!state.traceVisible),
                child: Text(
                  state.traceVisible ? 'Скрыть трассу' : 'Показать трассу',
                ),
              ),
            ),
            if (trace != null)
              Text(
                '${trace.renderedCharacters}/${trace.budgetCharacters}'
                '${trace.truncated ? ' · обрезано' : ''}',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: tokens.textMuted),
              ),
          ],
        ),
        if (state.traceVisible && trace != null)
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: DomovoyDimensions.memoryTraceMaxHeight,
            ),
            child: ListView(
              key: const ValueKey('memory-trace-list'),
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (final record in trace.records)
                  Text(
                    '${record.included ? '✓' : '×'} ${record.reason.name} '
                    '${record.entryId.value}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: record.included
                          ? tokens.textSecondary
                          : tokens.textMuted,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _editCandidate(
    BuildContext context,
    MemoryCandidate candidate,
  ) async {
    final result = await showDialog<_MemoryEdit>(
      context: context,
      builder: (context) => _MemoryEditDialog(
        title: 'Изменить кандидата',
        content: candidate.content ?? '',
        kind: candidate.kind,
        layer: candidate.layer,
      ),
    );
    if (result == null) {
      return;
    }
    await controller.editCandidate(
      candidate,
      content: result.content,
      kind: result.kind,
    );
  }

  Future<void> _editEntry(BuildContext context, MemoryEntry entry) async {
    final result = await showDialog<_MemoryEdit>(
      context: context,
      builder: (context) => _MemoryEditDialog(
        title: 'Изменить память',
        content: entry.content,
        kind: entry.kind,
        layer: entry.layer,
      ),
    );
    if (result == null) return;
    await controller.editEntry(
      entry,
      content: result.content,
      kind: result.kind,
    );
  }
}

final class _MemoryEdit {
  const _MemoryEdit({required this.content, required this.kind});

  final String content;
  final MemoryKind kind;
}

class _MemoryEditDialog extends StatefulWidget {
  const _MemoryEditDialog({
    required this.title,
    required this.content,
    required this.kind,
    required this.layer,
  });

  final String title;
  final String content;
  final MemoryKind kind;
  final MemoryLayer layer;

  @override
  State<_MemoryEditDialog> createState() => _MemoryEditDialogState();
}

class _MemoryEditDialogState extends State<_MemoryEditDialog> {
  late final TextEditingController _content = TextEditingController(
    text: widget.content,
  );
  late MemoryKind _kind = widget.kind;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('memory-edit-field'),
            controller: _content,
            minLines: 2,
            maxLines: 5,
          ),
          const SizedBox(height: DomovoyDimensions.space3),
          DropdownButtonFormField<MemoryKind>(
            key: const ValueKey('memory-edit-kind'),
            initialValue: _kind,
            items: <DropdownMenuItem<MemoryKind>>[
              for (final kind in MemoryKind.values)
                if (kind.allowsLayer(widget.layer))
                  DropdownMenuItem<MemoryKind>(
                    value: kind,
                    child: Text(_kindLabel(kind)),
                  ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('memory-edit-cancel'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey('memory-edit-save'),
          onPressed: () => Navigator.of(
            context,
          ).maybePop(_MemoryEdit(content: _content.text, kind: _kind)),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

String _layerLabel(MemoryLayerView layer) => switch (layer) {
  MemoryLayerView.shortTerm => 'Краткосрочная',
  MemoryLayerView.working => 'Рабочая',
  MemoryLayerView.longTerm => 'Долговременная',
  MemoryLayerView.candidates => 'Кандидаты',
};

String _statusLabel(MemoryExtractionStatus status) => switch (status) {
  MemoryExtractionStatus.skipped => 'ожидание',
  MemoryExtractionStatus.busy => 'занято',
  MemoryExtractionStatus.extracted => 'готово',
  MemoryExtractionStatus.failed => 'ошибка',
};

String _operationLabel(MemoryProposalOperation operation) =>
    switch (operation) {
      MemoryProposalOperation.create => 'Создание',
      MemoryProposalOperation.update => 'Обновление',
      MemoryProposalOperation.noop => 'Без изменений',
    };

String _kindLabel(MemoryKind kind) => switch (kind) {
  MemoryKind.requirement => 'Требование',
  MemoryKind.decision => 'Решение',
  MemoryKind.fact => 'Факт',
  MemoryKind.preference => 'Предпочтение',
  MemoryKind.procedure => 'Процедура',
  MemoryKind.profile => 'Профиль',
  MemoryKind.policy => 'Политика',
};

String _layerKindLabel(MemoryLayer layer, MemoryKind kind) =>
    '${layer == MemoryLayer.working ? 'проект' : 'глобально'} · ${_kindLabel(kind)}';
