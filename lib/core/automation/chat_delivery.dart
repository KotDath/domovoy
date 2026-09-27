import 'errors.dart';
import 'ids.dart';
import 'json.dart';
import 'run.dart';

/// Version of the separately typed chat delivery card contract (B8).
///
/// Bump only together with a replay/migration path: readers reject unknown
/// versions instead of partially accepting a new shape.
const automationChatDeliverySchemaVersion = 1;

/// Stable stream-key prefix of one delivered result card.
const automationChatDeliveryPrefix = 'acd_';

/// Separately typed result card delivered to one chat.
///
/// A card is **not** a user or assistant message: it never enters the model
/// transcript and the next LLM request is byte-identical with and without it.
/// The card lives in its own durable stream and is projected by the chat UI
/// from that stream, so reopening the chat shows it again.
///
/// Identity is `(chatId, runId)`: delivery of one run is idempotent, and a
/// retry after an uncertain response or a crash between the terminal run write
/// and the delivery marker finds the existing card instead of appending a
/// second one.
final class AutomationChatDelivery {
  AutomationChatDelivery({
    required String chatId,
    required String runId,
    required String taskId,
    required String taskName,
    required this.status,
    String? resultText,
    String? errorMessage,
    required DateTime deliveredAt,
    String? reference,
  }) : chatId = _requireText(chatId, 'chatId', maxLength: 128),
       runId = AutomationRunId(runId),
       taskId = AutomationTaskId(taskId),
       taskName = _requireText(taskName, 'taskName', maxLength: 200),
       resultText = resultText == null
           ? null
           : sanitizeAutomationText(resultText, maxLength: 4000),
       errorMessage = errorMessage == null
           ? null
           : sanitizeAutomationText(errorMessage, maxLength: 1000),
       deliveredAt = deliveredAt.toUtc(),
       reference = reference ?? AutomationRunId(runId).runRef {
    if (status != AutomationRunStatus.succeeded &&
        status != AutomationRunStatus.failed) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Карточку в чат можно доставить только по завершённому запуску; '
        'статус ${status.name} не поддерживается.',
      );
    }
    if (status == AutomationRunStatus.failed &&
        errorMessage == null &&
        resultText == null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Неуспешный запуск требует текста ошибки или частичного результата.',
      );
    }
  }

  factory AutomationChatDelivery.fromJson(Object? json) {
    final map = requireJsonObject(json, 'Карточка результата');
    final version = map['schemaVersion'];
    if (version != automationChatDeliverySchemaVersion) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Версия карточки результата не поддерживается: $version.',
      );
    }
    final deliveredAtRaw = map['deliveredAt'];
    if (deliveredAtRaw is! String) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'deliveredAt карточки должен быть ISO 8601 UTC.',
      );
    }
    final deliveredAt = DateTime.tryParse(deliveredAtRaw);
    if (deliveredAt == null || !deliveredAt.isUtc) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'deliveredAt карточки должен быть ISO 8601 UTC.',
      );
    }
    return AutomationChatDelivery(
      chatId: requireJsonText(
        map,
        'chatId',
        label: 'Карточка результата',
        maxLength: 128,
      ),
      runId: requireJsonText(
        map,
        'runId',
        label: 'Карточка результата',
        maxLength: 80,
      ),
      taskId: requireJsonText(
        map,
        'taskId',
        label: 'Карточка результата',
        maxLength: 80,
      ),
      taskName: requireJsonText(
        map,
        'taskName',
        label: 'Карточка результата',
        maxLength: 200,
      ),
      status: AutomationRunStatus.fromWire(map['status']),
      resultText: _optionalText(map, 'resultText'),
      errorMessage: _optionalText(map, 'errorMessage'),
      deliveredAt: deliveredAt,
      reference: _optionalText(map, 'reference'),
    );
  }

  /// Chat this card is addressed to.
  final String chatId;

  /// Run this card reports; part of the idempotency identity.
  final AutomationRunId runId;

  final AutomationTaskId taskId;
  final String taskName;

  /// Terminal status of the reported run: `succeeded` or `failed`.
  final AutomationRunStatus status;

  final String? resultText;

  /// Sanitized error text of a failed run.
  final String? errorMessage;

  final DateTime deliveredAt;

  /// Stable reference of the source run, for the tasks section deep link.
  final String reference;

  /// Stable durable identity of this card, derived from [runId].
  String get deliveryId => deliveryIdForRun(runId.value);

  /// Own reference of the card event, distinct from the run reference.
  String get cardRef => 'domovoy://automation/chat/$deliveryId';

  /// Stable stream key of the card of [runId].
  static String deliveryIdForRun(String runId) =>
      '$automationChatDeliveryPrefix$runId';

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'schemaVersion': automationChatDeliverySchemaVersion,
    'deliveryId': deliveryId,
    'chatId': chatId,
    'runId': runId.value,
    'taskId': taskId.value,
    'taskName': taskName,
    'status': status.name,
    if (resultText != null) 'resultText': resultText,
    if (errorMessage != null) 'errorMessage': errorMessage,
    'deliveredAt': deliveredAt.toIso8601String(),
    'reference': reference,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationChatDelivery &&
          other.deliveryId == deliveryId &&
          other.chatId == chatId &&
          other.runId == runId &&
          other.taskId == taskId &&
          other.taskName == taskName &&
          other.status == status &&
          other.resultText == resultText &&
          other.errorMessage == errorMessage &&
          other.deliveredAt == deliveredAt &&
          other.reference == reference;

  @override
  int get hashCode => Object.hash(
    deliveryId,
    chatId,
    runId,
    taskId,
    taskName,
    status,
    resultText,
    errorMessage,
    deliveredAt,
    reference,
  );

  @override
  String toString() =>
      'AutomationChatDelivery($deliveryId -> chat $chatId, ${status.name})';
}

