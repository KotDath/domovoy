import 'package:flutter/material.dart';

import '../../../core/automation/automation.dart';
import '../../../core/llm/identifiers.dart';
import '../application/task_editor_controller.dart';
import '../application/task_editor_state.dart';
import '../application/tasks_controller.dart';
import '../domain/task_editor_draft.dart';

/// Foreground task list with history, result and trace. Controllers are supplied
/// by the app composition so this page never creates a second scheduler.
class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.controller,
    required this.editor,
    this.availableModels = const <ModelRef>[],
    super.key,
  });
  final TasksController controller;
  final TaskEditorController editor;
  final List<ModelRef> availableModels;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool _showDetail = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.initialize();
  }

  @override
  void didUpdateWidget(covariant TasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.initialize();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _edit([AutomationTask? task]) async {
    if (task == null) {
      widget.editor.startNew();
    } else {
      widget.editor.editTask(task);
    }
    await widget.editor.loadChats();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskEditorPage(
          controller: widget.editor,
          availableModels: widget.availableModels,
        ),
      ),
    );
    if (mounted) await widget.controller.refresh();
  }

  Future<void> _delete(AutomationTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить задачу?'),
        content: Text(
          '«${task.name}» больше не будет запускаться. История запусков останется на этом устройстве.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.controller.deleteTask(task.taskId);
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() => _showDetail = false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message ?? 'Не удалось удалить задачу.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected = state.selectedTask;
    final list = ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Задачи запускаются, пока приложение открыто и активно. После возвращения может выполниться один пропущенный запуск; остальные останутся в истории как пропущенные.',
          ),
        ),
        if (!state.foreground)
          const ListTile(
            leading: Icon(Icons.pause_circle),
            title: Text('Приложение в фоне — запуски ждут возвращения'),
          ),
        if (state.error != null)
          ListTile(
            title: Text(
              state.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        for (final task in state.tasks)
          ListTile(
            key: ValueKey('task:${task.taskId.value}'),
            selected: state.selectedTaskId == task.taskId,
            title: Text(task.name),
            subtitle: Text(
              '${_taskStatus(task.state)} · ${task.nextDueAt == null ? 'без следующего запуска' : 'далее ${task.nextDueAt!.toLocal()}'}',
            ),
            trailing: IconButton(
              tooltip: 'Изменить',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(task),
            ),
            onTap: () {
              widget.controller.selectTask(task.taskId);
              setState(() => _showDetail = true);
            },
          ),
        if (state.tasks.isEmpty && !state.isLoading)
          const ListTile(
            title: Text('Задач пока нет. Создайте первую задачу.'),
          ),
      ],
    );
    final detail = selected == null
        ? const Center(child: Text('Выберите задачу.'))
        : _TaskDetail(
            controller: widget.controller,
            task: selected,
            onEdit: () => _edit(selected),
            onDelete: () => _delete(selected),
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Задачи'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: widget.controller.refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Новая задача',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : wide
          ? Row(
              children: [
                SizedBox(width: 360, child: list),
                const VerticalDivider(width: 1),
                Expanded(child: detail),
              ],
            )
          : selected == null || !_showDetail
          ? list
          : Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showDetail = false),
                    icon: const Icon(Icons.list),
                    label: const Text('Список задач'),
                  ),
                ),
                Expanded(child: detail),
              ],
            ),
    );
  }
}

