import 'dart:math';

import 'errors.dart';
import 'json.dart';

final RegExp _taskIdPattern = RegExp(r'^atm_[a-z0-9]{16,64}$');
final RegExp _runIdPattern = RegExp(r'^ran_[a-z0-9]{16,64}$');

/// Normalized identity of one automation task.
///
/// Generated identities are unpredictable (`atm_` plus 16 random bytes), so a
/// guessed or duplicated ID can never select another task's schedule or
/// broaden a scheduled run's rights.
final class AutomationTaskId {
  AutomationTaskId(String raw) : value = _normalize(raw, _taskIdPattern, 'atm');

  factory AutomationTaskId.fromJson(Object? json) {
    if (json is! String) {
      throwAutomation(AutomationErrorKind.invalidInput, 'taskId must be text.');
    }
    return AutomationTaskId(json);
  }

  /// Parses [raw] or returns null when it is not a task identity.
  static AutomationTaskId? tryParse(String raw) {
    try {
      return AutomationTaskId(raw);
    } on AutomationException {
      return null;
    }
  }

  /// Creates a fresh unpredictable identity from [random].
  static AutomationTaskId generate(Random random) =>
      AutomationTaskId('atm_${_hex16(random)}');

  final String value;

  /// Stable local reference used by tool results and the tasks UI.
  String get taskRef => 'domovoy://automation/task/$value';

  Map<String, Object?> toJson() =>
      freezeJsonMap(<String, Object?>{'taskId': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationTaskId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Normalized identity of one automation run.
final class AutomationRunId {
  AutomationRunId(String raw) : value = _normalize(raw, _runIdPattern, 'ran');

  factory AutomationRunId.fromJson(Object? json) {
    if (json is! String) {
      throwAutomation(AutomationErrorKind.invalidInput, 'runId must be text.');
    }
    return AutomationRunId(json);
  }

  static AutomationRunId? tryParse(String raw) {
    try {
      return AutomationRunId(raw);
    } on AutomationException {
      return null;
    }
  }

  static AutomationRunId generate(Random random) =>
      AutomationRunId('ran_${_hex16(random)}');

  final String value;

  String get runRef => 'domovoy://automation/run/$value';

  Map<String, Object?> toJson() =>
      freezeJsonMap(<String, Object?>{'runId': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationRunId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Source of task and run identities for one scheduler instance.
abstract interface class AutomationIdGenerator {
  AutomationTaskId nextTaskId();

  AutomationRunId nextRunId();
}

/// Unpredictable default generator backed by a secure random source.
final class RandomAutomationIdGenerator implements AutomationIdGenerator {
  RandomAutomationIdGenerator([Random? random])
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  AutomationTaskId nextTaskId() => AutomationTaskId.generate(_random);

  @override
  AutomationRunId nextRunId() => AutomationRunId.generate(_random);
}

String _normalize(String raw, RegExp pattern, String prefix) {
  final candidate = raw.trim();
  if (!pattern.hasMatch(candidate)) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      'Идентификатор должен выглядеть как ${prefix}_<hex>.',
    );
  }
  return candidate;
}

String _hex16(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
