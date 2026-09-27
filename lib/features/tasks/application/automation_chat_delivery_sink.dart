import '../../../core/agents/agents.dart';
import '../../../core/automation/automation.dart';

/// Whether a chat pinned as a delivery target still exists on this device.
abstract interface class TasksChatExistence {
  Future<bool> chatExists(String chatId);
}

/// [TasksChatExistence] over the agent session repository of this device.
final class SessionRepositoryChatExistence implements TasksChatExistence {
  const SessionRepositoryChatExistence(this.repository);

  final AgentSessionRepository repository;

  @override
  Future<bool> chatExists(String chatId) async =>
      await repository.load(AgentSessionId(chatId)) != null;
}

/// Durable delivery of a finished run as a card in the chosen chat.
///
/// The card is a separately typed event with its own reference; it is never a
/// user or assistant message, so the model transcript and the next LLM request
/// stay unchanged. [store] is idempotent by runId: a retried delivery after an
/// uncertain response or a crash between the terminal run write and the
/// delivery marker returns the existing card instead of appending a second one.
///
/// A chat that no longer exists produces an explicit undelivered result with a
/// readable reason, which the service writes into the run record; the result
/// stays visible in the tasks section.
final class AutomationChatDeliverySink implements AutomationResultDelivery {
  AutomationChatDeliverySink({
    required this.store,
    required this.chatExists,
    this.tasks,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AutomationChatDeliveryStore store;
  final TasksChatExistence chatExists;

  /// Task repository used only to resolve the display name of the card.
  final AutomationTaskRepository? tasks;

  final DateTime Function() _now;

  @override
  Future<AutomationDeliveryResult?> deliver({
    required AutomationDelivery target,
    required AutomationRun run,
  }) async {
    if (target.kind != AutomationDeliveryKind.chat || target.chatId == null) {
      return AutomationDeliveryResult(
        delivered: true,
        reference: run.runId.runRef,
      );
    }
    final chatId = target.chatId!.trim();
    late final bool exists;
    try {
      exists = await chatExists.chatExists(chatId);
    } on Object {
      return const AutomationDeliveryResult(
        delivered: false,
        error:
            'Не удалось проверить чат доставки; результат остаётся в разделе '
            '«Задачи».',
      );
    }
    if (!exists) {
      return const AutomationDeliveryResult(
        delivered: false,
        error:
            'Чат для карточки результата не найден на этом устройстве; '
            'результат остаётся в разделе «Задачи».',
      );
    }
    final terminalStatus = run.status == AutomationRunStatus.succeeded
        ? AutomationRunStatus.succeeded
        : AutomationRunStatus.failed;
    final errorMessage = terminalStatus == AutomationRunStatus.failed
        ? run.error?.message ??
              (run.resultText == null
                  ? 'Запуск не завершился успешно; подробности в разделе '
                        '«Задачи».'
                  : null)
        : null;
    final card = AutomationChatDelivery(
      chatId: chatId,
      runId: run.runId.value,
      taskId: run.taskId.value,
      taskName: await _taskName(run.taskId),
      status: terminalStatus,
      resultText: run.resultText,
      errorMessage: errorMessage,
      deliveredAt: _now().toUtc(),
      reference: run.runId.runRef,
    );
    try {
      final write = await store.saveIfAbsent(card);
      final stored = write.delivery;
      if (stored.chatId != chatId) {
        return const AutomationDeliveryResult(
          delivered: false,
          error:
              'Результат этого запуска уже доставлен в другой чат; повторная '
              'доставка не создаёт вторую карточку.',
        );
      }
      return AutomationDeliveryResult(
        delivered: true,
        reference: stored.cardRef,
      );
    } on AutomationException catch (error) {
      return AutomationDeliveryResult(
        delivered: false,
        error: error.error.kind == AutomationErrorKind.persistence
            ? 'Карточку результата не удалось сохранить; результат остаётся в '
                  'разделе «Задачи».'
            : 'Карточку результата не удалось доставить; результат остаётся в '
                  'разделе «Задачи».',
      );
    } on Object {
      return const AutomationDeliveryResult(
        delivered: false,
        error:
            'Карточку результата не удалось доставить; результат остаётся в '
            'разделе «Задачи».',
      );
    }
  }

  Future<String> _taskName(AutomationTaskId taskId) async {
    final repository = tasks;
    if (repository == null) {
      return taskId.value;
    }
    try {
      final task = await repository.findTask(taskId);
      return task?.name ?? taskId.value;
    } on Object {
      return taskId.value;
    }
  }
}
