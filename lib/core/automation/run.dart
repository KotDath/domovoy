import '../llm/identifiers.dart';
import 'errors.dart';
import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'task.dart';

/// Lifecycle of one automation run.
enum AutomationRunStatus {
  /// The run record was persisted and the agent session is executing.
  running,

  /// The agent session completed and produced a result.
  succeeded,

  /// The run stopped with a visible error; no retry happens automatically.
  failed,

  /// The period was not executed (overlap or pause) and is recorded as skipped.
  skipped,

  /// The run was cut off by a background transition, shutdown or crash.
  interrupted;

  bool get isTerminal => this != running;

  static AutomationRunStatus fromWire(Object? raw) {
    for (final status in values) {
      if (status.name == raw) {
        return status;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестный статус запуска "$raw".',
    );
  }
}

/// Why a run was created.
enum AutomationRunTrigger {
  /// The persisted `nextDueAt` fired on time.
  scheduled,

  /// The app was reopened (or resumed) after one or more missed periods.
  catchUp,

  /// A person or an interactive agent requested the run now.
  manual;

  static AutomationRunTrigger fromWire(Object? raw) {
    for (final trigger in values) {
      if (trigger.name == raw) {
        return trigger;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестный источник запуска "$raw".',
    );
  }
}

/// Machine-readable failure taxonomy of one run.
enum AutomationRunErrorKind {
  unavailable,
  modelUnavailable,
  toolUnavailable,
  secretUnavailable,
  timeout,
  limits,
  cancelled,
  interrupted,
  provider,
  agent,
  noOverlap,
  denied,
  delivery,
  internal;

  static AutomationRunErrorKind? tryFromWire(Object? raw) {
    for (final kind in values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    return null;
  }
}

/// Terminal status of one traced tool call.
enum AutomationToolTraceStatus {
  succeeded,
  failed,
  denied,
  unavailable;

  static AutomationToolTraceStatus fromWire(Object? raw) {
    for (final status in values) {
      if (status.name == raw) {
        return status;
      }
    }
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Неизвестный статус вызова "$raw".',
    );
  }
}

/// One tool call in the run trace.
final class AutomationToolTraceEntry {
  AutomationToolTraceEntry({
    required String name,
    required this.status,
    String? detail,
  }) : name = name.trim(),
       detail = detail == null ? null : sanitizeAutomationText(detail) {
    if (this.name.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Имя инструмента в трассе не может быть пустым.',
      );
    }
  }

  factory AutomationToolTraceEntry.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Запись трассы');
    final detail = map['detail'];
    if (detail != null && detail is! String) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'detail трассы должен быть строкой.',
      );
    }
    return AutomationToolTraceEntry(
      name: requireJsonText(
        map,
        'name',
        label: 'Запись трассы',
        maxLength: 200,
      ),
      status: AutomationToolTraceStatus.fromWire(map['status']),
      detail: detail as String?,
    );
  }

  final String name;
  final AutomationToolTraceStatus status;
  final String? detail;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'name': name,
    'status': status.name,
    if (detail != null) 'detail': detail,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationToolTraceEntry &&
          other.name == name &&
          other.status == status &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(name, status, detail);
}

/// One sanitized run failure.
final class AutomationRunError {
  AutomationRunError({required this.kind, required String message})
    : message = sanitizeAutomationText(message);

  factory AutomationRunError.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Ошибка запуска');
    final kind = AutomationRunErrorKind.tryFromWire(map['kind']);
    if (kind == null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Неизвестный вид ошибки запуска "${map['kind']}".',
      );
    }
    return AutomationRunError(
      kind: kind,
      message: requireJsonText(map, 'message', label: 'Ошибка запуска'),
    );
  }

  final AutomationRunErrorKind kind;
  final String message;

  Map<String, Object?> toJson() =>
      freezeJsonMap(<String, Object?>{'kind': kind.name, 'message': message});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationRunError &&
          other.kind == kind &&
          other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => '${kind.name}: $message';
}

/// Outcome of delivering a finished run to its configured target.
final class AutomationDeliveryResult {
  const AutomationDeliveryResult({
    required this.delivered,
    this.reference,
    this.error,
  });

  factory AutomationDeliveryResult.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Доставка');
    final reference = map['reference'];
    final error = map['error'];
    if (reference != null && reference is! String) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'reference доставки должен быть строкой.',
      );
    }
    if (error != null && error is! String) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'error доставки должен быть строкой.',
      );
    }
    return AutomationDeliveryResult(
      delivered: map['delivered'] == true,
      reference: reference as String?,
      error: error as String?,
    );
  }

  final bool delivered;
  final String? reference;
  final String? error;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'delivered': delivered,
    if (reference != null) 'reference': reference,
    if (error != null) 'error': error,
  });
}

