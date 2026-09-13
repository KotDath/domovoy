import '../llm/capabilities.dart';
import '../llm/errors.dart';
import '../llm/generation.dart';
import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/registry.dart';
import 'definition.dart';
import 'errors.dart';
import 'events.dart';
import 'ids.dart';

final class AgentSessionSelection {
  const AgentSessionSelection({
    required this.model,
    required this.reasoningMode,
    required this.reasoningEffort,
  });

  factory AgentSessionSelection.fromDefinition(AgentDefinition definition) {
    return AgentSessionSelection(
      model: definition.model,
      reasoningMode: definition.generation.reasoningMode,
      reasoningEffort: definition.generation.reasoningEffort,
    );
  }

  factory AgentSessionSelection.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentSessionSelection(
      model: ModelRef.fromJson(map['model']),
      reasoningMode: ReasoningMode.fromName(
        requireNonBlankString(map, 'reasoningMode'),
      ),
      reasoningEffort: ReasoningEffort.fromName(
        requireNonBlankString(map, 'reasoningEffort'),
      ),
    );
  }

  static const jsonType = 'agent.session_selection';

  final ModelRef model;
  final ReasoningMode reasoningMode;
  final ReasoningEffort reasoningEffort;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'model': model.toJson(),
      'reasoningMode': reasoningMode.name,
      'reasoningEffort': reasoningEffort.name,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSessionSelection &&
          other.model == model &&
          other.reasoningMode == reasoningMode &&
          other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(model, reasoningMode, reasoningEffort);

  @override
  String toString() =>
      'AgentSessionSelection($model, ${reasoningMode.name}, '
      '${reasoningEffort.name})';
}

enum AgentSessionOperationKind { run, compaction, selection, close }

final class AgentModelSwitchFitInput {
  const AgentModelSwitchFitInput({
    required this.model,
    required this.maxOutputTokens,
  });

  final LlmModel model;
  final int? maxOutputTokens;
}

final class AgentModelSwitchFit {
  const AgentModelSwitchFit({
    required this.contextBound,
    required this.outputReserve,
    required this.headroom,
    required this.fitThreshold,
    required this.compactionTarget,
    required this.policyId,
    required this.policyVersion,
  });

  final int contextBound;
  final int outputReserve;
  final int headroom;
  final int fitThreshold;
  final int compactionTarget;
  final String policyId;
  final int policyVersion;

  Map<String, Object?> get metadata => <String, Object?>{
    'contextBound': contextBound,
    'outputReserve': outputReserve,
    'headroom': headroom,
    'fitThreshold': fitThreshold,
    'postCompactionTarget': compactionTarget,
  };
}

abstract interface class AgentModelSwitchFitPolicy {
  String get id;

  int get version;

  AgentModelSwitchFit evaluate(AgentModelSwitchFitInput input);
}

/// OpenCode-inspired target fit policy used independently from the ordinary
/// pre-request trigger so callers can replace either decision seam.
final class OpenCodeAgentModelSwitchFitPolicy
    implements AgentModelSwitchFitPolicy {
  OpenCodeAgentModelSwitchFitPolicy({
    this.outputReserve,
    this.minimumOutputReserve = 2048,
    this.outputReserveFraction = 0.10,
    this.headroom,
    this.minimumHeadroom = 1024,
    this.headroomFraction = 0.05,
    this.postCompactionRatio = 0.70,
  }) {
    if (outputReserve != null && outputReserve! <= 0 ||
        minimumOutputReserve <= 0 ||
        !outputReserveFraction.isFinite ||
        outputReserveFraction <= 0 ||
        headroom != null && headroom! <= 0 ||
        minimumHeadroom <= 0 ||
        !headroomFraction.isFinite ||
        headroomFraction <= 0 ||
        !postCompactionRatio.isFinite ||
        postCompactionRatio <= 0 ||
        postCompactionRatio >= 1) {
      throwAgent(
        AgentErrorKind.configuration,
        'Model-switch fit policy configuration is invalid.',
      );
    }
  }

  @override
  String get id => 'opencode-model-switch-fit';

  @override
  int get version => 1;

  final int? outputReserve;
  final int minimumOutputReserve;
  final double outputReserveFraction;
  final int? headroom;
  final int minimumHeadroom;
  final double headroomFraction;
  final double postCompactionRatio;

  @override
  AgentModelSwitchFit evaluate(AgentModelSwitchFitInput input) {
    final model = input.model;
    final requestedOutput = input.maxOutputTokens;
    if (requestedOutput != null && requestedOutput > model.outputBound) {
      throwAgent(
        AgentErrorKind.configuration,
        'Requested output exceeds the target model bound.',
      );
    }
    final defaultOutput = _min(
      model.outputBound,
      _max(
        minimumOutputReserve,
        (model.contextBound * outputReserveFraction).ceil(),
      ),
    );
    final resolvedOutput = requestedOutput ?? outputReserve ?? defaultOutput;
    if (resolvedOutput <= 0 || resolvedOutput > model.outputBound) {
      throwAgent(
        AgentErrorKind.configuration,
        'Model-switch output reserve is outside the target model bound.',
      );
    }
    final resolvedHeadroom =
        headroom ??
        _max(minimumHeadroom, (model.contextBound * headroomFraction).ceil());
    final threshold = model.contextBound - resolvedOutput - resolvedHeadroom;
    if (threshold <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Target model reserves leave no usable context.',
      );
    }
    return AgentModelSwitchFit(
      contextBound: model.contextBound,
      outputReserve: resolvedOutput,
      headroom: resolvedHeadroom,
      fitThreshold: threshold,
      compactionTarget: (threshold * postCompactionRatio).floor(),
      policyId: id,
      policyVersion: version,
    );
  }
}

