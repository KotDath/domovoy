import '../llm/identifiers.dart';
import 'errors.dart';
import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'schedule.dart';

/// Lifecycle state of one automation task.
///
/// `proposed` is the only state an agent tool can create: it is a proposal
/// that waits for a human confirmation in the tasks UI. `deleted` is a
/// tombstone kept in the append-only JSONL stream.
enum AutomationTaskState {
  proposed,
  active,
  paused,
  completed,
  deleted;

  static AutomationTaskState fromWire(Object? raw) {
    for (final state in values) {
      if (state.name == raw) {
        return state;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестное состояние задачи "$raw".',
    );
  }

  bool get isScheduled => this == active;

  bool get isAlive => this != deleted;
}

/// Who created a task. Agent-created tasks always start as proposals.
enum AutomationTaskOrigin {
  human,
  agent;

  static AutomationTaskOrigin fromWire(Object? raw) {
    for (final origin in values) {
      if (origin.name == raw) {
        return origin;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестный источник задачи "$raw".',
    );
  }
}

/// Where the result of a finished run is delivered.
enum AutomationDeliveryKind {
  /// The run is visible in the tasks section only.
  tasks,

  /// The result also appears as a card in the referenced chat.
  chat;

  static AutomationDeliveryKind fromWire(Object? raw) {
    for (final kind in values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестный способ доставки "$raw".',
    );
  }
}

/// Delivery target of one task, pinned when the task is saved.
final class AutomationDelivery {
  const AutomationDelivery.tasks()
    : kind = AutomationDeliveryKind.tasks,
      chatId = null;

  const AutomationDelivery.chat(String this.chatId)
    : kind = AutomationDeliveryKind.chat;

  factory AutomationDelivery.fromJson(Object? json) {
    final map = requireJsonObject(json, 'delivery');
    final kind = AutomationDeliveryKind.fromWire(map['kind']);
    if (kind == AutomationDeliveryKind.tasks) {
      return const AutomationDelivery.tasks();
    }
    final chatId = map['chatId'];
    if (chatId is! String || chatId.trim().isEmpty || chatId.length > 128) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Доставка в чат требует непустой "chatId" до 128 символов.',
      );
    }
    return AutomationDelivery.chat(chatId.trim());
  }

  final AutomationDeliveryKind kind;
  final String? chatId;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind.name,
    if (chatId != null) 'chatId': chatId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationDelivery &&
          other.kind == kind &&
          other.chatId == chatId;

  @override
  int get hashCode => Object.hash(kind, chatId);

  @override
  String toString() =>
      kind == AutomationDeliveryKind.tasks ? 'tasks' : 'chat($chatId)';
}

/// Validated task fields before identity and schedule state are assigned.
final class AutomationTaskDraft {
  AutomationTaskDraft({
    required String name,
    required String prompt,
    required this.schedule,
    required this.model,
    Iterable<String> allowedToolIds = const <String>[],
    this.delivery = const AutomationDelivery.tasks(),
    this.origin = AutomationTaskOrigin.human,
  }) : name = name.trim(),
       prompt = prompt.trim(),
       allowedToolIds = normalizeAllowedToolIds(allowedToolIds);

  final String name;
  final String prompt;
  final AutomationSchedule schedule;
  final ModelRef model;
  final List<String> allowedToolIds;
  final AutomationDelivery delivery;
  final AutomationTaskOrigin origin;
}

