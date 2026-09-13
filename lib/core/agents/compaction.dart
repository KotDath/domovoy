import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/capabilities.dart';
import '../llm/continuation.dart';
import '../llm/errors.dart';
import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/messages.dart';
import '../llm/request.dart';
import '../llm/usage.dart';
import 'errors.dart';
import 'ids.dart';
import 'schema.dart';
import 'token_accounting.dart';
import 'tools.dart';

enum AgentCompactionReason { preRequest, providerOverflow, modelSwitch, manual }

enum AgentCompactionDecisionKind { skip, compact }

enum AgentCompactionOutcome { compacted, noChange }

final class AgentContextEstimateInput {
  AgentContextEstimateInput({
    required LlmRequestSnapshot request,
    required this.cancellation,
  }) : request = LlmRequestSnapshot.fromJson(request.toJson());

  final LlmRequestSnapshot request;
  final CancellationToken cancellation;
}

final class AgentContextEstimate {
  AgentContextEstimate({
    required this.value,
    required String estimatorId,
    required this.estimatorVersion,
  }) : estimatorId = _nonBlank(estimatorId, 'Estimator id') {
    if (value < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Context estimate must be non-negative.',
      );
    }
    if (estimatorVersion <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Estimator version must be positive.',
      );
    }
  }

  final int value;
  final String estimatorId;
  final int estimatorVersion;
}

abstract interface class AgentContextEstimator {
  String get id;

  int get version;

  AgentContextEstimate estimate(AgentContextEstimateInput input);
}

final class Utf8FramingAgentContextEstimator implements AgentContextEstimator {
  const Utf8FramingAgentContextEstimator();

  static const defaultId = 'utf8-framing';
  static const defaultVersion = 1;
  static const requestFramingUnits = 16;

  @override
  String get id => defaultId;

  @override
  int get version => defaultVersion;

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) {
    if (input.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    final bytes = utf8
        .encode(canonicalJsonEncode(input.request.toJson()))
        .length;
    return AgentContextEstimate(
      value: ((bytes + 1) ~/ 2) + requestFramingUnits,
      estimatorId: id,
      estimatorVersion: version,
    );
  }
}

