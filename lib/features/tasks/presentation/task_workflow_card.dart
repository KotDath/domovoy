import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/tasks/tasks.dart';
import '../../../design_system/design_system.dart';
import '../application/tasks.dart';

class TaskWorkflowCard extends StatelessWidget {
  const TaskWorkflowCard({
    required this.controller,
    this.awaitingGoal = false,
    this.notice,
    super.key,
  });

  final TaskWorkflowController controller;
  final bool awaitingGoal;
  final String? notice;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      final snapshot = state.snapshot;
      if (snapshot == null && !awaitingGoal && notice == null) {
        return const SizedBox.shrink();
      }
      return Card(
        key: const ValueKey('task-workflow-card'),
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: snapshot == null
                ? _EmptyTaskNotice(awaitingGoal: awaitingGoal, notice: notice)
                : _TaskDetails(
                    controller: controller,
                    snapshot: snapshot,
                    invoking: state.isInvokingAgent,
                    failure: state.failure,
                    notice: notice,
                  ),
          ),
        ),
      );
    },
  );
}

class _EmptyTaskNotice extends StatelessWidget {
  const _EmptyTaskNotice({required this.awaitingGoal, this.notice});

  final bool awaitingGoal;
  final String? notice;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.account_tree_outlined),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          awaitingGoal
              ? 'Режим плана включён. Отправьте цель следующим сообщением.'
              : notice ?? 'Активной задачи нет.',
          key: const ValueKey('task-empty-notice'),
        ),
      ),
    ],
  );
}

class _TaskDetails extends StatelessWidget {
  const _TaskDetails({
    required this.controller,
    required this.snapshot,
    required this.invoking,
    this.failure,
    this.notice,
  });

  final TaskWorkflowController controller;
  final TaskSnapshot snapshot;
  final bool invoking;
  final TaskWorkflowFailure? failure;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentNodeId == null
        ? null
        : snapshot.plan?.nodes
              .where((node) => node.id == snapshot.currentNodeId)
              .firstOrNull;
    final progress = snapshot.totalNodeCount == 0
        ? 0.0
        : snapshot.completedNodeCount / snapshot.totalNodeCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              invoking ? Icons.sync_rounded : Icons.account_tree_outlined,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Задача · ${_phaseLabel(snapshot.phase)}',
                key: const ValueKey('task-phase'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('r${snapshot.revision}'),
          ],
        ),
        const SizedBox(height: 8),
        Text(snapshot.goal ?? 'Цель ещё не задана.'),
        if (snapshot.totalNodeCount > 0) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: const ValueKey('task-progress'),
            value: progress,
          ),
          const SizedBox(height: 4),
          Text(
            '${snapshot.completedNodeCount}/${snapshot.totalNodeCount} узлов'
            '${current == null ? '' : ' · ${current.title}'}',
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Ожидается: ${_actionLabel(snapshot.expectedAction)}',
          key: const ValueKey('task-expected-action'),
        ),
        if (snapshot.plan != null && !snapshot.planApproved)
          ExpansionTile(
            key: const ValueKey('task-plan'),
            tilePadding: EdgeInsets.zero,
            title: Text('План (${snapshot.plan!.nodes.length})'),
            children: [
              for (final node in snapshot.plan!.nodes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(node.title),
                  subtitle: Text(node.acceptanceCriteria),
                ),
            ],
          ),
        if (snapshot.phase == TaskPhase.done &&
            snapshot.finalOutput?.trim().isNotEmpty == true)
          ExpansionTile(
            key: const ValueKey('task-final-output'),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            title: const Text('Результат'),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(snapshot.finalOutput!),
              ),
            ],
          ),
        if (failure != null || snapshot.failureCode != null) ...[
          const SizedBox(height: 8),
          Text(
            failure == null
                ? '[${snapshot.failureCode}] ${snapshot.failureMessage ?? ''}'
                : '[${failure!.code}] ${failure!.message}',
            key: const ValueKey('task-failure'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ] else if (notice != null) ...[
          const SizedBox(height: 8),
          Text(notice!, key: const ValueKey('task-notice')),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: _actions(context)),
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    final terminal = snapshot.cancelled || snapshot.phase == TaskPhase.done;
    return <Widget>[
      if (!snapshot.planApproved && snapshot.plan != null && !snapshot.paused)
        FilledButton(
          key: const ValueKey('task-approve'),
          onPressed: invoking
              ? null
              : () => unawaited(controller.approvePlan()),
          child: const Text('Утвердить план'),
        ),
      if (!terminal && !snapshot.paused)
        OutlinedButton(
          key: const ValueKey('task-pause'),
          onPressed: () => unawaited(controller.pause()),
          child: const Text('Пауза'),
        ),
      if (!terminal && snapshot.paused)
        FilledButton.tonal(
          key: const ValueKey('task-resume'),
          onPressed: () => unawaited(controller.resume()),
          child: const Text('Продолжить'),
        ),
      if (!terminal)
        OutlinedButton(
          key: const ValueKey('task-replan'),
          onPressed: invoking
              ? null
              : () => unawaited(_openReplanDialog(context)),
          child: const Text('Новый план'),
        ),
      if (!terminal)
        OutlinedButton(
          key: const ValueKey('task-invariants'),
          onPressed: invoking
              ? null
              : () => unawaited(_openInvariantEditor(context)),
          child: const Text('Инварианты'),
        ),
      if (!terminal && snapshot.phase == TaskPhase.planning)
        TextButton(
          key: const ValueKey('task-diagnose-execution'),
          onPressed: () =>
              controller.diagnose(TaskTransitionKind.executionStarted),
          child: const Text('Проверить execution'),
        ),
      if (!terminal && snapshot.phase == TaskPhase.execution)
        TextButton(
          key: const ValueKey('task-diagnose-done'),
          onPressed: () =>
              controller.diagnose(TaskTransitionKind.finalValidated),
          child: const Text('Проверить done'),
        ),
      if (!terminal)
        TextButton(
          key: const ValueKey('task-cancel'),
          onPressed: () => unawaited(controller.cancel()),
          child: const Text('Отменить'),
        ),
    ];
  }

  Future<void> _openInvariantEditor(BuildContext context) async {
    late final List<TaskInvariantRule> initial;
    try {
      initial = await controller.loadTaskRules();
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось загрузить инварианты.')),
      );
      return;
    }
    if (!context.mounted) return;
    final rules = await showDialog<List<TaskInvariantRule>>(
      context: context,
      builder: (context) => _TaskInvariantEditor(initial: initial),
    );
    if (rules == null || !context.mounted) return;
    try {
      final result = await controller.saveTaskRules(rules);
      if (!context.mounted || result.isAccepted) return;
      final failure = result.failure!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось сохранить инварианты: '
            '[${failure.code}] ${failure.message}',
          ),
        ),
      );
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить инварианты.')),
      );
    }
  }

  Future<void> _openReplanDialog(BuildContext context) async {
    final goal = await showDialog<String>(
      context: context,
      builder: (context) => _TaskReplanDialog(initialGoal: snapshot.goal ?? ''),
    );
    if (goal != null) await controller.replan(goal: goal);
  }
}