class _TaskDetail extends StatelessWidget {
  const _TaskDetail({
    required this.controller,
    required this.task,
    required this.onEdit,
    required this.onDelete,
  });
  final TasksController controller;
  final AutomationTask task;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final run = state.selectedRun ?? state.lastRun;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(task.name, style: Theme.of(context).textTheme.headlineSmall),
        Text(_taskStatus(task.state)),
        if (task.nextDueAt != null)
          Text('Следующий запуск: ${task.nextDueAt!.toLocal()}'),
        if (task.schedule is CronSchedule)
          Text(
            'Расписание: ${(task.schedule as CronSchedule).expression} · ${(task.schedule as CronSchedule).timeZoneId}',
          ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: state.busy
                  ? null
                  : () => controller.runNow(task.taskId),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Запустить сейчас'),
            ),
            if (task.state == AutomationTaskState.active ||
                task.state == AutomationTaskState.paused)
              OutlinedButton(
                onPressed: state.busy
                    ? null
                    : () => controller.setPaused(
                        task.taskId,
                        task.state == AutomationTaskState.active,
                      ),
                child: Text(
                  task.state == AutomationTaskState.active
                      ? 'Пауза'
                      : 'Возобновить',
                ),
              ),
            if (task.state == AutomationTaskState.proposed)
              OutlinedButton(
                onPressed: () => controller.confirmTask(task.taskId),
                child: const Text('Подтвердить задачу'),
              ),
            TextButton(onPressed: onEdit, child: const Text('Изменить')),
            TextButton.icon(
              onPressed: state.busy ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Удалить'),
            ),
          ],
        ),
        const Divider(),
        Text(
          'История запусков',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final entry in state.runs)
          ListTile(
            key: ValueKey('run:${entry.runId.value}'),
            selected: run?.runId == entry.runId,
            title: Text(
              '${_runStatus(entry.status)} · ${entry.scheduledAt.toLocal()}',
            ),
            subtitle: Text(
              entry.trigger == AutomationRunTrigger.catchUp
                  ? 'Догоняющий запуск после открытия · пропущено: ${entry.aggregatedSkippedCount}'
                  : entry.trigger == AutomationRunTrigger.manual
                  ? 'Запущено вручную'
                  : 'По расписанию',
            ),
            onTap: () => controller.selectRun(entry.runId),
          ),
        if (run != null) ...[
          const Divider(),
          Text(
            'Результат · ${_runStatus(run.status)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (run.resultText != null) SelectableText(run.resultText!),
          if (run.error != null) Text(run.error!.message),
          if (run.deliveryTarget?.kind == AutomationDeliveryKind.chat &&
              (run.status == AutomationRunStatus.succeeded ||
                  run.status == AutomationRunStatus.failed))
            ListTile(
              title: Text(
                run.delivery?.delivered == true
                    ? 'Карточка доставлена в чат'
                    : 'Карточка не доставлена',
              ),
              subtitle: Text(
                run.delivery?.error ??
                    run.delivery?.reference ??
                    'Ожидает доставки',
              ),
              trailing: run.delivery?.delivered == true
                  ? null
                  : TextButton(
                      onPressed: () => controller.retryDelivery(run.runId),
                      child: const Text('Повторить'),
                    ),
            ),
          Text(
            'Трасса инструментов',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (run.trace.isEmpty) const Text('Вызовов инструментов не было.'),
          for (final trace in run.trace)
            ListTile(
              title: Text(trace.name),
              subtitle: Text(trace.detail ?? ''),
              trailing: Text(trace.status.name),
            ),
        ],
      ],
    );
  }
}

String _taskStatus(AutomationTaskState state) => switch (state) {
  AutomationTaskState.proposed => 'Ждёт подтверждения',
  AutomationTaskState.active => 'Активна',
  AutomationTaskState.paused => 'На паузе',
  AutomationTaskState.completed => 'Завершена',
  AutomationTaskState.deleted => 'Удалена',
};

String _runStatus(AutomationRunStatus status) => switch (status) {
  AutomationRunStatus.running => 'Выполняется',
  AutomationRunStatus.succeeded => 'Готово',
  AutomationRunStatus.failed => 'Ошибка',
  AutomationRunStatus.skipped => 'Пропущено',
  AutomationRunStatus.interrupted => 'Прервано',
};

/// Full-screen editor keeps every field usable on a narrow phone.
class TaskEditorPage extends StatefulWidget {
  const TaskEditorPage({
    required this.controller,
    this.availableModels = const <ModelRef>[],
    super.key,
  });
  final TaskEditorController controller;
  final List<ModelRef> availableModels;
  @override
  State<TaskEditorPage> createState() => _TaskEditorPageState();
}