final class AgentCompactionDecision {
  AgentCompactionDecision._({
    required this.kind,
    required this.triggerId,
    required this.triggerVersion,
    required this.targetEstimate,
    required Map<String, Object?> metadata,
  }) : metadata = _sanitizedMetadata(metadata) {
    if ((triggerId == null) != (triggerVersion == null)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Trigger id and version must be supplied together.',
      );
    }
    if (triggerId != null) {
      _nonBlank(triggerId!, 'Trigger id');
      if (triggerVersion! <= 0) {
        throwAgent(
          AgentErrorKind.configuration,
          'Trigger version must be positive.',
        );
      }
    }
    if (targetEstimate != null && targetEstimate! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction target must be non-negative.',
      );
    }
    if (kind == AgentCompactionDecisionKind.skip && targetEstimate != null) {
      throwAgent(
        AgentErrorKind.configuration,
        'A skip decision cannot carry a target.',
      );
    }
  }

  factory AgentCompactionDecision.skip({
    required String triggerId,
    required int triggerVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => AgentCompactionDecision._(
    kind: AgentCompactionDecisionKind.skip,
    triggerId: triggerId,
    triggerVersion: triggerVersion,
    targetEstimate: null,
    metadata: metadata,
  );

  factory AgentCompactionDecision.compact({
    required String triggerId,
    required int triggerVersion,
    int? targetEstimate,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => AgentCompactionDecision._(
    kind: AgentCompactionDecisionKind.compact,
    triggerId: triggerId,
    triggerVersion: triggerVersion,
    targetEstimate: targetEstimate,
    metadata: metadata,
  );

  factory AgentCompactionDecision.manual() => AgentCompactionDecision._(
    kind: AgentCompactionDecisionKind.compact,
    triggerId: null,
    triggerVersion: null,
    targetEstimate: null,
    metadata: const <String, Object?>{},
  );

  final AgentCompactionDecisionKind kind;
  final String? triggerId;
  final int? triggerVersion;
  final int? targetEstimate;
  final Map<String, Object?> metadata;
}

abstract interface class AgentCompactionTrigger {
  AgentCompactionDecision evaluate(AgentCompactionContext context);
}

final class OpenCodeCompactionTrigger implements AgentCompactionTrigger {
  OpenCodeCompactionTrigger({
    this.outputReserve,
    this.minimumOutputReserve = 2048,
    this.outputReserveFraction = 0.10,
    this.headroom,
    this.minimumHeadroom = 1024,
    this.headroomFraction = 0.05,
    this.postCompactionRatio = 0.70,
  }) {
    if (outputReserve != null && outputReserve! <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction output reserve must be positive.',
      );
    }
    if (minimumOutputReserve <= 0 ||
        outputReserveFraction <= 0 ||
        !outputReserveFraction.isFinite) {
      throwAgent(
        AgentErrorKind.configuration,
        'Default compaction output reserve configuration is invalid.',
      );
    }
    if (headroom != null && headroom! <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction headroom must be positive.',
      );
    }
    if (minimumHeadroom <= 0 ||
        headroomFraction <= 0 ||
        !headroomFraction.isFinite) {
      throwAgent(
        AgentErrorKind.configuration,
        'Default compaction headroom configuration is invalid.',
      );
    }
    if (postCompactionRatio <= 0 ||
        postCompactionRatio >= 1 ||
        !postCompactionRatio.isFinite) {
      throwAgent(
        AgentErrorKind.configuration,
        'Post-compaction ratio must be between zero and one.',
      );
    }
  }

  static const id = 'opencode-pressure';
  static const version = 1;

  final int? outputReserve;
  final int minimumOutputReserve;
  final double outputReserveFraction;
  final int? headroom;
  final int minimumHeadroom;
  final double headroomFraction;
  final double postCompactionRatio;

  @override
  AgentCompactionDecision evaluate(AgentCompactionContext context) {
    if (context.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    final contextBound = context.selectedModel.contextBound;
    final explicitOutputCap = context.request.generation.maxOutputTokens;
    final defaultOutputReserve = _min(
      context.selectedModel.outputBound,
      _max(
        minimumOutputReserve,
        _ceilScaled(contextBound, outputReserveFraction),
      ),
    );
    final resolvedOutputReserve =
        explicitOutputCap ?? outputReserve ?? defaultOutputReserve;
    final resolvedHeadroom =
        headroom ??
        _max(minimumHeadroom, _ceilScaled(contextBound, headroomFraction));
    final pressureThreshold =
        contextBound - resolvedOutputReserve - resolvedHeadroom;
    if (pressureThreshold < 0) {
      throwAgent(
        AgentErrorKind.compaction,
        'Model context reserves leave no valid compaction target.',
      );
    }
    final target = (pressureThreshold * postCompactionRatio).floor();
    final providerUsage = context.providerContextUsage;
    final metadata = <String, Object?>{
      'contextBound': contextBound,
      'outputReserve': resolvedOutputReserve,
      'headroom': resolvedHeadroom,
      'pressureThreshold': pressureThreshold,
      'postCompactionTarget': target,
      'providerContextUsage': providerUsage,
      'providerContextSource': providerUsage == null
          ? 'unavailable'
          : 'provider',
    };
    if (context.reason == AgentCompactionReason.providerOverflow) {
      return AgentCompactionDecision.compact(
        triggerId: id,
        triggerVersion: version,
        targetEstimate: target,
        metadata: metadata,
      );
    }
    if (providerUsage != null && providerUsage > pressureThreshold) {
      return AgentCompactionDecision.compact(
        triggerId: id,
        triggerVersion: version,
        targetEstimate: target,
        metadata: metadata,
      );
    }
    return AgentCompactionDecision.skip(
      triggerId: id,
      triggerVersion: version,
      metadata: metadata,
    );
  }
}

final class AgentInteractionGroup {
  AgentInteractionGroup({
    required String id,
    required this.startMessageIndex,
    required this.endMessageIndex,
    required List<LlmMessage> messages,
  }) : id = _nonBlank(id, 'Interaction group id'),
       messages = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(messages),
       ) {
    if (startMessageIndex < 0 || endMessageIndex <= startMessageIndex) {
      throwAgent(
        AgentErrorKind.configuration,
        'Interaction group range is invalid.',
      );
    }
    if (this.messages.length != endMessageIndex - startMessageIndex) {
      throwAgent(
        AgentErrorKind.configuration,
        'Interaction group range does not match its messages.',
      );
    }
  }

  final String id;
  final int startMessageIndex;
  final int endMessageIndex;
  final List<LlmMessage> messages;

  String get suffixBoundaryId => 'group:$id';
}

List<AgentInteractionGroup> partitionAgentInteractionGroups({
  required List<LlmMessage> messages,
  required int startMessageIndex,
}) {
  if (startMessageIndex < 0 || startMessageIndex > messages.length) {
    throwAgent(
      AgentErrorKind.configuration,
      'Interaction history start is outside the transcript.',
    );
  }
  final groups = <AgentInteractionGroup>[];
  var cursor = startMessageIndex;
  while (cursor < messages.length) {
    if (messages[cursor].role != LlmMessageRole.user) {
      throwAgent(
        AgentErrorKind.configuration,
        'Each compactable interaction must begin with a user message.',
      );
    }
    final start = cursor++;
    while (cursor < messages.length &&
        messages[cursor].role != LlmMessageRole.user) {
      final message = messages[cursor];
      if (message.role == LlmMessageRole.tool) {
        throwAgent(
          AgentErrorKind.configuration,
          'Tool results must follow their assistant tool call.',
        );
      }
      final calls = message.parts.whereType<LlmToolCallPart>().toList();
      cursor += 1;
      if (calls.isEmpty) {
        continue;
      }
      final expected = <String>{};
      for (final call in calls) {
        if (!expected.add(call.callId.value)) {
          throwAgent(
            AgentErrorKind.configuration,
            'An interaction contains duplicate tool call identifiers.',
          );
        }
      }
      final results = <String>{};
      while (cursor < messages.length &&
          messages[cursor].role == LlmMessageRole.tool) {
        for (final part
            in messages[cursor].parts.whereType<LlmToolResultPart>()) {
          if (!expected.contains(part.callId.value) ||
              !results.add(part.callId.value)) {
            throwAgent(
              AgentErrorKind.configuration,
              'Tool results do not match the preceding assistant tool call.',
            );
          }
        }
        cursor += 1;
      }
      if (results.length != expected.length) {
        throwAgent(
          AgentErrorKind.configuration,
          'An assistant tool call is missing a complete result set.',
        );
      }
    }
    final end = cursor;
    groups.add(
      AgentInteractionGroup(
        id: '$start:$end',
        startMessageIndex: start,
        endMessageIndex: end,
        messages: messages.sublist(start, end),
      ),
    );
  }
  return List<AgentInteractionGroup>.unmodifiable(groups);
}

final class AgentCompactionState {
  AgentCompactionState({
    required this.generation,
    required this.generatedPrefixStart,
    required this.generatedPrefixCount,
    required this.reason,
    required this.triggerId,
    required this.triggerVersion,
    required String strategyId,
    required this.strategyVersion,
    required String estimatorId,
    required this.estimatorVersion,
    required this.removedMessageCount,
    required this.beforeEstimate,
    required this.afterEstimate,
    required Map<String, Object?> decisionMetadata,
    required this.updatedAtMicros,
  }) : strategyId = _nonBlank(strategyId, 'Strategy id'),
       estimatorId = _nonBlank(estimatorId, 'Estimator id'),
       decisionMetadata = _sanitizedMetadata(decisionMetadata) {
    if (generation <= 0 ||
        generatedPrefixStart < 0 ||
        generatedPrefixCount < 0 ||
        strategyVersion <= 0 ||
        estimatorVersion <= 0 ||
        removedMessageCount <= 0 ||
        beforeEstimate < 0 ||
        afterEstimate < 0 ||
        afterEstimate >= beforeEstimate ||
        updatedAtMicros < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction provenance is structurally invalid.',
      );
    }
    if ((triggerId == null) != (triggerVersion == null)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction trigger provenance is incomplete.',
      );
    }
    if (reason == AgentCompactionReason.manual && triggerId != null) {
      throwAgent(
        AgentErrorKind.configuration,
        'Manual compaction cannot carry trigger provenance.',
      );
    }
    if (reason != AgentCompactionReason.manual && triggerId == null) {
      throwAgent(
        AgentErrorKind.configuration,
        'Automatic compaction must carry trigger provenance.',
      );
    }
    if (triggerId != null) {
      _nonBlank(triggerId!, 'Trigger id');
      if (triggerVersion! <= 0) {
        throwAgent(
          AgentErrorKind.configuration,
          'Trigger version must be positive.',
        );
      }
    }
  }

  factory AgentCompactionState.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final reasonName = requireNonBlankString(map, 'reason');
    final reason = AgentCompactionReason.values
        .where((value) => value.name == reasonName)
        .firstOrNull;
    if (reason == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Unknown compaction reason "$reasonName".',
      );
    }
    final metadata = optionalJsonMap(map, 'decisionMetadata');
    return AgentCompactionState(
      generation: requirePositiveInt(map, 'generation'),
      generatedPrefixStart: _requireNonNegative(map, 'generatedPrefixStart'),
      generatedPrefixCount: _requireNonNegative(map, 'generatedPrefixCount'),
      reason: reason,
      triggerId: optionalString(map, 'triggerId'),
      triggerVersion: optionalNonNegativeInt(map, 'triggerVersion'),
      strategyId: requireNonBlankString(map, 'strategyId'),
      strategyVersion: requirePositiveInt(map, 'strategyVersion'),
      estimatorId: requireNonBlankString(map, 'estimatorId'),
      estimatorVersion: requirePositiveInt(map, 'estimatorVersion'),
      removedMessageCount: requirePositiveInt(map, 'removedMessageCount'),
      beforeEstimate: _requireNonNegative(map, 'beforeEstimate'),
      afterEstimate: _requireNonNegative(map, 'afterEstimate'),
      decisionMetadata: metadata ?? const <String, Object?>{},
      updatedAtMicros: _requireNonNegative(map, 'updatedAtMicros'),
    );
  }

  static const jsonType = 'agent.compaction_state';

  final int generation;
  final int generatedPrefixStart;
  final int generatedPrefixCount;
  final AgentCompactionReason reason;
  final String? triggerId;
  final int? triggerVersion;
  final String strategyId;
  final int strategyVersion;
  final String estimatorId;
  final int estimatorVersion;
  final int removedMessageCount;
  final int beforeEstimate;
  final int afterEstimate;
  final Map<String, Object?> decisionMetadata;
  final int updatedAtMicros;

  int get generatedPrefixEnd => generatedPrefixStart + generatedPrefixCount;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'generation': generation,
      'generatedPrefixStart': generatedPrefixStart,
      'generatedPrefixCount': generatedPrefixCount,
      'reason': reason.name,
      'strategyId': strategyId,
      'strategyVersion': strategyVersion,
      'estimatorId': estimatorId,
      'estimatorVersion': estimatorVersion,
      'removedMessageCount': removedMessageCount,
      'beforeEstimate': beforeEstimate,
      'afterEstimate': afterEstimate,
      'decisionMetadata': decisionMetadata,
      'updatedAtMicros': updatedAtMicros,
    };
    if (triggerId != null) {
      fields['triggerId'] = triggerId;
      fields['triggerVersion'] = triggerVersion;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentCompactionState &&
          other.generation == generation &&
          other.generatedPrefixStart == generatedPrefixStart &&
          other.generatedPrefixCount == generatedPrefixCount &&
          other.reason == reason &&
          other.triggerId == triggerId &&
          other.triggerVersion == triggerVersion &&
          other.strategyId == strategyId &&
          other.strategyVersion == strategyVersion &&
          other.estimatorId == estimatorId &&
          other.estimatorVersion == estimatorVersion &&
          other.removedMessageCount == removedMessageCount &&
          other.beforeEstimate == beforeEstimate &&
          other.afterEstimate == afterEstimate &&
          jsonEquals(other.decisionMetadata, decisionMetadata) &&
          other.updatedAtMicros == updatedAtMicros;

  @override
  int get hashCode => Object.hash(
    generation,
    generatedPrefixStart,
    generatedPrefixCount,
    reason,
    triggerId,
    triggerVersion,
    strategyId,
    strategyVersion,
    estimatorId,
    estimatorVersion,
    removedMessageCount,
    beforeEstimate,
    afterEstimate,
    jsonHash(decisionMetadata),
    updatedAtMicros,
  );
}