class _TaskReplanDialog extends StatefulWidget {
  const _TaskReplanDialog({required this.initialGoal});

  final String initialGoal;

  @override
  State<_TaskReplanDialog> createState() => _TaskReplanDialogState();
}

class _TaskReplanDialogState extends State<_TaskReplanDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialGoal,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новый план'),
    content: TextField(
      key: const ValueKey('task-replan-goal'),
      controller: _text,
      autofocus: true,
      minLines: 2,
      maxLines: 5,
      decoration: const InputDecoration(labelText: 'Уточнённая цель'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const ValueKey('task-replan-submit'),
        onPressed: () {
          final value = _text.text.trim();
          if (value.isNotEmpty) Navigator.pop(context, value);
        },
        child: const Text('Перестроить'),
      ),
    ],
  );
}

class _TaskInvariantEditor extends StatefulWidget {
  const _TaskInvariantEditor({required this.initial});

  final List<TaskInvariantRule> initial;

  @override
  State<_TaskInvariantEditor> createState() => _TaskInvariantEditorState();
}

class _TaskInvariantEditorState extends State<_TaskInvariantEditor> {
  late final List<TaskInvariantRule> _rules = List.of(widget.initial);
  final _description = TextEditingController();
  final _terms = TextEditingController();

  @override
  void dispose() {
    _description.dispose();
    _terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Инварианты задачи'),
    content: SizedBox(
      width: DomovoyDimensions.settingsDialogWidth,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < _rules.length; index++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_rules[index].description),
                subtitle: Text(_rules[index].terms.join(', ')),
                trailing: IconButton(
                  tooltip: 'Удалить инвариант',
                  onPressed: () => setState(() => _rules.removeAt(index)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            TextField(
              key: const ValueKey('task-invariant-description'),
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Описание',
                hintText: 'Не использовать другой стек',
              ),
            ),
            TextField(
              key: const ValueKey('task-invariant-terms'),
              controller: _terms,
              decoration: const InputDecoration(
                labelText: 'Запрещённые слова через запятую',
                hintText: 'React, Redux',
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('task-invariant-add'),
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Добавить'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const ValueKey('task-invariant-save'),
        onPressed: () => Navigator.pop(context, _rules),
        child: const Text('Сохранить'),
      ),
    ],
  );

  void _add() {
    final terms = _terms.text
        .split(',')
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty)
        .toList();
    final description = _description.text.trim();
    if (description.isEmpty || terms.isEmpty) return;
    setState(() {
      _rules.add(
        TaskInvariantRule(
          id: 'task-rule-${DateTime.now().microsecondsSinceEpoch}',
          scope: TaskInvariantScope.task,
          category: TaskInvariantCategory.custom,
          description: description,
          checker: TaskInvariantChecker.forbiddenTerms,
          terms: terms,
        ),
      );
      _description.clear();
      _terms.clear();
    });
  }
}

String _phaseLabel(TaskPhase phase) => switch (phase) {
  TaskPhase.planning => 'планирование',
  TaskPhase.execution => 'выполнение',
  TaskPhase.validation => 'валидация',
  TaskPhase.done => 'готово',
};

String _actionLabel(TaskExpectedAction action) => switch (action) {
  TaskExpectedAction.captureGoal => 'цель',
  TaskExpectedAction.preparePlan => 'подготовка плана',
  TaskExpectedAction.approvePlan => 'утверждение плана',
  TaskExpectedAction.runNode => 'выполнение шага',
  TaskExpectedAction.verifyNode => 'проверка шага',
  TaskExpectedAction.repairNode => 'исправление шага',
  TaskExpectedAction.composeFinal => 'сборка финала',
  TaskExpectedAction.validateFinal => 'проверка финала',
  TaskExpectedAction.resume => 'продолжение пользователем',
  TaskExpectedAction.resolveFailure => 'устранение ошибки',
  TaskExpectedAction.none => 'нет',
};