/// One persisted automation run.
///
/// The first record of a run stream holds status `running`; the terminal record
/// replaces it after the executor settles. `(taskId, scheduledAt)` is the
/// idempotency identity of a **period**: a scheduled, catch-up or skipped
/// period is never executed twice, including after a crash, and history is
/// never rewritten by a later run. Manual runs do not occupy a period: they are
/// distinct by [runId] and never consume the schedule.
final class AutomationRun {
  AutomationRun({
    required String runId,
    required String taskId,
    required this.taskRevision,
    required this.trigger,
    required this.status,
    required DateTime scheduledAt,
    DateTime? startedAt,
    DateTime? finishedAt,
    required this.model,
    Iterable<String> allowedToolIds = const <String>[],
    this.deliveryTarget,
    this.resultText,
    this.error,
    this.aggregatedSkippedCount = 0,
    DateTime? skippedFrom,
    this.skippedTruncated = false,
    this.modelTurns = 0,
    this.toolCalls = 0,
    Iterable<AutomationToolTraceEntry> trace =
        const <AutomationToolTraceEntry>[],
    this.delivery,
    this.revision = 0,
  }) : runId = AutomationRunId(runId),
       taskId = AutomationTaskId(taskId),
       scheduledAt = scheduledAt.toUtc(),
       startedAt = startedAt?.toUtc(),
       finishedAt = finishedAt?.toUtc(),
       allowedToolIds = normalizeAllowedToolIds(allowedToolIds),
       skippedFrom = skippedFrom?.toUtc(),
       trace = List<AutomationToolTraceEntry>.unmodifiable(trace) {
    if (aggregatedSkippedCount < 0) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Число пропущенных периодов не может быть отрицательным.',
      );
    }
    if (revision < 0) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Ревизия запуска не может быть отрицательной.',
      );
    }
    if (status == AutomationRunStatus.running) {
      if (this.startedAt == null || this.finishedAt != null || error != null) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Активный запуск требует startedAt и не имеет finishedAt/error.',
        );
      }
    } else if (this.finishedAt == null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Завершённый запуск требует finishedAt.',
      );
    }
  }

  factory AutomationRun.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Запуск автоматизации');
    final version = map['schemaVersion'];
    if (version != schemaVersion) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Версия записи запуска не поддерживается: $version.',
      );
    }
    final startedRaw = map['startedAt'];
    final finishedRaw = map['finishedAt'];
    final skippedRaw = map['skippedFrom'];
    final traceRaw = map['trace'] ?? const <Object?>[];
    if (traceRaw is! List) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'trace должен быть массивом.',
      );
    }
    return AutomationRun(
      runId: requireJsonText(map, 'runId', label: 'Запуск', maxLength: 80),
      taskId: requireJsonText(map, 'taskId', label: 'Запуск', maxLength: 80),
      taskRevision: requireJsonInt(
        map,
        'taskRevision',
        label: 'Запуск',
        minimum: 0,
      ),
      trigger: AutomationRunTrigger.fromWire(map['trigger']),
      status: AutomationRunStatus.fromWire(map['status']),
      scheduledAt: _utcFromJson(map, 'scheduledAt'),
      startedAt: _optionalUtc(startedRaw, 'startedAt'),
      finishedAt: _optionalUtc(finishedRaw, 'finishedAt'),
      model: _modelRefFromJson(map['model']),
      allowedToolIds: _toolIdsFromJson(map['allowedToolIds']),
      deliveryTarget: map['deliveryTarget'] == null
          ? null
          : AutomationDelivery.fromJson(map['deliveryTarget']),
      resultText: _optionalText(map['resultText'], 'resultText'),
      error: map['error'] == null
          ? null
          : AutomationRunError.fromJson(map['error']),
      aggregatedSkippedCount: map['aggregatedSkippedCount'] is int
          ? map['aggregatedSkippedCount'] as int
          : 0,
      skippedFrom: _optionalUtc(skippedRaw, 'skippedFrom'),
      skippedTruncated: map['skippedTruncated'] == true,
      modelTurns: map['modelTurns'] is int ? map['modelTurns'] as int : 0,
      toolCalls: map['toolCalls'] is int ? map['toolCalls'] as int : 0,
      trace: traceRaw
          .map(AutomationToolTraceEntry.fromJson)
          .toList(growable: false),
      delivery: map['delivery'] == null
          ? null
          : AutomationDeliveryResult.fromJson(map['delivery']),
      revision: requireJsonInt(map, 'revision', label: 'Запуск', minimum: 0),
    );
  }

  static const schemaVersion = 1;

  final AutomationRunId runId;
  final AutomationTaskId taskId;

  /// Task revision the run started from; later edits do not affect it.
  final int taskRevision;

  final AutomationRunTrigger trigger;
  final AutomationRunStatus status;

  /// UTC instant this run belongs to; the idempotency key with [taskId].
  final DateTime scheduledAt;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Model pinned when the run started.
  final ModelRef model;

  /// Tools pinned when the run started.
  final List<String> allowedToolIds;

  /// Delivery target pinned when the run started.
  ///
  /// An edit of the task while the run executes changes only later runs; the
  /// result is routed by this snapshot, not by the current task record. Null
  /// only for legacy records written before the field existed.
  final AutomationDelivery? deliveryTarget;

  final String? resultText;
  final AutomationRunError? error;

  /// How many older periods this catch-up run aggregates as skipped.
  final int aggregatedSkippedCount;

  /// First missed period of the catch-up, when known.
  final DateTime? skippedFrom;

  /// True when [aggregatedSkippedCount] is a lower bound ("at least").
  final bool skippedTruncated;

  final int modelTurns;
  final int toolCalls;
  final List<AutomationToolTraceEntry> trace;
  final AutomationDeliveryResult? delivery;
  final int revision;

  /// Stable `(taskId, scheduledAt)` identity of a **period**.
  ///
  /// Only scheduled, catch-up and skipped runs share this identity; manual
  /// runs are distinct by [runId] and never consume a period.
  static String scheduleKey(AutomationTaskId taskId, DateTime scheduledAt) =>
      '${taskId.value}@${scheduledAt.toUtc().toIso8601String()}';

  String get scheduleKeyValue => scheduleKey(taskId, scheduledAt);

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'schemaVersion': schemaVersion,
    'runId': runId.value,
    'taskId': taskId.value,
    'taskRevision': taskRevision,
    'trigger': trigger.name,
    'status': status.name,
    'scheduledAt': scheduledAt.toIso8601String(),
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'model': <String, Object?>{
      'providerId': model.providerId.value,
      'modelId': model.modelId.value,
    },
    'allowedToolIds': allowedToolIds,
    if (deliveryTarget != null) 'deliveryTarget': deliveryTarget!.toJson(),
    if (resultText != null) 'resultText': resultText,
    if (error != null) 'error': error!.toJson(),
    'aggregatedSkippedCount': aggregatedSkippedCount,
    if (skippedFrom != null) 'skippedFrom': skippedFrom!.toIso8601String(),
    if (skippedTruncated) 'skippedTruncated': true,
    'modelTurns': modelTurns,
    'toolCalls': toolCalls,
    'trace': trace.map((entry) => entry.toJson()).toList(growable: false),
    if (delivery != null) 'delivery': delivery!.toJson(),
    'revision': revision,
  });

  AutomationRun copyWith({
    int? taskRevision,
    AutomationRunStatus? status,
    Object? startedAt = _unset,
    Object? finishedAt = _unset,
    Object? resultText = _unset,
    Object? error = _unset,
    int? aggregatedSkippedCount,
    Object? skippedFrom = _unset,
    bool? skippedTruncated,
    int? modelTurns,
    int? toolCalls,
    Iterable<AutomationToolTraceEntry>? trace,
    Object? delivery = _unset,
    int? revision,
  }) {
    return AutomationRun(
      runId: runId.value,
      taskId: taskId.value,
      taskRevision: taskRevision ?? this.taskRevision,
      trigger: trigger,
      status: status ?? this.status,
      scheduledAt: scheduledAt,
      startedAt: identical(startedAt, _unset)
          ? this.startedAt
          : startedAt as DateTime?,
      finishedAt: identical(finishedAt, _unset)
          ? this.finishedAt
          : finishedAt as DateTime?,
      model: model,
      allowedToolIds: allowedToolIds,
      deliveryTarget: deliveryTarget,
      resultText: identical(resultText, _unset)
          ? this.resultText
          : resultText as String?,
      error: identical(error, _unset)
          ? this.error
          : error as AutomationRunError?,
      aggregatedSkippedCount:
          aggregatedSkippedCount ?? this.aggregatedSkippedCount,
      skippedFrom: identical(skippedFrom, _unset)
          ? this.skippedFrom
          : skippedFrom as DateTime?,
      skippedTruncated: skippedTruncated ?? this.skippedTruncated,
      modelTurns: modelTurns ?? this.modelTurns,
      toolCalls: toolCalls ?? this.toolCalls,
      trace: trace ?? this.trace,
      delivery: identical(delivery, _unset)
          ? this.delivery
          : delivery as AutomationDeliveryResult?,
      revision: revision ?? this.revision,
    );
  }

  /// Bounds the record against the configured limits.
  AutomationRun validateAgainst(AutomationLimits limits) {
    if (trace.length > limits.maxTraceEntries) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Трасса запуска длиннее ${limits.maxTraceEntries} записей.',
      );
    }
    if (allowedToolIds.length > limits.maxAllowedTools) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Снимок инструментов запуска длиннее ${limits.maxAllowedTools}.',
      );
    }
    return this;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AutomationRun && other.runId == runId;

  @override
  int get hashCode => runId.hashCode;

  @override
  String toString() =>
      'AutomationRun(${runId.value}, ${status.name}, ${scheduledAt.toIso8601String()})';
}

const Object _unset = Object();

DateTime _utcFromJson(Map<String, Object?> json, String key) {
  final raw = json[key];
  if (raw is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601 строкой.',
    );
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601.',
    );
  }
  return parsed.toUtc();
}

DateTime? _optionalUtc(Object? raw, String key) {
  if (raw == null) {
    return null;
  }
  if (raw is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601 строкой.',
    );
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть ISO 8601.',
    );
  }
  return parsed.toUtc();
}

String? _optionalText(Object? raw, String key) {
  if (raw == null) {
    return null;
  }
  if (raw is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" должно быть строкой.',
    );
  }
  return raw;
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