final class AgentCompactionContext {
  AgentCompactionContext({
    required this.operationId,
    required this.sessionId,
    this.runId,
    required this.reason,
    required LlmModel selectedModel,
    LlmModel? currentSessionModel,
    required LlmRequestSnapshot request,
    required List<LlmMessage> protectedSeed,
    required List<LlmMessage> generatedPrefix,
    required List<AgentInteractionGroup> interactionGroups,
    required List<LlmContinuationEntry> continuationEntries,
    List<AgentTranscriptMessageId?>? messageIds,
    required this.priorState,
    required this.currentEstimate,
    required this.targetEstimate,
    this.providerContextUsage,
    required this.cancellation,
  }) : selectedModel = LlmModel.fromJson(selectedModel.toJson()),
       currentSessionModel = LlmModel.fromJson(
         (currentSessionModel ?? selectedModel).toJson(),
       ),
       request = LlmRequestSnapshot.fromJson(request.toJson()),
       protectedSeed = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(protectedSeed),
       ),
       generatedPrefix = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(generatedPrefix),
       ),
       interactionGroups = List<AgentInteractionGroup>.unmodifiable(
         interactionGroups.map(
           (group) => AgentInteractionGroup(
             id: group.id,
             startMessageIndex: group.startMessageIndex,
             endMessageIndex: group.endMessageIndex,
             messages: group.messages,
           ),
         ),
       ),
       continuationEntries = List<LlmContinuationEntry>.unmodifiable(
         continuationEntries.map(
           (entry) => LlmContinuationEntry.fromJson(entry.toJson()),
         ),
       ),
       messageIds = List<AgentTranscriptMessageId?>.unmodifiable(
         messageIds ??
             List<AgentTranscriptMessageId?>.filled(
               request.context.messages.length,
               null,
             ),
       ) {
    if (targetEstimate != null && targetEstimate! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction target must be non-negative.',
      );
    }
    if (providerContextUsage != null && providerContextUsage! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Provider context usage must be non-negative.',
      );
    }
    if (this.messageIds.length != this.request.context.messages.length) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction message identities do not align with the request.',
      );
    }
    _validateContextShape(this);
  }

  final AgentCompactionOperationId operationId;
  final AgentSessionId sessionId;
  final RunId? runId;
  final AgentCompactionReason reason;

  /// The model that owns the live session before this compaction starts.
  ///
  /// This differs from [selectedModel] only while preparing a model switch.
  final LlmModel currentSessionModel;
  final LlmModel selectedModel;
  final LlmRequestSnapshot request;
  final List<LlmMessage> protectedSeed;
  final List<LlmMessage> generatedPrefix;
  final List<AgentInteractionGroup> interactionGroups;
  final List<LlmContinuationEntry> continuationEntries;
  final List<AgentTranscriptMessageId?> messageIds;
  final AgentCompactionState? priorState;
  final AgentContextEstimate currentEstimate;
  final int? targetEstimate;

  /// Usable provider-reported context usage from the latest completed physical
  /// LLM invocation, or `null` when that invocation supplied no usable
  /// provider measurement. Estimation never substitutes for this value.
  final int? providerContextUsage;

  final CancellationToken cancellation;

  String get endBoundaryId => 'end:${request.context.messages.length}';

  List<String> get legalSuffixBoundaryIds => List<String>.unmodifiable(<String>[
    ...interactionGroups.map((group) => group.suffixBoundaryId),
    endBoundaryId,
  ]);

  AgentCompactionContext withTarget(int? target) => AgentCompactionContext(
    operationId: operationId,
    sessionId: sessionId,
    runId: runId,
    reason: reason,
    selectedModel: selectedModel,
    currentSessionModel: currentSessionModel,
    request: request,
    protectedSeed: protectedSeed,
    generatedPrefix: generatedPrefix,
    interactionGroups: interactionGroups,
    continuationEntries: continuationEntries,
    messageIds: messageIds,
    priorState: priorState,
    currentEstimate: currentEstimate,
    targetEstimate: target,
    providerContextUsage: providerContextUsage,
    cancellation: cancellation,
  );
}