abstract interface class AgentSessionSelectionOperation {
  AgentSelectionOperationId get id;

  Stream<AgentSessionSelectionEvent> get events;

  Future<AgentSessionSelectionResult> get result;

  Future<void> cancel();
}

sealed class AgentSessionSelectionEvent {
  const AgentSessionSelectionEvent({
    required this.operationId,
    required this.sessionId,
    required this.previous,
    required this.requested,
  });

  final AgentSelectionOperationId operationId;
  final AgentSessionId sessionId;
  final AgentSessionSelection previous;
  final AgentSessionSelection requested;

  bool get isTerminal =>
      this is AgentSessionSelectionSucceeded ||
      this is AgentSessionSelectionFailed ||
      this is AgentSessionSelectionCancelled;
}

final class AgentSessionSelectionStarted extends AgentSessionSelectionEvent {
  const AgentSessionSelectionStarted({
    required super.operationId,
    required super.sessionId,
    required super.previous,
    required super.requested,
    this.beforeEstimate,
    this.fitThreshold,
    this.compactionTarget,
  });

  final int? beforeEstimate;
  final int? fitThreshold;
  final int? compactionTarget;
}

final class AgentSessionSelectionCompaction extends AgentSessionSelectionEvent {
  const AgentSessionSelectionCompaction({
    required super.operationId,
    required super.sessionId,
    required super.previous,
    required super.requested,
    required this.compaction,
  });

  final AgentCompactionEvent compaction;
}

final class AgentSessionSelectionSucceeded extends AgentSessionSelectionEvent {
  const AgentSessionSelectionSucceeded({
    required super.operationId,
    required super.sessionId,
    required super.previous,
    required super.requested,
    required this.compacted,
  });

  final bool compacted;
}

final class AgentSessionSelectionFailed extends AgentSessionSelectionEvent {
  const AgentSessionSelectionFailed({
    required super.operationId,
    required super.sessionId,
    required super.previous,
    required super.requested,
    required this.error,
  });

  final AgentError error;
}

final class AgentSessionSelectionCancelled extends AgentSessionSelectionEvent {
  const AgentSessionSelectionCancelled({
    required super.operationId,
    required super.sessionId,
    required super.previous,
    required super.requested,
  });
}

enum AgentSessionSelectionStatus { changed, unchanged, busy, error }

final class AgentSessionSelectionResult {
  const AgentSessionSelectionResult._({
    required this.status,
    this.selection,
    this.activeOperation,
    this.error,
  });

  const AgentSessionSelectionResult.changed(AgentSessionSelection selection)
    : this._(status: AgentSessionSelectionStatus.changed, selection: selection);

  const AgentSessionSelectionResult.unchanged(AgentSessionSelection selection)
    : this._(
        status: AgentSessionSelectionStatus.unchanged,
        selection: selection,
      );

  const AgentSessionSelectionResult.busy(
    AgentSessionOperationKind activeOperation,
  ) : this._(
        status: AgentSessionSelectionStatus.busy,
        activeOperation: activeOperation,
      );

  const AgentSessionSelectionResult.error(AgentError error)
    : this._(status: AgentSessionSelectionStatus.error, error: error);

  final AgentSessionSelectionStatus status;
  final AgentSessionSelection? selection;
  final AgentSessionOperationKind? activeOperation;
  final AgentError? error;
}

LlmModel validateAgentSessionSelection(
  AgentSessionSelection selection,
  LlmProviderRegistry registry,
) {
  late final LlmModel model;
  try {
    model = registry.requireModel(selection.model);
  } on LlmException catch (error) {
    throwAgent(AgentErrorKind.configuration, error.error.message);
  }
  final capabilities = model.capabilities;
  switch (capabilities.reasoning) {
    case ModelReasoningCapability.unsupported:
      if (selection.reasoningMode != ReasoningMode.disabled ||
          selection.reasoningEffort != ReasoningEffort.modelDefault) {
        throwAgent(
          AgentErrorKind.configuration,
          'The selected model does not support reasoning.',
        );
      }
    case ModelReasoningCapability.required:
      if (selection.reasoningMode != ReasoningMode.enabled) {
        throwAgent(
          AgentErrorKind.configuration,
          'The selected model requires reasoning.',
        );
      }
      _validateEffort(selection, capabilities);
    case ModelReasoningCapability.optional:
      if (selection.reasoningMode == ReasoningMode.disabled &&
          selection.reasoningEffort != ReasoningEffort.modelDefault) {
        throwAgent(
          AgentErrorKind.configuration,
          'Disabled reasoning cannot use an explicit effort.',
        );
      }
      if (selection.reasoningMode == ReasoningMode.enabled) {
        _validateEffort(selection, capabilities);
      }
  }
  return model;
}

void _validateEffort(
  AgentSessionSelection selection,
  ModelCapabilities capabilities,
) {
  final effort = selection.reasoningEffort;
  if (effort.isExplicit && !capabilities.selectableEfforts.contains(effort)) {
    throwAgent(
      AgentErrorKind.configuration,
      'The selected reasoning effort is not supported by this model.',
    );
  }
}

int _min(int left, int right) => left < right ? left : right;

int _max(int left, int right) => left > right ? left : right;
