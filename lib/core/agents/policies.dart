import '../llm/errors.dart';
import '../llm/generation.dart';
import '../llm/json.dart';
import 'errors.dart';

enum ToolPermission { allow, deny, ask }

final class AgentRunLimits {
  AgentRunLimits({
    this.maxModelTurns,
    this.maxToolCalls,
    this.maxDuration,
    this.maxOutputTokensPerTurn,
  }) {
    _assertPositive('maxModelTurns', maxModelTurns);
    if (maxToolCalls != null && maxToolCalls! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'maxToolCalls must be a non-negative integer.',
      );
    }
    if (maxDuration != null && maxDuration! <= Duration.zero) {
      throwAgent(
        AgentErrorKind.configuration,
        'maxDuration must be a positive duration.',
      );
    }
    _assertPositive('maxOutputTokensPerTurn', maxOutputTokensPerTurn);
  }

  factory AgentRunLimits.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final micros = optionalNonNegativeInt(map, 'maxDurationMicros');
    return AgentRunLimits(
      maxModelTurns: optionalNonNegativeInt(map, 'maxModelTurns') == null
          ? null
          : _requirePositiveJson(map, 'maxModelTurns'),
      maxToolCalls: optionalNonNegativeInt(map, 'maxToolCalls'),
      maxDuration: micros == null ? null : Duration(microseconds: micros),
      maxOutputTokensPerTurn:
          optionalNonNegativeInt(map, 'maxOutputTokensPerTurn') == null
          ? null
          : _requirePositiveJson(map, 'maxOutputTokensPerTurn'),
    );
  }

  static const jsonType = 'agent.run_limits';

  static final unlimited = AgentRunLimits();

  final int? maxModelTurns;
  final int? maxToolCalls;
  final Duration? maxDuration;
  final int? maxOutputTokensPerTurn;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{};
    if (maxModelTurns != null) {
      fields['maxModelTurns'] = maxModelTurns;
    }
    if (maxToolCalls != null) {
      fields['maxToolCalls'] = maxToolCalls;
    }
    if (maxDuration != null) {
      fields['maxDurationMicros'] = maxDuration!.inMicroseconds;
    }
    if (maxOutputTokensPerTurn != null) {
      fields['maxOutputTokensPerTurn'] = maxOutputTokensPerTurn;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentRunLimits &&
          other.maxModelTurns == maxModelTurns &&
          other.maxToolCalls == maxToolCalls &&
          other.maxDuration == maxDuration &&
          other.maxOutputTokensPerTurn == maxOutputTokensPerTurn;

  @override
  int get hashCode => Object.hash(
    maxModelTurns,
    maxToolCalls,
    maxDuration,
    maxOutputTokensPerTurn,
  );
}

final class AgentTokenBudget {
  AgentTokenBudget({this.inputTokens, this.outputTokens, this.totalTokens}) {
    _assertNonNegative('inputTokens', inputTokens);
    _assertNonNegative('outputTokens', outputTokens);
    _assertNonNegative('totalTokens', totalTokens);
  }

  factory AgentTokenBudget.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentTokenBudget(
      inputTokens: optionalNonNegativeInt(map, 'inputTokens'),
      outputTokens: optionalNonNegativeInt(map, 'outputTokens'),
      totalTokens: optionalNonNegativeInt(map, 'totalTokens'),
    );
  }

  static const jsonType = 'agent.token_budget';

  static final unlimited = AgentTokenBudget();

  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{};
    if (inputTokens != null) {
      fields['inputTokens'] = inputTokens;
    }
    if (outputTokens != null) {
      fields['outputTokens'] = outputTokens;
    }
    if (totalTokens != null) {
      fields['totalTokens'] = totalTokens;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTokenBudget &&
          other.inputTokens == inputTokens &&
          other.outputTokens == outputTokens &&
          other.totalTokens == totalTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens, totalTokens);
}

final class AgentLivenessPolicy {
  AgentLivenessPolicy({this.idleTimeout = defaultIdleTimeout}) {
    if (idleTimeout != null && idleTimeout! <= Duration.zero) {
      throwAgent(
        AgentErrorKind.configuration,
        'Idle timeout must be a positive duration when enabled.',
      );
    }
  }