/// One provider invocation performed by a compaction strategy.
final class AgentCompactionInvocationReport {
  AgentCompactionInvocationReport({
    required this.invocationOrdinal,
    required this.model,
    required this.outcome,
    required this.usage,
  }) {
    if (invocationOrdinal < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction invocation ordinal must be non-negative.',
      );
    }
    if (outcome == AgentModelInvocationOutcome.overflow ||
        outcome == AgentModelInvocationOutcome.stopped) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction invocation outcome is invalid.',
      );
    }
  }

  final int invocationOrdinal;
  final ModelRef model;
  final AgentModelInvocationOutcome outcome;
  final LlmUsage usage;
}

sealed class AgentCompactionStrategyResult {
  AgentCompactionStrategyResult({
    required String strategyId,
    required this.strategyVersion,
    required Map<String, Object?> metadata,
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) : strategyId = _nonBlank(strategyId, 'Strategy id'),
       metadata = _sanitizedMetadata(metadata),
       reports = _validatedInvocationReports(reports) {
    if (strategyVersion <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Strategy version must be positive.',
      );
    }
  }

  final String strategyId;
  final int strategyVersion;
  final Map<String, Object?> metadata;
  final List<AgentCompactionInvocationReport> reports;

  /// Coarse compatibility projection. Per-invocation [reports] are authoritative.
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);
}