/// One saved automation task.
///
/// The record pins the prompt, model, allowed tools and delivery; editing the
/// current chat never changes an already saved task. Every mutation increments
/// [revision], which the store checks optimistically before appending.
final class AutomationTask {
  AutomationTask({
    required String taskId,
    required String name,
    required String prompt,
    required this.schedule,
    required this.model,
    Iterable<String> allowedToolIds = const <String>[],
    this.delivery = const AutomationDelivery.tasks(),
    required this.state,
    required this.origin,
    DateTime? nextDueAt,
    this.revision = 0,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : taskId = AutomationTaskId(taskId),
       name = name.trim(),
       prompt = prompt.trim(),
       allowedToolIds = normalizeAllowedToolIds(allowedToolIds),
       nextDueAt = nextDueAt?.toUtc(),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    if (this.name.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Название задачи не может быть пустым.',
      );
    }
    if (this.prompt.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Промпт задачи не может быть пустым.',
      );
    }
    if (revision < 0) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Ревизия задачи не может быть отрицательной.',
      );
    }
    if (state.isScheduled || state == AutomationTaskState.proposed) {
      if (this.nextDueAt == null) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Задача в состоянии ${state.name} требует вычисленного nextDueAt.',
        );
      }
    } else if (this.nextDueAt != null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Задача в состоянии ${state.name} не может иметь nextDueAt.',
      );
    }
  }

  factory AutomationTask.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Задача автоматизации');
    final version = map['schemaVersion'];
    if (version != schemaVersion) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Версия записи задачи не поддерживается: $version.',
      );
    }
    final nextDueRaw = map['nextDueAt'];
    DateTime? nextDueAt;
    if (nextDueRaw != null) {
      if (nextDueRaw is! String) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'nextDueAt должен быть ISO 8601 строкой.',
        );
      }
      nextDueAt = DateTime.tryParse(nextDueRaw);
      if (nextDueAt == null || !nextDueAt.isUtc) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'nextDueAt должен быть ISO 8601 UTC: "$nextDueRaw".',
        );
      }
    }
    return AutomationTask(
      taskId: requireJsonText(map, 'taskId', label: 'Задача', maxLength: 80),
      name: requireJsonText(map, 'name', label: 'Задача'),
      prompt: requireJsonText(map, 'prompt', label: 'Задача'),
      schedule: AutomationSchedule.fromJson(map['schedule']),
      model: _modelRefFromJson(map['model']),
      allowedToolIds: _toolIdsFromJson(map['allowedToolIds']),
      delivery: AutomationDelivery.fromJson(map['delivery']),
      state: AutomationTaskState.fromWire(map['state']),
      origin: AutomationTaskOrigin.fromWire(map['origin']),
      nextDueAt: nextDueAt,
      revision: requireJsonInt(map, 'revision', label: 'Задача', minimum: 0),
      createdAt: _utcFromJson(map, 'createdAt'),
      updatedAt: _utcFromJson(map, 'updatedAt'),
    );
  }

  static const schemaVersion = 1;

  final AutomationTaskId taskId;
  final String name;
  final String prompt;
  final AutomationSchedule schedule;
  final ModelRef model;
  final List<String> allowedToolIds;
  final AutomationDelivery delivery;
  final AutomationTaskState state;
  final AutomationTaskOrigin origin;

  /// Next planned UTC instant; null in paused, completed or deleted states.
  final DateTime? nextDueAt;

  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'schemaVersion': schemaVersion,
    'taskId': taskId.value,
    'name': name,
    'prompt': prompt,
    'schedule': schedule.toJson(),
    'model': <String, Object?>{
      'providerId': model.providerId.value,
      'modelId': model.modelId.value,
    },
    'allowedToolIds': allowedToolIds,
    'delivery': delivery.toJson(),
    'state': state.name,
    'origin': origin.name,
    if (nextDueAt != null) 'nextDueAt': nextDueAt!.toIso8601String(),
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  /// Applies field edits without touching identity, revision or creation time.
  AutomationTask copyWith({
    String? name,
    String? prompt,
    AutomationSchedule? schedule,
    ModelRef? model,
    Iterable<String>? allowedToolIds,
    AutomationDelivery? delivery,
    AutomationTaskState? state,
    Object? nextDueAt = _unset,
    int? revision,
    DateTime? updatedAt,
  }) {
    return AutomationTask(
      taskId: taskId.value,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      schedule: schedule ?? this.schedule,
      model: model ?? this.model,
      allowedToolIds: allowedToolIds ?? this.allowedToolIds,
      delivery: delivery ?? this.delivery,
      state: state ?? this.state,
      origin: origin,
      nextDueAt: identical(nextDueAt, _unset)
          ? this.nextDueAt
          : nextDueAt as DateTime?,
      revision: revision ?? this.revision,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Next revision of this task after [state]/[nextDueAt] changed at [now].
  AutomationTask nextRevision({
    required AutomationTaskState state,
    required DateTime? nextDueAt,
    required DateTime now,
  }) => copyWith(
    state: state,
    nextDueAt: nextDueAt,
    revision: revision + 1,
    updatedAt: now,
  );

  /// Bounds the record against the configured limits.
  AutomationTask validateAgainst(AutomationLimits limits) {
    if (name.length > limits.maxNameCharacters) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Название задачи длиннее ${limits.maxNameCharacters} символов.',
      );
    }
    if (prompt.length > limits.maxPromptCharacters) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Промпт задачи длиннее ${limits.maxPromptCharacters} символов.',
      );
    }
    if (allowedToolIds.length > limits.maxAllowedTools) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Задача не может разрешить больше ${limits.maxAllowedTools} инструментов.',
      );
    }
    return this;
  }

  bool get isActive => state == AutomationTaskState.active;

  bool get isAlive => state.isAlive;

  /// Stable identity of the scheduled policy this task's runs use.
  String get policyId => 'scheduled-task-${taskId.value}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationTask &&
          other.taskId == taskId &&
          other.revision == revision;

  @override
  int get hashCode => Object.hash(taskId, revision);

  @override
  String toString() =>
      'AutomationTask(${taskId.value}, ${state.name}, rev $revision)';
}

const Object _unset = Object();

/// Shared normalization for allowed tool ids: trimmed, unique, bounded.
List<String> normalizeAllowedToolIds(
  Iterable<String> values, {
  int maxAllowed = 50,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Идентификатор разрешённого инструмента не может быть пустым.',
      );
    }
    if (seen.add(trimmed)) {
      result.add(trimmed);
    }
  }
  if (result.length > maxAllowed) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Задача не может разрешить больше $maxAllowed инструментов.',
    );
  }
  return List<String>.unmodifiable(result);
}

ModelRef _modelRefFromJson(Object? json) {
  final map = requireJsonObject(json, 'Модель');
  return ModelRef(
    providerId: ProviderId(requireJsonText(map, 'providerId', label: 'Модель')),
    modelId: ModelId(requireJsonText(map, 'modelId', label: 'Модель')),
  );
}

List<String> _toolIdsFromJson(Object? json) {
  if (json == null) {
    return const <String>[];
  }
  if (json is! List) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'allowedToolIds должен быть массивом строк.',
    );
  }
  return normalizeAllowedToolIds(
    json.map((value) {
      if (value is! String) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'allowedToolIds должен содержать только строки.',
        );
      }
      return value;
    }),
  );
}

DateTime _utcFromJson(Map<String, Object?> json, String key) {
  final raw = json[key];
  if (raw is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601 строкой.',
    );
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !parsed.isUtc) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601 UTC.',
    );
  }
  return parsed;
}