  factory AgentLivenessPolicy.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    if (!map.containsKey('idleTimeoutMicros')) {
      return AgentLivenessPolicy();
    }
    final micros = optionalNonNegativeInt(map, 'idleTimeoutMicros');
    return AgentLivenessPolicy(
      idleTimeout: micros == null ? null : Duration(microseconds: micros),
    );
  }

  static const jsonType = 'agent.liveness_policy';

  static const defaultIdleTimeout = Duration(minutes: 10);

  static final defaults = AgentLivenessPolicy();

  static final disabled = AgentLivenessPolicy(idleTimeout: null);

  /// `null` disables the idle watchdog.
  final Duration? idleTimeout;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'idleTimeoutMicros': idleTimeout?.inMicroseconds},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentLivenessPolicy && other.idleTimeout == idleTimeout;

  @override
  int get hashCode => idleTimeout.hashCode;
}

final class AgentNoProgressPolicy {
  AgentNoProgressPolicy({this.warningThreshold = 5, this.stopThreshold = 10}) {
    if (warningThreshold <= 0 || stopThreshold <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'No-progress thresholds must be positive.',
      );
    }
    if (warningThreshold >= stopThreshold) {
      throwAgent(
        AgentErrorKind.configuration,
        'No-progress warning threshold must be less than the stop threshold.',
      );
    }
  }

  factory AgentNoProgressPolicy.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentNoProgressPolicy(
      warningThreshold: map.containsKey('warningThreshold')
          ? requirePositiveInt(map, 'warningThreshold')
          : 5,
      stopThreshold: map.containsKey('stopThreshold')
          ? requirePositiveInt(map, 'stopThreshold')
          : 10,
    );
  }

  static const jsonType = 'agent.no_progress_policy';

  static final defaults = AgentNoProgressPolicy();

  final int warningThreshold;
  final int stopThreshold;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'warningThreshold': warningThreshold,
      'stopThreshold': stopThreshold,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentNoProgressPolicy &&
          other.warningThreshold == warningThreshold &&
          other.stopThreshold == stopThreshold;

  @override
  int get hashCode => Object.hash(warningThreshold, stopThreshold);
}

final class QuotaOverride<T> {
  const QuotaOverride.value(this.value) : explicitUnlimited = false;

  const QuotaOverride.unlimited() : value = null, explicitUnlimited = true;

  final T? value;
  final bool explicitUnlimited;
}

final class AgentPersistencePolicy {
  AgentPersistencePolicy({
    this.cancellationGracePeriod = defaultCancellationGracePeriod,
  }) {
    if (cancellationGracePeriod <= Duration.zero) {
      throwAgent(
        AgentErrorKind.configuration,
        'Persistence cancellation grace period must be a positive duration.',
      );
    }
  }

  static const defaultCancellationGracePeriod = Duration(seconds: 5);

  static final defaults = AgentPersistencePolicy();

  final Duration cancellationGracePeriod;
}

final class AgentRuntimeProfile {
  AgentRuntimeProfile({
    AgentRunLimits? limits,
    AgentTokenBudget? budget,
    AgentLivenessPolicy? liveness,
    AgentNoProgressPolicy? noProgress,
  }) : limits = limits ?? AgentRunLimits.unlimited,
       budget = budget ?? AgentTokenBudget.unlimited,
       liveness = liveness ?? AgentLivenessPolicy.defaults,
       noProgress = noProgress ?? AgentNoProgressPolicy.defaults;

  static final defaults = AgentRuntimeProfile();

  final AgentRunLimits limits;
  final AgentTokenBudget budget;
  final AgentLivenessPolicy liveness;
  final AgentNoProgressPolicy noProgress;
}

final class AgentReasoningOverride {
  AgentReasoningOverride({required this.mode, required this.effort}) {
    if (mode == ReasoningMode.disabled &&
        effort != ReasoningEffort.modelDefault) {
      throwAgent(
        AgentErrorKind.configuration,
        'Disabled reasoning cannot carry an explicit effort.',
      );
    }
  }

  final ReasoningMode mode;
  final ReasoningEffort effort;
}

