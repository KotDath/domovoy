import 'errors.dart';

/// Limits of one scheduled agent run.
///
/// The scheduler passes these to the injected executor; the executor maps them
/// onto the agent runtime limits, so a background task can never spend more
/// time, model turns, tool calls or output than the user accepted.
final class AutomationRunLimits {
  const AutomationRunLimits({
    this.maxDuration = const Duration(minutes: 10),
    this.maxModelTurns = 24,
    this.maxToolCalls = 40,
    this.maxOutputTokensPerTurn = 4096,
    this.maxResultCharacters = 16000,
  });

  final Duration maxDuration;
  final int maxModelTurns;
  final int maxToolCalls;
  final int maxOutputTokensPerTurn;
  final int maxResultCharacters;

  AutomationRunLimits validate() {
    if (maxDuration <= Duration.zero) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Лимит времени запуска должен быть положительным.',
      );
    }
    _positive('maxModelTurns', maxModelTurns);
    _positive('maxToolCalls', maxToolCalls);
    _positive('maxOutputTokensPerTurn', maxOutputTokensPerTurn);
    _positive('maxResultCharacters', maxResultCharacters);
    return this;
  }

  /// Runtime budget for the agent loop: slightly tighter than the hard
  /// deadline enforced around the whole run, so the runtime stops gracefully
  /// with a stop reason instead of being cut off from outside.
  Duration get runtimeBudget {
    final grace = Duration(seconds: maxDuration.inSeconds ~/ 10 + 1);
    final budget = maxDuration - grace;
    return budget < const Duration(seconds: 30) ? maxDuration : budget;
  }
}

/// Limits of the automation store and service.
final class AutomationLimits {
  const AutomationLimits({
    this.maxNameCharacters = 120,
    this.maxPromptCharacters = 8000,
    this.maxSessionLabelCharacters = 200,
    this.maxAllowedTools = 50,
    this.maxTasks = 200,
    this.maxRunHistoryPage = 200,
    this.maxTraceEntries = 200,
    this.maxAggregatedSkipped = 1000,
    this.run = const AutomationRunLimits(),
    this.maxTaskBytes = 65536,
    this.maxRunBytes = 131072,
    this.maxStreamBytes = 4 * 1024 * 1024,
  });

  final int maxNameCharacters;
  final int maxPromptCharacters;
  final int maxSessionLabelCharacters;
  final int maxAllowedTools;
  final int maxTasks;
  final int maxRunHistoryPage;
  final int maxTraceEntries;

  /// Upper bound for the aggregated count of missed periods recorded on one
  /// catch-up run. When the real number is larger, the record says "at least".
  final int maxAggregatedSkipped;

  final AutomationRunLimits run;

  final int maxTaskBytes;
  final int maxRunBytes;
  final int maxStreamBytes;

  static const envelopeHeadroomBytes = 8192;

  AutomationLimits validate() {
    _positive('maxNameCharacters', maxNameCharacters);
    _positive('maxPromptCharacters', maxPromptCharacters);
    _positive('maxSessionLabelCharacters', maxSessionLabelCharacters);
    _positive('maxAllowedTools', maxAllowedTools);
    _positive('maxTasks', maxTasks);
    _positive('maxRunHistoryPage', maxRunHistoryPage);
    _positive('maxTraceEntries', maxTraceEntries);
    _positive('maxAggregatedSkipped', maxAggregatedSkipped);
    _positive('maxTaskBytes', maxTaskBytes);
    _positive('maxRunBytes', maxRunBytes);
    _positive('maxStreamBytes', maxStreamBytes);
    run.validate();
    if (maxTaskBytes + envelopeHeadroomBytes > maxStreamBytes ||
        maxRunBytes + envelopeHeadroomBytes > maxStreamBytes) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Лимит потока автоматизации должен вмещать запись задачи или запуска '
        'вместе с конвертом JSONL.',
      );
    }
    return this;
  }
}

void _positive(String name, int value) {
  if (value <= 0) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Лимит "$name" должен быть положительным.',
    );
  }
}
