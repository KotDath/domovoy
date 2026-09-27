import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/automation/automation.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/mcp/mcp.dart';
import '../domain/arxiv_collection_preset.dart';
import '../domain/task_editor_draft.dart';
import 'task_editor_state.dart';
import 'tasks_state.dart';

/// Common IANA zones offered by the editor; any known IANA id is accepted.
const taskEditorCommonTimeZones = <String>[
  'UTC',
  'Europe/Moscow',
  'Europe/Berlin',
  'Europe/London',
  'America/New_York',
  'America/Los_Angeles',
  'Asia/Almaty',
  'Asia/Tokyo',
  'Australia/Sydney',
];

/// Editor of one automation task (B8).
///
/// The editor validates the arbitrary prompt, the one-shot/cron schedule, the
/// explicit IANA zone, the model, the exact allowed MCP tools and the delivery
/// target **before** saving, shows the next three fire times and never writes
/// to the repository directly: creation and edits go through
/// [AutomationService.createTask] and [AutomationService.updateTask].
final class TaskEditorController extends ChangeNotifier {
  TaskEditorController({
    required this.service,
    this.mcpHost,
    this.hostChanges,
    this.chats,
    String? defaultTimeZoneId,
  }) : _state = TaskEditorState(
         draft: TaskEditorDraft(timeZoneId: defaultTimeZoneId ?? 'UTC'),
       ) {
    _state = _derived(_state);
    _refreshPreview();
    hostChanges?.addListener(_syncFromHost);
    _hostEvents = mcpHost?.events.listen((_) => _syncFromHost());
  }

  final AutomationService service;

  /// Live MCP catalog used to offer the exact tools of every server.
  final McpHost? mcpHost;
  final Listenable? hostChanges;

  /// Chats of this device, for the optional result card.
  final AgentSessionCatalog? chats;

  late final StreamSubscription<McpHostEvent>? _hostEvents;
  TaskEditorState _state;
  var _disposed = false;

  TaskEditorState get state => _state;

  /// Starts a new empty task.
  void startNew({String? timeZoneId}) {
    _emit(
      TaskEditorState(
        draft: TaskEditorDraft(
          timeZoneId: timeZoneId ?? _state.draft.timeZoneId,
        ),
        toolConnections: _toolConnections(),
      ),
    );
    _refreshPreview();
  }

  /// Loads an existing task into the editor.
  void editTask(AutomationTask task) {
    _emit(
      TaskEditorState(
        draft: TaskEditorDraft.fromTask(task),
        editingTaskId: task.taskId.value,
        editingRevision: task.revision,
        toolConnections: _toolConnections(),
      ),
    );
    _refreshPreview();
  }

  void setName(String value) =>
      _update(_state.draft.copyWith(name: value), clearNotices: true);

  void setPrompt(String value) =>
      _update(_state.draft.copyWith(prompt: value), clearNotices: true);

  void setScheduleKind(TaskScheduleKind kind) {
    final next = _state.draft.copyWith(scheduleKind: kind);
    _update(next, clearNotices: true);
  }

  void setCronExpression(String value) => _update(
    _state.draft.copyWith(
      cronExpression: value,
      scheduleKind: TaskScheduleKind.cron,
    ),
    clearNotices: true,
  );

  void setTimeZone(String value) =>
      _update(_state.draft.copyWith(timeZoneId: value), clearNotices: true);

  void setOneShotLocal(DateTime value) => _update(
    _state.draft.copyWith(
      oneShotLocal: value,
      scheduleKind: TaskScheduleKind.oneShot,
    ),
    clearNotices: true,
  );

  void setModel(ModelRef? model) =>
      _update(_state.draft.copyWith(model: model), clearNotices: true);

  void toggleTool(String toolId, bool selected) {
    final next = <String>[..._state.draft.allowedToolIds];
    if (selected) {
      if (!next.contains(toolId)) {
        next.add(toolId);
      }
    } else {
      next.remove(toolId);
    }
    _update(_state.draft.copyWith(allowedToolIds: next), clearNotices: true);
  }