final class AgentRunOptions {
  AgentRunOptions({
    this.maxModelTurns,
    this.maxToolCalls,
    this.maxDuration,
    this.maxOutputTokensPerTurn,
    this.inputTokenBudget,
    this.outputTokenBudget,
    this.totalTokenBudget,
    this.idleTimeout,
    this.noProgressWarning,
    this.noProgressStop,
    this.reasoning,
    this.typedInput,
  }) {
    _validatePositiveOverride('maxModelTurns', maxModelTurns);
    _validateNonNegativeOverride('maxToolCalls', maxToolCalls);
    _validateDurationOverride('maxDuration', maxDuration);
    _validatePositiveOverride('maxOutputTokensPerTurn', maxOutputTokensPerTurn);
    _validateNonNegativeOverride('inputTokenBudget', inputTokenBudget);
    _validateNonNegativeOverride('outputTokenBudget', outputTokenBudget);
    _validateNonNegativeOverride('totalTokenBudget', totalTokenBudget);
    _validateDurationOverride('idleTimeout', idleTimeout);
    _validatePositiveOverride('noProgressWarning', noProgressWarning);
    _validatePositiveOverride('noProgressStop', noProgressStop);
    final warning = noProgressWarning?.value;
    final stop = noProgressStop?.value;
    if (warning != null && stop != null && warning >= stop) {
      throwAgent(
        AgentErrorKind.configuration,
        'No-progress warning threshold must be less than the stop threshold.',
      );
    }
  }

  final QuotaOverride<int>? maxModelTurns;
  final QuotaOverride<int>? maxToolCalls;
  final QuotaOverride<Duration>? maxDuration;
  final QuotaOverride<int>? maxOutputTokensPerTurn;
  final QuotaOverride<int>? inputTokenBudget;
  final QuotaOverride<int>? outputTokenBudget;
  final QuotaOverride<int>? totalTokenBudget;
  final QuotaOverride<Duration>? idleTimeout;
  final QuotaOverride<int>? noProgressWarning;
  final QuotaOverride<int>? noProgressStop;
  final AgentReasoningOverride? reasoning;
  final Object? typedInput;
}

final class ResolvedRunGuards {
  ResolvedRunGuards({
    required this.maxModelTurns,
    required this.maxToolCalls,
    required this.maxDuration,
    required this.maxOutputTokensPerTurn,
    required this.inputTokenBudget,
    required this.outputTokenBudget,
    required this.totalTokenBudget,
    required this.idleTimeout,
    required this.noProgress,
  });

  final int? maxModelTurns;
  final int? maxToolCalls;
  final Duration? maxDuration;
  final int? maxOutputTokensPerTurn;
  final int? inputTokenBudget;
  final int? outputTokenBudget;
  final int? totalTokenBudget;
  final Duration? idleTimeout;
  final AgentNoProgressPolicy noProgress;
}

T? resolveQuota<T>(QuotaOverride<T>? run, T? definition, T? profile) {
  return resolveSpecified(
    run: run,
    definitionSpecified: definition != null,
    definitionValue: definition,
    profileValue: profile,
  );
}

T? resolveSpecified<T>({
  required QuotaOverride<T>? run,
  required bool definitionSpecified,
  required T? definitionValue,
  required T? profileValue,
}) {
  if (run != null) {
    return run.value;
  }
  if (definitionSpecified) {
    return definitionValue;
  }
  return profileValue;
}

void _validatePositiveOverride(String name, QuotaOverride<int>? override) {
  if (override == null || override.explicitUnlimited) {
    return;
  }
  _assertPositive(name, override.value);
}

void _validateNonNegativeOverride(String name, QuotaOverride<int>? override) {
  if (override == null || override.explicitUnlimited) {
    return;
  }
  _assertNonNegative(name, override.value);
}

void _validateDurationOverride(String name, QuotaOverride<Duration>? override) {
  if (override == null || override.explicitUnlimited) {
    return;
  }
  final value = override.value;
  if (value != null && value <= Duration.zero) {
    throwAgent(
      AgentErrorKind.configuration,
      '$name must be a positive duration.',
    );
  }
}

void _assertPositive(String name, int? value) {
  if (value != null && value <= 0) {
    throwAgent(
      AgentErrorKind.configuration,
      '$name must be a positive integer.',
    );
  }
}

void _assertNonNegative(String name, int? value) {
  if (value != null && value < 0) {
    throwAgent(
      AgentErrorKind.configuration,
      '$name must be a non-negative integer.',
    );
  }
}

int _requirePositiveJson(Map<String, Object?> map, String key) {
  final value = requireInt(map, key);
  if (value <= 0) {
    throwLlm(LlmErrorKind.protocol, 'Expected positive integer field "$key".');
  }
  return value;
}