final class AgentCompactionNoChange extends AgentCompactionStrategyResult {
  AgentCompactionNoChange({
    required super.strategyId,
    required super.strategyVersion,
    super.metadata = const <String, Object?>{},
    super.reports,
  });
}

final class AgentCompactionCandidate extends AgentCompactionStrategyResult {
  AgentCompactionCandidate({
    required super.strategyId,
    required super.strategyVersion,
    required String retainedSuffixBoundaryId,
    List<LlmMessage> generatedPrefix = const <LlmMessage>[],
    List<AgentTranscriptMessageId?>? generatedPrefixMessageIds,
    super.metadata = const <String, Object?>{},
    super.reports,
  }) : retainedSuffixBoundaryId = _nonBlank(
         retainedSuffixBoundaryId,
         'Retained suffix boundary id',
       ),
       generatedPrefix = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(generatedPrefix),
       ),
       generatedPrefixMessageIds = List<AgentTranscriptMessageId?>.unmodifiable(
         generatedPrefixMessageIds ??
             List<AgentTranscriptMessageId?>.filled(
               generatedPrefix.length,
               null,
             ),
       ) {
    if (this.generatedPrefixMessageIds.length != this.generatedPrefix.length) {
      throwAgent(
        AgentErrorKind.configuration,
        'Generated compaction message identities do not align.',
      );
    }
  }

  final String retainedSuffixBoundaryId;
  final List<LlmMessage> generatedPrefix;
  final List<AgentTranscriptMessageId?> generatedPrefixMessageIds;
}

abstract interface class AgentHistoryCompactor {
  String get id;

  int get version;

  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  );
}

final class AgentCompactionStrategyException implements Exception {
  AgentCompactionStrategyException._({
    required this.error,
    required List<AgentCompactionInvocationReport> reports,
  }) : reports = _validatedInvocationReports(reports) {
    final last = this.reports.lastOrNull;
    if (last != null &&
        ((error.kind == AgentErrorKind.cancelled &&
                last.outcome == AgentModelInvocationOutcome.failed) ||
            (error.kind != AgentErrorKind.cancelled &&
                last.outcome == AgentModelInvocationOutcome.cancelled))) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction failure reports contradict the terminal outcome.',
      );
    }
  }

  factory AgentCompactionStrategyException.failed({
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) => AgentCompactionStrategyException._(
    error: sanitizedCompactionError(),
    reports: reports,
  );

  factory AgentCompactionStrategyException.cancelled({
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) => AgentCompactionStrategyException._(
    error: AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
    reports: reports,
  );

  final AgentError error;
  final List<AgentCompactionInvocationReport> reports;

  /// Coarse compatibility projection. Per-invocation [reports] are authoritative.
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);

  @override
  String toString() => error.toString();
}