  void clearTools() => _update(
    _state.draft.copyWith(allowedToolIds: const <String>[]),
    clearNotices: true,
  );

  void setDeliveryTasks() => _update(
    _state.draft.copyWith(delivery: const AutomationDelivery.tasks()),
    clearNotices: true,
  );

  void setDeliveryChat(String chatId) => _update(
    _state.draft.copyWith(delivery: AutomationDelivery.chat(chatId)),
    clearNotices: true,
  );

  /// Applies the built-in arXiv collection preset over the live catalog.
  ///
  /// A missing server is left out and reported in normal user language; the
  /// preset never widens the selection by itself.
  void applyArxivPreset() {
    final catalog = mcpHost?.snapshot.catalog ?? McpCatalog.empty;
    final available = resolveArxivPresetToolIds(catalog);
    final missing = missingArxivPresetTools(catalog);
    final tools = <String>[..._state.draft.allowedToolIds];
    for (final toolId in available) {
      if (!tools.contains(toolId)) {
        tools.add(toolId);
      }
    }
    final draft = _state.draft.copyWith(
      name: _state.draft.name.trim().isEmpty
          ? arxivPresetName
          : _state.draft.name,
      prompt: _state.draft.prompt.trim().isEmpty
          ? arxivPresetPrompt
          : _state.draft.prompt,
      allowedToolIds: tools,
    );
    _update(
      draft,
      presetNotice: missing.isEmpty
          ? 'Пресет «$arxivPresetName» применён: '
                '${available.length} инструмента(ов).'
          : 'Пресет «$arxivPresetName» применён частично. Не объявлены: '
                '${missing.map((tool) => '${tool.connectionId}.${tool.toolName}').join(', ')}.',
      clearNotices: false,
    );
  }