/// Outcome of one idempotent card append.
final class AutomationChatDeliveryWrite {
  const AutomationChatDeliveryWrite({
    required this.delivery,
    required this.created,
  });

  final AutomationChatDelivery delivery;

  /// True only when this call published the card; false means the durable card
  /// of the same run existed already and was returned instead of duplicated.
  final bool created;

  bool get deduplicated => !created;
}

/// Durable, separately typed store of chat result cards.
///
/// Append is idempotent by `(chatId, runId)`: [saveIfAbsent] returns the
/// existing card and never writes a second one for the same run. Implemented
/// by the B8 infrastructure JSONL store.
abstract interface class AutomationChatDeliveryStore {
  /// Card of [runId], or null when nothing was delivered for it yet.
  Future<AutomationChatDelivery?> findByRunId(String runId);

  /// Publishes [delivery] unless a card for the same `(chatId, runId)` exists.
  Future<AutomationChatDeliveryWrite> saveIfAbsent(
    AutomationChatDelivery delivery,
  );
}

/// Read side of the card store consumed by chat presentation.
abstract interface class AutomationChatDeliverySource {
  /// All cards addressed to [chatId], oldest first.
  Future<List<AutomationChatDelivery>> deliveriesForChat(String chatId);

  /// Cards appended in this process, for a chat that is currently open.
  Stream<AutomationChatDelivery> get delivered;
}

String _requireText(String value, String label, {required int maxLength}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$label" карточки результата не может быть пустым.',
    );
  }
  if (trimmed.length > maxLength) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$label" карточки результата длиннее $maxLength символов.',
    );
  }
  if (RegExp(r'[\u0000-\u001F\u007F]').hasMatch(trimmed)) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$label" карточки результата содержит управляющие символы.',
    );
  }
  return trimmed;
}

String? _optionalText(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Поле "$key" карточки результата должно быть строкой.',
    );
  }
  return value;
}