final class RecentInteractionGroupsCompactor implements AgentHistoryCompactor {
  RecentInteractionGroupsCompactor(this.recentGroupCount) {
    if (recentGroupCount < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Recent interaction group count must be non-negative.',
      );
    }
  }

  @override
  String get id => 'recent-interaction-groups';

  @override
  int get version => 1;

  final int recentGroupCount;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    if (context.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    final groups = context.interactionGroups;
    if (groups.length <= recentGroupCount && context.generatedPrefix.isEmpty) {
      return AgentCompactionNoChange(strategyId: id, strategyVersion: version);
    }
    final retained = recentGroupCount > groups.length
        ? groups.length
        : recentGroupCount;
    final cut = groups.length - retained;
    return AgentCompactionCandidate(
      strategyId: id,
      strategyVersion: version,
      retainedSuffixBoundaryId: cut == groups.length
          ? context.endBoundaryId
          : groups[cut].suffixBoundaryId,
    );
  }
}

final class PreparedAgentCompaction {
  PreparedAgentCompaction({
    required List<LlmMessage> messages,
    required List<LlmContinuationEntry> continuationEntries,
    required List<AgentTranscriptMessageId?> messageIds,
    required this.state,
    required this.afterEstimate,
  }) : messages = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(messages),
       ),
       continuationEntries = List<LlmContinuationEntry>.unmodifiable(
         List<LlmContinuationEntry>.from(continuationEntries),
       ),
       messageIds = List<AgentTranscriptMessageId?>.unmodifiable(messageIds);

  final List<LlmMessage> messages;
  final List<LlmContinuationEntry> continuationEntries;
  final List<AgentTranscriptMessageId?> messageIds;
  final AgentCompactionState state;
  final AgentContextEstimate afterEstimate;
}

PreparedAgentCompaction prepareAgentCompaction({
  required AgentCompactionContext context,
  required AgentCompactionDecision decision,
  required AgentCompactionCandidate candidate,
  required AgentContextEstimator estimator,
  required int updatedAtMicros,
}) {
  if (decision.kind != AgentCompactionDecisionKind.compact) {
    throwAgent(AgentErrorKind.compaction, 'Compaction was not requested.');
  }
  _validateGeneratedPrefix(candidate.generatedPrefix);
  final boundary = _boundaryIndex(context, candidate.retainedSuffixBoundaryId);
  if (context.reason != AgentCompactionReason.manual &&
      context.interactionGroups.isNotEmpty &&
      boundary > context.interactionGroups.last.startMessageIndex) {
    throwAgent(
      AgentErrorKind.compaction,
      'Automatic compaction must retain the active interaction group.',
    );
  }
  final oldMessages = context.request.context.messages;
  final prefixCount = context.protectedSeed.length;
  final newMessages = <LlmMessage>[
    ...context.protectedSeed,
    ...candidate.generatedPrefix,
    ...oldMessages.sublist(boundary),
  ];
  final newMessageIds = <AgentTranscriptMessageId?>[
    ...context.messageIds.take(prefixCount),
    ...candidate.generatedPrefixMessageIds,
    ...context.messageIds.skip(boundary),
  ];
  final uniqueIds = <AgentTranscriptMessageId>{};
  if (newMessageIds.whereType<AgentTranscriptMessageId>().any(
    (id) => !uniqueIds.add(id),
  )) {
    throwAgent(
      AgentErrorKind.compaction,
      'Compaction produced duplicate transcript message identities.',
    );
  }
  final remapped = <LlmContinuationEntry>[];
  final oldGeneratedEnd = prefixCount + context.generatedPrefix.length;
  for (final entry in context.continuationEntries) {
    final oldIndex = entry.assistantMessageIndex;
    if (oldIndex < prefixCount) {
      remapped.add(LlmContinuationEntry.fromJson(entry.toJson()));
    } else if (oldIndex >= boundary) {
      remapped.add(
        LlmContinuationEntry(
          assistantMessageIndex:
              prefixCount +
              candidate.generatedPrefix.length +
              oldIndex -
              boundary,
          state: LlmProviderTurnState.fromJson(entry.state.toJson()),
        ),
      );
    } else if (oldIndex < oldGeneratedEnd) {
      // A prior generated prefix cannot own continuation state; context
      // validation rejects this before reconstruction.
      throwAgent(
        AgentErrorKind.compaction,
        'Generated compaction messages cannot carry continuation state.',
      );
    }
  }
  final newContext = LlmContext(
    systemPrompt: context.request.context.systemPrompt,
    messages: newMessages,
    tools: context.request.context.tools,
    continuationEntries: remapped,
  );
  try {
    validateContinuationEntries(
      messages: newMessages,
      entries: remapped,
      origin: context.request.model,
      wireFamily: context.selectedModel.wireFamily,
    );
  } on LlmException catch (error) {
    throwAgent(AgentErrorKind.compaction, error.error.message);
  }
  partitionAgentInteractionGroups(
    messages: newMessages,
    startMessageIndex: prefixCount + candidate.generatedPrefix.length,
  );
  final after = estimator.estimate(
    AgentContextEstimateInput(
      request: LlmRequestSnapshot(
        model: context.request.model,
        context: newContext,
        generation: context.request.generation,
      ),
      cancellation: context.cancellation,
    ),
  );
  if (after.estimatorId != context.currentEstimate.estimatorId ||
      after.estimatorVersion != context.currentEstimate.estimatorVersion) {
    throwAgent(
      AgentErrorKind.compaction,
      'The active estimator changed identity during compaction.',
    );
  }
  if (after.value >= context.currentEstimate.value) {
    throwAgent(
      AgentErrorKind.compaction,
      'Compaction candidate does not reduce the active context estimate.',
    );
  }
  final target = decision.targetEstimate ?? context.targetEstimate;
  if (target != null && after.value > target) {
    throwAgent(
      AgentErrorKind.compaction,
      'Compaction candidate does not meet the requested target.',
    );
  }
  final removedThisGeneration =
      context.generatedPrefix.length + boundary - oldGeneratedEnd;
  if (removedThisGeneration <= 0) {
    throwAgent(
      AgentErrorKind.compaction,
      'Compaction candidate removes no source messages.',
    );
  }
  final state = AgentCompactionState(
    generation: (context.priorState?.generation ?? 0) + 1,
    generatedPrefixStart: prefixCount,
    generatedPrefixCount: candidate.generatedPrefix.length,
    reason: context.reason,
    triggerId: decision.triggerId,
    triggerVersion: decision.triggerVersion,
    strategyId: candidate.strategyId,
    strategyVersion: candidate.strategyVersion,
    estimatorId: after.estimatorId,
    estimatorVersion: after.estimatorVersion,
    removedMessageCount:
        (context.priorState?.removedMessageCount ?? 0) + removedThisGeneration,
    beforeEstimate: context.currentEstimate.value,
    afterEstimate: after.value,
    decisionMetadata: <String, Object?>{
      ...decision.metadata,
      ...candidate.metadata,
    },
    updatedAtMicros: updatedAtMicros,
  );
  validateAgentCompactionState(
    messages: newMessages,
    protectedSeed: context.protectedSeed,
    state: state,
    continuationEntries: remapped,
  );
  return PreparedAgentCompaction(
    messages: newMessages,
    continuationEntries: remapped,
    messageIds: newMessageIds,
    state: state,
    afterEstimate: after,
  );
}