class _TaskEditorPageState extends State<TaskEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _cron;
  late final TextEditingController _zone;
  late final TextEditingController _provider;
  late final TextEditingController _model;

  @override
  void initState() {
    super.initState();
    final draft = widget.controller.state.draft;
    _name = TextEditingController(text: draft.name);
    _prompt = TextEditingController(text: draft.prompt);
    _cron = TextEditingController(text: draft.cronExpression);
    _zone = TextEditingController(text: draft.timeZoneId);
    _provider = TextEditingController(
      text: draft.model?.providerId.value ?? '',
    );
    _model = TextEditingController(text: draft.model?.modelId.value ?? '');
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    for (final controller in [
      _name,
      _prompt,
      _cron,
      _zone,
      _provider,
      _model,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setModel() {
    if (_provider.text.trim().isEmpty || _model.text.trim().isEmpty) {
      widget.controller.setModel(null);
      return;
    }
    try {
      widget.controller.setModel(
        ModelRef(
          providerId: ProviderId(_provider.text.trim()),
          modelId: ModelId(_model.text.trim()),
        ),
      );
    } on Object {
      widget.controller.setModel(null);
    }
  }

  Future<void> _pickOneShot() async {
    final initial =
        widget.controller.state.draft.oneShotLocal ??
        DateTime.now().add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    widget.controller.setOneShotLocal(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final draft = state.draft;
    String? error(TaskEditorField field) => state.errors[field];
    return Scaffold(
      appBar: AppBar(
        title: Text(state.isEditing ? 'Изменить задачу' : 'Новая задача'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Задача выполняется, пока приложение открыто и активно. Пропущенные интервалы не запускаются все сразу.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Название',
                  errorText: error(TaskEditorField.name),
                ),
                onChanged: widget.controller.setName,
              ),
              TextField(
                controller: _prompt,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'Промпт',
                  errorText: error(TaskEditorField.prompt),
                ),
                onChanged: widget.controller.setPrompt,
              ),
              const SizedBox(height: 12),
              SegmentedButton<TaskScheduleKind>(
                segments: const [
                  ButtonSegment(
                    value: TaskScheduleKind.cron,
                    label: Text('Повторять'),
                  ),
                  ButtonSegment(
                    value: TaskScheduleKind.oneShot,
                    label: Text('Один раз'),
                  ),
                ],
                selected: {draft.scheduleKind},
                onSelectionChanged: (value) =>
                    widget.controller.setScheduleKind(value.first),
              ),
              if (draft.scheduleKind == TaskScheduleKind.cron)
                TextField(
                  controller: _cron,
                  decoration: InputDecoration(
                    labelText: 'Cron · 5 полей',
                    helperText: 'Например, */5 * * * * — каждые 5 минут',
                    errorText: error(TaskEditorField.schedule),
                  ),
                  onChanged: widget.controller.setCronExpression,
                )
              else
                ListTile(
                  title: Text(
                    draft.oneShotLocal == null
                        ? 'Дата и время не выбраны'
                        : draft.oneShotLocal.toString(),
                  ),
                  subtitle: Text(
                    error(TaskEditorField.schedule) ??
                        'Местное время выбранного часового пояса',
                  ),
                  trailing: const Icon(Icons.calendar_month),
                  onTap: _pickOneShot,
                ),
              TextField(
                controller: _zone,
                decoration: const InputDecoration(
                  labelText: 'Часовой пояс · IANA',
                  helperText: 'Например, Europe/Moscow',
                ),
                onChanged: widget.controller.setTimeZone,
              ),
              if (state.previewError != null)
                Text(
                  state.previewError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              for (var i = 0; i < state.occurrences.length; i++)
                Text(
                  'Запуск ${i + 1}: ${_scheduledMoment(widget.controller.service, draft.timeZoneId, state.occurrences[i])}',
                ),
              const Divider(),
              Text('Модель', style: Theme.of(context).textTheme.titleMedium),
              if (widget.availableModels.isNotEmpty)
                DropdownButtonFormField<ModelRef>(
                  isExpanded: true,
                  initialValue: widget.availableModels.contains(draft.model)
                      ? draft.model
                      : null,
                  decoration: InputDecoration(
                    labelText: 'Выберите модель',
                    errorText: error(TaskEditorField.model),
                  ),
                  items: [
                    for (final model in widget.availableModels)
                      DropdownMenuItem(
                        value: model,
                        child: Text(
                          '${model.providerId.value} · ${model.modelId.value}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: widget.controller.setModel,
                )
              else ...[
                TextField(
                  controller: _provider,
                  decoration: const InputDecoration(labelText: 'Провайдер'),
                  onChanged: (_) => _setModel(),
                ),
                TextField(
                  controller: _model,
                  decoration: InputDecoration(
                    labelText: 'ID модели',
                    errorText: error(TaskEditorField.model),
                  ),
                  onChanged: (_) => _setModel(),
                ),
              ],
              const Divider(),
              Text(
                'Разрешённые MCP инструменты',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                error(TaskEditorField.tools) ??
                    'Задача сможет вызывать только отмеченные инструменты.',
              ),
              for (final connection in state.toolConnections) ...[
                ListTile(
                  title: Text(connection.alias),
                  subtitle: Text(
                    connection.unavailableReason ??
                        connection.connectionId.value,
                  ),
                ),
                for (final tool in connection.tools)
                  CheckboxListTile(
                    key: ValueKey('tool:${tool.toolId}'),
                    title: Text(tool.title ?? tool.originalName),
                    subtitle: Text(
                      '${connection.connectionId.value}.${tool.originalName}\n${tool.description ?? ''}',
                    ),
                    value: draft.allowedToolIds.contains(tool.toolId),
                    onChanged: (value) => widget.controller.toggleTool(
                      tool.toolId,
                      value ?? false,
                    ),
                  ),
              ],
              OutlinedButton(
                onPressed: () {
                  widget.controller.applyArxivPreset();
                  final updated = widget.controller.state.draft;
                  _name.text = updated.name;
                  _prompt.text = updated.prompt;
                },
                child: const Text(
                  'Пресет: подборка arXiv → сводка → библиотека',
                ),
              ),
              if (state.presetNotice != null) Text(state.presetNotice!),
              const Divider(),
              Text(
                'Доставка результата',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SwitchListTile(
                title: const Text('Также карточка в чате'),
                value: draft.delivery.kind == AutomationDeliveryKind.chat,
                onChanged: (enabled) {
                  if (enabled) {
                    widget.controller.setDeliveryChat(
                      state.chatOptions.firstOrNull?.id.value ?? '',
                    );
                  } else {
                    widget.controller.setDeliveryTasks();
                  }
                },
              ),
              if (draft.delivery.kind == AutomationDeliveryKind.chat)
                DropdownButtonFormField<String>(
                  initialValue:
                      state.chatOptions.any(
                        (chat) => chat.id.value == draft.delivery.chatId,
                      )
                      ? draft.delivery.chatId
                      : null,
                  decoration: InputDecoration(
                    labelText: 'Чат',
                    errorText: error(TaskEditorField.delivery),
                  ),
                  items: [
                    for (final chat in state.chatOptions)
                      DropdownMenuItem(
                        value: chat.id.value,
                        child: Text(chat.title ?? chat.id.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      widget.controller.setDeliveryChat(value);
                    }
                  },
                ),
              if (state.error != null)
                Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: state.busy
                    ? null
                    : () async {
                        final result = await widget.controller.save();
                        if (result.isSuccess && context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                child: Text(state.busy ? 'Сохранение…' : 'Сохранить задачу'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _scheduledMoment(
  AutomationService service,
  String zoneId,
  DateTime utc,
) {
  final local = service.timeZones.localTime(zoneId, utc);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)} · $zoneId';
}