  /// Reloads the chats that can receive a result card.
  Future<void> loadChats() async {
    final catalog = chats;
    if (catalog == null || _disposed) {
      return;
    }
    _emit(_state.copyWith(chatsLoading: true));
    try {
      final snapshot = await catalog.list();
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(chatOptions: snapshot.available, chatsLoading: false),
      );
    } on Object {
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          chatsLoading: false,
          error: 'Не удалось загрузить список чатов этого устройства.',
        ),
      );
    }
  }

  /// User-facing validation of every field, run before any save.
  Map<TaskEditorField, String> validate() {
    final errors = <TaskEditorField, String>{};
    final limits = service.limits;
    final name = _state.draft.name.trim();
    if (name.isEmpty) {
      errors[TaskEditorField.name] = 'Введите название задачи.';
    } else if (name.length > limits.maxNameCharacters) {
      errors[TaskEditorField.name] =
          'Название длиннее ${limits.maxNameCharacters} символов.';
    }
    final prompt = _state.draft.prompt.trim();
    if (prompt.isEmpty) {
      errors[TaskEditorField.prompt] = 'Введите промпт задачи.';
    } else if (prompt.length > limits.maxPromptCharacters) {
      errors[TaskEditorField.prompt] =
          'Промпт длиннее ${limits.maxPromptCharacters} символов.';
    }
    final scheduleError = _scheduleValidationError();
    if (scheduleError != null) {
      errors[TaskEditorField.schedule] = scheduleError;
    }
    if (_state.draft.model == null) {
      errors[TaskEditorField.model] =
          'Выберите модель: задача выполняется от её имени.';
    }
    if (_state.draft.allowedToolIds.isEmpty) {
      errors[TaskEditorField.tools] =
          'Выберите хотя бы один инструмент: без них задача не сможет '
          'работать, а лишние права ей не нужны.';
    } else {
      if (_state.draft.allowedToolIds.length > limits.maxAllowedTools) {
        errors[TaskEditorField.tools] =
            'Разрешено больше ${limits.maxAllowedTools} инструментов.';
      }
      final missing = _missingSelectedTools();
      if (missing.isNotEmpty) {
        errors[TaskEditorField.tools] =
            'Эти инструменты больше не объявлены сервером: '
            '${missing.join(', ')}. Снимите их или переподключите сервер.';
      }
    }
    final delivery = _state.draft.delivery;
    if (delivery.kind == AutomationDeliveryKind.chat &&
        (delivery.chatId ?? '').trim().isEmpty) {
      errors[TaskEditorField.delivery] =
          'Выберите чат для карточки результата.';
    } else if (delivery.kind == AutomationDeliveryKind.chat &&
        chats != null &&
        !_state.chatOptions.any((chat) => chat.id.value == delivery.chatId)) {
      errors[TaskEditorField.delivery] =
          'Выбранный чат не найден на этом устройстве. Выберите другой чат.';
    }
    return errors;
  }

  /// Validates and saves the draft as a new task or a new revision.
  Future<TasksCommandResult> save() async {
    if (_disposed) {
      return const TasksCommandResult.failed('Редактор задачи закрыт.');
    }
    if (_state.busy) {
      return const TasksCommandResult.busy();
    }
    final errors = validate();
    if (errors.isNotEmpty) {
      _emit(
        _state.copyWith(
          errors: errors,
          error: 'Проверьте поля задачи перед сохранением.',
        ),
      );
      return const TasksCommandResult.failed(
        'Проверьте поля задачи перед сохранением.',
      );
    }
    _emit(_state.copyWith(busy: true, errors: const {}, error: null));
    try {
      final draft = _state.draft.toTaskDraft(service.timeZones);
      final AutomationTask saved;
      final editingId = _state.editingTaskId;
      if (editingId == null) {
        saved = await service.createTask(draft);
      } else {
        saved = await service.updateTask(
          AutomationTaskId(editingId),
          draft,
          expectedRevision: _state.editingRevision,
        );
      }
      _emit(
        _state.copyWith(
          savedTask: saved,
          editingTaskId: saved.taskId.value,
          editingRevision: saved.revision,
          busy: false,
          errors: const {},
          error: null,
          presetNotice: null,
        ),
      );
      _refreshPreview();
      return const TasksCommandResult.succeeded();
    } on AutomationException catch (error) {
      _emit(
        _state.copyWith(
          busy: false,
          error: error.error.message,
          errors: _fieldErrorsFor(error.error),
        ),
      );
      return TasksCommandResult.failed(error.error.message);
    } on Object {
      const message = 'Не удалось сохранить задачу.';
      _emit(_state.copyWith(busy: false, error: message));
      return const TasksCommandResult.failed(message);
    }
  }

  /// Recomputes the next three occurrences of the current draft.
  void refreshPreview() => _refreshPreview();

  Map<TaskEditorField, String> _fieldErrorsFor(AutomationError error) {
    final field = switch (error.kind) {
      AutomationErrorKind.invalidSchedule => TaskEditorField.schedule,
      AutomationErrorKind.revisionMismatch ||
      AutomationErrorKind.conflict => null,
      AutomationErrorKind.invalidInput => TaskEditorField.prompt,
      _ => null,
    };
    return field == null
        ? const {}
        : <TaskEditorField, String>{field: error.message};
  }

  String? _scheduleValidationError() {
    final draft = _state.draft;
    try {
      final schedule = draft.buildSchedule(service.timeZones);
      schedule.validate(service.timeZones);
      final occurrences = schedule.nextOccurrences(
        afterUtc: service.clock.nowUtc(),
        zones: service.timeZones,
        count: 3,
      );
      if (occurrences.isEmpty) {
        return draft.scheduleKind == TaskScheduleKind.oneShot
            ? 'Разовое время уже прошло; выберите будущий момент.'
            : 'У расписания нет следующих запусков; измените выражение.';
      }
    } on AutomationException catch (error) {
      return error.error.message;
    } on Object {
      return 'Не удалось проверить расписание.';
    }
    return null;
  }

  List<String> _missingSelectedTools() {
    final host = mcpHost;
    if (host == null) {
      return const <String>[];
    }
    final catalog = host.snapshot.catalog;
    if (catalog.isEmpty) {
      return List<String>.unmodifiable(_state.draft.allowedToolIds);
    }
    final known = <String>{
      for (final route in catalog.routes) route.modelToolName.value,
    };
    return List<String>.unmodifiable(
      _state.draft.allowedToolIds.where((id) => !known.contains(id)),
    );
  }

  void _update(
    TaskEditorDraft draft, {
    required bool clearNotices,
    String? presetNotice,
  }) {
    _emit(
      _state.copyWith(
        draft: draft,
        savedTask: clearNotices ? null : _state.savedTask,
        presetNotice: clearNotices ? null : presetNotice ?? _state.presetNotice,
        error: clearNotices ? null : _state.error,
        errors: clearNotices ? const {} : _state.errors,
      ),
    );
    _refreshPreview();
  }

  void _refreshPreview() {
    if (_disposed) {
      return;
    }
    var occurrences = const <DateTime>[];
    String? previewError;
    try {
      final schedule = _state.draft.buildSchedule(service.timeZones);
      schedule.validate(service.timeZones);
      occurrences = schedule.nextOccurrences(
        afterUtc: service.clock.nowUtc(),
        zones: service.timeZones,
        count: 3,
      );
      if (occurrences.isEmpty) {
        previewError = _state.draft.scheduleKind == TaskScheduleKind.oneShot
            ? 'Разовое время уже прошло.'
            : 'У расписания нет следующих запусков.';
      }
    } on AutomationException catch (error) {
      previewError = error.error.message;
    } on Object {
      previewError = 'Не удалось вычислить ближайшие запуски.';
    }
    _emit(
      _state.copyWith(occurrences: occurrences, previewError: previewError),
    );
  }

  TaskEditorState _derived(TaskEditorState state) =>
      state.copyWith(toolConnections: _toolConnections());

  List<TaskToolConnection> _toolConnections() {
    final host = mcpHost;
    if (host == null) {
      return const <TaskToolConnection>[];
    }
    final snapshot = host.snapshot;
    final statuses = <String, McpConnectionStatus>{
      for (final status in snapshot.connections) status.id.value: status,
    };
    final grouped = <String, List<McpToolRoute>>{};
    for (final route in snapshot.catalog.routes) {
      grouped
          .putIfAbsent(route.connectionId.value, () => <McpToolRoute>[])
          .add(route);
    }
    final keys = grouped.keys.toList()..sort();
    final result = <TaskToolConnection>[];
    for (final key in keys) {
      final routes = grouped[key]!;
      routes.sort(
        (left, right) =>
            left.originalToolName.compareTo(right.originalToolName),
      );
      final status = statuses[key];
      result.add(
        TaskToolConnection(
          connectionId: McpConnectionId(key),
          alias: status?.alias ?? key,
          connected: status?.phase == McpConnectionPhase.ready,
          unavailableReason: _connectionReason(status),
          tools: List<TaskToolChoice>.unmodifiable(<TaskToolChoice>[
            for (final route in routes)
              TaskToolChoice(
                toolId: route.modelToolName.value,
                originalName: route.originalToolName,
                title: route.descriptor.title,
                description: route.descriptor.description,
              ),
          ]),
        ),
      );
    }
    return List<TaskToolConnection>.unmodifiable(result);
  }

  String? _connectionReason(McpConnectionStatus? status) {
    if (status == null) {
      return 'Сервер не подключён в этой сессии.';
    }
    if (status.phase == McpConnectionPhase.disabled) {
      return 'Сервер отключён в настройках.';
    }
    if (status.lastError != null) {
      return status.lastError;
    }
    return switch (status.phase) {
      McpConnectionPhase.disabled => 'Сервер отключён в настройках.',
      McpConnectionPhase.stopped => 'Сервер не подключён.',
      McpConnectionPhase.connecting => 'Идёт подключение…',
      McpConnectionPhase.failed =>
        status.lastError ?? 'Не удалось подключиться к серверу.',
      McpConnectionPhase.ready => null,
    };
  }

  void _syncFromHost() {
    if (_disposed) {
      return;
    }
    _emit(_state.copyWith(toolConnections: _toolConnections()));
  }

  void _emit(TaskEditorState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    hostChanges?.removeListener(_syncFromHost);
    unawaited(_hostEvents?.cancel());
    super.dispose();
  }
}