List<AgentCompactionInvocationReport> _validatedInvocationReports(
  List<AgentCompactionInvocationReport> reports,
) {
  final frozen = List<AgentCompactionInvocationReport>.unmodifiable(reports);
  for (var index = 0; index < frozen.length; index++) {
    if (frozen[index].invocationOrdinal != index) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction invocation reports must be contiguous and source ordered.',
      );
    }
  }
  return frozen;
}

LlmUsage? aggregateAgentCompactionUsage(
  List<AgentCompactionInvocationReport> reports,
) {
  if (reports.isEmpty) {
    return null;
  }
  if (reports.length == 1) {
    return reports.single.usage;
  }
  final aggregate = AgentUsageAggregate.fromUsages(
    reports.map((report) => report.usage),
  );
  LlmUsageMetric? metric(AgentUsageDimensionAggregate dimension) =>
      dimension.value == null
      ? null
      : LlmUsageMetric.derivedFromProvider(dimension.value!);
  return LlmUsage(
    input: metric(aggregate.input),
    cacheRead: metric(aggregate.cacheRead),
    cacheWrite: metric(aggregate.cacheWrite),
    reportedInputTotal: metric(aggregate.requestContext),
    output: metric(aggregate.output),
    reasoning: metric(aggregate.reasoning),
    reportedOutputTotal: metric(aggregate.responseGenerated),
    reportedOverall: metric(aggregate.overall),
  );
}

void validateAgentCompactionState({
  required List<LlmMessage> messages,
  required List<LlmMessage> protectedSeed,
  required AgentCompactionState state,
  required List<LlmContinuationEntry> continuationEntries,
}) {
  if (messages.length < protectedSeed.length ||
      !listEquals(messages.sublist(0, protectedSeed.length), protectedSeed)) {
    throwAgent(
      AgentErrorKind.configuration,
      'Compacted transcript does not preserve its protected seed.',
    );
  }
  if (state.generatedPrefixStart != protectedSeed.length ||
      state.generatedPrefixEnd > messages.length) {
    throwAgent(
      AgentErrorKind.configuration,
      'Generated compaction prefix range is invalid.',
    );
  }
  _validateGeneratedPrefix(
    messages.sublist(state.generatedPrefixStart, state.generatedPrefixEnd),
  );
  for (final entry in continuationEntries) {
    if (entry.assistantMessageIndex >= state.generatedPrefixStart &&
        entry.assistantMessageIndex < state.generatedPrefixEnd) {
      throwAgent(
        AgentErrorKind.configuration,
        'Generated compaction messages cannot carry continuation state.',
      );
    }
  }
  partitionAgentInteractionGroups(
    messages: messages,
    startMessageIndex: state.generatedPrefixEnd,
  );
}

void _validateContextShape(AgentCompactionContext context) {
  final messages = context.request.context.messages;
  final protectedCount = context.protectedSeed.length;
  final generatedEnd = protectedCount + context.generatedPrefix.length;
  if (messages.length < generatedEnd ||
      !listEquals(messages.sublist(0, protectedCount), context.protectedSeed) ||
      !listEquals(
        messages.sublist(protectedCount, generatedEnd),
        context.generatedPrefix,
      )) {
    throwAgent(
      AgentErrorKind.configuration,
      'Compaction context prefixes do not match the request snapshot.',
    );
  }
  _validateGeneratedPrefix(context.generatedPrefix);
  final expected = partitionAgentInteractionGroups(
    messages: messages,
    startMessageIndex: generatedEnd,
  );
  if (expected.length != context.interactionGroups.length) {
    throwAgent(
      AgentErrorKind.configuration,
      'Compaction interaction groups do not cover the mutable history.',
    );
  }
  for (var index = 0; index < expected.length; index++) {
    final left = expected[index];
    final right = context.interactionGroups[index];
    if (left.id != right.id ||
        left.startMessageIndex != right.startMessageIndex ||
        left.endMessageIndex != right.endMessageIndex ||
        !listEquals(left.messages, right.messages)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction interaction groups are not canonical.',
      );
    }
  }
  if (!listEquals(
    context.request.context.continuationEntries,
    context.continuationEntries,
  )) {
    throwAgent(
      AgentErrorKind.configuration,
      'Compaction continuation snapshot does not match the request.',
    );
  }
  for (final entry in context.continuationEntries) {
    if (entry.assistantMessageIndex >= protectedCount &&
        entry.assistantMessageIndex < generatedEnd) {
      throwAgent(
        AgentErrorKind.configuration,
        'Generated compaction messages cannot carry continuation state.',
      );
    }
  }
  final prior = context.priorState;
  if (prior == null && context.generatedPrefix.isNotEmpty) {
    throwAgent(
      AgentErrorKind.configuration,
      'Generated messages require compaction provenance.',
    );
  }
  if (prior != null) {
    validateAgentCompactionState(
      messages: messages,
      protectedSeed: context.protectedSeed,
      state: prior,
      continuationEntries: context.continuationEntries,
    );
  }
}

void _validateGeneratedPrefix(List<LlmMessage> messages) {
  for (final message in messages) {
    if (message.role == LlmMessageRole.tool ||
        message.parts.any((part) => part is! LlmTextPart)) {
      throwAgent(
        AgentErrorKind.compaction,
        'Generated compaction messages must contain only user/assistant text.',
      );
    }
  }
}

int _boundaryIndex(AgentCompactionContext context, String boundaryId) {
  if (boundaryId == context.endBoundaryId) {
    return context.request.context.messages.length;
  }
  for (final group in context.interactionGroups) {
    if (group.suffixBoundaryId == boundaryId) {
      return group.startMessageIndex;
    }
  }
  throwAgent(
    AgentErrorKind.compaction,
    'Compaction candidate selected an unknown interaction boundary.',
  );
}

Map<String, Object?> _sanitizedMetadata(Map<String, Object?> metadata) {
  Object? sanitize(Object? value) {
    if (value is String) {
      return sanitizePublicText(value, fallback: '[redacted]');
    }
    if (value is List) {
      return value.map(sanitize).toList();
    }
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((key, nested) {
        if (key is! String) {
          throwAgent(
            AgentErrorKind.configuration,
            'Compaction metadata keys must be strings.',
          );
        }
        result[key] = sanitize(nested);
      });
      return result;
    }
    if (value == null || value is bool || value is num) {
      return value;
    }
    throwAgent(
      AgentErrorKind.configuration,
      'Compaction metadata must contain only JSON values.',
    );
  }

  return freezeJsonMap(sanitize(metadata)! as Map<String, Object?>);
}

String _nonBlank(String value, String label) {
  final result = value.trim();
  if (result.isEmpty) {
    throwAgent(AgentErrorKind.configuration, '$label must not be blank.');
  }
  return result;
}

int _requireNonNegative(Map<String, Object?> map, String key) {
  final value = requireInt(map, key);
  if (value < 0) {
    throwLlm(
      LlmErrorKind.protocol,
      'Expected non-negative integer field "$key".',
    );
  }
  return value;
}

int _ceilScaled(int value, double fraction) => (value * fraction).ceil();

int _min(int left, int right) => left < right ? left : right;

int _max(int left, int right) => left > right ? left : right;
