import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/usage.dart';
import 'errors.dart';
import 'ids.dart';

enum AgentModelOperationKind { assistant, compaction }

enum AgentModelInvocationOutcome {
  completed,
  failed,
  overflow,
  cancelled,
  stopped,
}

/// One immutable fact for one accepted physical provider invocation.
final class AgentModelUsageEntry {
  AgentModelUsageEntry._({
    required this.sequence,
    required this.attemptId,
    required this.model,
    required this.operationKind,
    required this.outcome,
    required this.usage,
    required this.contextRevision,
    required this.runId,
    required this.turnId,
    required this.retryOrdinal,
    required this.requestMessageId,
    required this.responseMessageId,
    required this.compactionOperationId,
    required this.invocationOrdinal,
  }) {
    if (sequence <= 0 || contextRevision < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Usage ledger position and context revision are invalid.',
      );
    }
    if (<LlmUsageMetric?>[
      usage.input,
      usage.cacheRead,
      usage.cacheWrite,
      usage.output,
      usage.reasoning,
      usage.reportedInputTotal,
      usage.reportedOutputTotal,
      usage.reportedOverall,
      usage.cacheMissEvidence,
    ].whereType<LlmUsageMetric>().any(
      (metric) => metric.provenance == LlmUsageMetricProvenance.estimated,
    )) {
      throwAgent(
        AgentErrorKind.configuration,
        'Persisted provider usage cannot contain estimated metrics.',
      );
    }
    _validateCorrelation();
  }

  factory AgentModelUsageEntry.assistant({
    required int sequence,
    required ProviderAttemptId attemptId,
    required ModelRef model,
    required AgentModelInvocationOutcome outcome,
    required LlmUsage usage,
    required int contextRevision,
    required RunId runId,
    required TurnId turnId,
    required int retryOrdinal,
    required AgentTranscriptMessageId requestMessageId,
    AgentTranscriptMessageId? responseMessageId,
  }) => AgentModelUsageEntry._(
    sequence: sequence,
    attemptId: attemptId,
    model: model,
    operationKind: AgentModelOperationKind.assistant,
    outcome: outcome,
    usage: usage,
    contextRevision: contextRevision,
    runId: runId,
    turnId: turnId,
    retryOrdinal: retryOrdinal,
    requestMessageId: requestMessageId,
    responseMessageId: responseMessageId,
    compactionOperationId: null,
    invocationOrdinal: null,
  );

  factory AgentModelUsageEntry.compaction({
    required int sequence,
    required ProviderAttemptId attemptId,
    required ModelRef model,
    required AgentModelInvocationOutcome outcome,
    required LlmUsage usage,
    required int contextRevision,
    required AgentCompactionOperationId compactionOperationId,
    required int invocationOrdinal,
    RunId? runId,
  }) => AgentModelUsageEntry._(
    sequence: sequence,
    attemptId: attemptId,
    model: model,
    operationKind: AgentModelOperationKind.compaction,
    outcome: outcome,
    usage: usage,
    contextRevision: contextRevision,
    runId: runId,
    turnId: null,
    retryOrdinal: null,
    requestMessageId: null,
    responseMessageId: null,
    compactionOperationId: compactionOperationId,
    invocationOrdinal: invocationOrdinal,
  );

  factory AgentModelUsageEntry.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final operationKind = _enumValue(
      AgentModelOperationKind.values,
      requireNonBlankString(map, 'operationKind'),
      'operation kind',
    );
    final outcome = _enumValue(
      AgentModelInvocationOutcome.values,
      requireNonBlankString(map, 'outcome'),
      'invocation outcome',
    );
    final common = (
      sequence: requirePositiveInt(map, 'sequence'),
      attemptId: ProviderAttemptId.fromJson(map['attemptId']),
      model: ModelRef.fromJson(map['model']),
      outcome: outcome,
      usage: LlmUsage.fromJson(map['usage']),
      contextRevision: _requireNonNegative(map, 'contextRevision'),
      runId: map['runId'] == null ? null : RunId.fromJson(map['runId']),
    );
    return switch (operationKind) {
      AgentModelOperationKind.assistant => AgentModelUsageEntry.assistant(
        sequence: common.sequence,
        attemptId: common.attemptId,
        model: common.model,
        outcome: common.outcome,
        usage: common.usage,
        contextRevision: common.contextRevision,
        runId: common.runId ?? _missingCorrelation('run id'),
        turnId: TurnId.fromJson(map['turnId']),
        retryOrdinal: _requireNonNegative(map, 'retryOrdinal'),
        requestMessageId: AgentTranscriptMessageId.fromJson(
          map['requestMessageId'],
        ),
        responseMessageId: map['responseMessageId'] == null
            ? null
            : AgentTranscriptMessageId.fromJson(map['responseMessageId']),
      ),
      AgentModelOperationKind.compaction => AgentModelUsageEntry.compaction(
        sequence: common.sequence,
        attemptId: common.attemptId,
        model: common.model,
        outcome: common.outcome,
        usage: common.usage,
        contextRevision: common.contextRevision,
        compactionOperationId: AgentCompactionOperationId.fromJson(
          map['compactionOperationId'],
        ),
        invocationOrdinal: _requireNonNegative(map, 'invocationOrdinal'),
        runId: common.runId,
      ),
    };
  }

  static const jsonType = 'agent.model_usage_entry';

  final int sequence;
  final ProviderAttemptId attemptId;
  final ModelRef model;
  final AgentModelOperationKind operationKind;
  final AgentModelInvocationOutcome outcome;
  final LlmUsage usage;
  final int contextRevision;
  final RunId? runId;
  final TurnId? turnId;
  final int? retryOrdinal;
  final AgentTranscriptMessageId? requestMessageId;
  final AgentTranscriptMessageId? responseMessageId;
  final AgentCompactionOperationId? compactionOperationId;
  final int? invocationOrdinal;

  void _validateCorrelation() {
    if (operationKind == AgentModelOperationKind.assistant) {
      if (runId == null ||
          turnId == null ||
          retryOrdinal == null ||
          retryOrdinal! < 0 ||
          requestMessageId == null ||
          compactionOperationId != null ||
          invocationOrdinal != null) {
        throwAgent(
          AgentErrorKind.configuration,
          'Assistant usage correlation is incomplete.',
        );
      }
      if (responseMessageId != null &&
          outcome != AgentModelInvocationOutcome.completed) {
        throwAgent(
          AgentErrorKind.configuration,
          'Assistant response correlation contradicts its outcome.',
        );
      }
      return;
    }
    if (turnId != null ||
        retryOrdinal != null ||
        requestMessageId != null ||
        responseMessageId != null ||
        compactionOperationId == null ||
        invocationOrdinal == null ||
        invocationOrdinal! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compaction usage correlation is invalid.',
      );
    }
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'sequence': sequence,
      'attemptId': attemptId.toJson(),
      'model': model.toJson(),
      'operationKind': operationKind.name,
      'outcome': outcome.name,
      'usage': usage.toJson(),
      'contextRevision': contextRevision,
      if (runId != null) 'runId': runId!.toJson(),
      if (turnId != null) 'turnId': turnId!.toJson(),
      if (retryOrdinal != null) 'retryOrdinal': retryOrdinal,
      if (requestMessageId != null)
        'requestMessageId': requestMessageId!.toJson(),
      if (responseMessageId != null)
        'responseMessageId': responseMessageId!.toJson(),
      if (compactionOperationId != null)
        'compactionOperationId': compactionOperationId!.toJson(),
      if (invocationOrdinal != null) 'invocationOrdinal': invocationOrdinal,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentModelUsageEntry &&
          other.sequence == sequence &&
          other.attemptId == attemptId &&
          other.model == model &&
          other.operationKind == operationKind &&
          other.outcome == outcome &&
          other.usage == usage &&
          other.contextRevision == contextRevision &&
          other.runId == runId &&
          other.turnId == turnId &&
          other.retryOrdinal == retryOrdinal &&
          other.requestMessageId == requestMessageId &&
          other.responseMessageId == responseMessageId &&
          other.compactionOperationId == compactionOperationId &&
          other.invocationOrdinal == invocationOrdinal;

  @override
  int get hashCode => Object.hash(
    sequence,
    attemptId,
    model,
    operationKind,
    outcome,
    usage,
    contextRevision,
    runId,
    turnId,
    retryOrdinal,
    requestMessageId,
    responseMessageId,
    compactionOperationId,
    invocationOrdinal,
  );
}

/// Persisted accounting source of truth.
final class AgentTokenAccountingState {
  AgentTokenAccountingState({
    required this.generation,
    required this.contextRevision,
    required List<AgentTranscriptMessageId?> messageIds,
    required this.legacyBaseline,
    required List<AgentModelUsageEntry> entries,
  }) : messageIds = List<AgentTranscriptMessageId?>.unmodifiable(messageIds),
       entries = List<AgentModelUsageEntry>.unmodifiable(entries) {
    _validate();
  }

  factory AgentTokenAccountingState.legacy({
    required int transcriptMessageCount,
    required LlmUsage usage,
  }) => AgentTokenAccountingState(
    generation: 0,
    contextRevision: 0,
    messageIds: List<AgentTranscriptMessageId?>.filled(
      transcriptMessageCount,
      null,
    ),
    legacyBaseline: usage,
    entries: const <AgentModelUsageEntry>[],
  );

  factory AgentTokenAccountingState.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType, version: jsonVersion);
    return AgentTokenAccountingState(
      generation: requirePositiveInt(map, 'generation'),
      contextRevision: _requireNonNegative(map, 'contextRevision'),
      messageIds: requireList(map, 'messageIds')
          .map(
            (value) =>
                value == null ? null : AgentTranscriptMessageId.fromJson(value),
          )
          .toList(growable: false),
      legacyBaseline: LlmUsage.fromJson(map['legacyBaseline']),
      entries: requireList(
        map,
        'entries',
      ).map(AgentModelUsageEntry.fromJson).toList(growable: false),
    );
  }

  static const jsonType = 'agent.token_accounting';
  static const jsonVersion = 1;

  final int generation;
  final int contextRevision;
  final List<AgentTranscriptMessageId?> messageIds;
  final LlmUsage legacyBaseline;
  final List<AgentModelUsageEntry> entries;

  void _validate() {
    if (generation < 0 || contextRevision < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Accounting generation and context revision must be non-negative.',
      );
    }
    if (generation == 0 &&
        (contextRevision != 0 ||
            entries.isNotEmpty ||
            messageIds.any((id) => id != null))) {
      throwAgent(
        AgentErrorKind.configuration,
        'Generation-zero accounting cannot invent attributed history.',
      );
    }
    final retainedIds = <AgentTranscriptMessageId>{};
    for (final id in messageIds) {
      if (id != null && !retainedIds.add(id)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Transcript message identities must be unique.',
        );
      }
    }
    final attempts = <ProviderAttemptId>{};
    final responseIds = <AgentTranscriptMessageId>{};
    final assistantOrdinals = <(RunId, TurnId, int)>{};
    final compactionOrdinals = <AgentCompactionOperationId, int>{};
    var priorSequence = 0;
    for (final entry in entries) {
      if (entry.sequence <= priorSequence || !attempts.add(entry.attemptId)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Usage ledger entries must have unique ids and increasing sequence.',
        );
      }
      final responseId = entry.responseMessageId;
      if (responseId != null && !responseIds.add(responseId)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Assistant response identities must be unique.',
        );
      }
      if (entry.operationKind == AgentModelOperationKind.assistant) {
        if (!assistantOrdinals.add((
          entry.runId!,
          entry.turnId!,
          entry.retryOrdinal!,
        ))) {
          throwAgent(
            AgentErrorKind.configuration,
            'Assistant attempt ordinals must be unique per logical turn.',
          );
        }
      } else {
        final operationId = entry.compactionOperationId!;
        final priorOrdinal = compactionOrdinals[operationId];
        if (priorOrdinal != null && entry.invocationOrdinal! <= priorOrdinal) {
          throwAgent(
            AgentErrorKind.configuration,
            'Compaction invocation ordinals must increase per operation.',
          );
        }
        compactionOrdinals[operationId] = entry.invocationOrdinal!;
      }
      priorSequence = entry.sequence;
    }
  }

  LlmUsage get compatibilityUsage {
    if (entries.isEmpty) {
      return legacyBaseline;
    }
    final aggregate = AgentUsageAggregate.fromUsages(<LlmUsage>[
      if (!legacyBaseline.isEmpty) legacyBaseline,
      ...entries.map((entry) => entry.usage),
    ]);
    LlmUsageMetric? metric(AgentUsageDimensionAggregate dimension) =>
        dimension.value == null
        ? null
        : LlmUsageMetric.derivedFromProvider(dimension.value!);
    return LlmUsage(
      reportedInputTotal: metric(aggregate.requestContext),
      cacheRead: metric(aggregate.cacheRead),
      reportedOutputTotal: metric(aggregate.responseGenerated),
      reportedOverall: metric(aggregate.overall),
      cacheMissEvidence: legacyBaseline.cacheMissEvidence,
    );
  }

  AgentTokenAccountingState copyWith({
    int? generation,
    int? contextRevision,
    List<AgentTranscriptMessageId?>? messageIds,
    LlmUsage? legacyBaseline,
    List<AgentModelUsageEntry>? entries,
  }) => AgentTokenAccountingState(
    generation: generation ?? this.generation,
    contextRevision: contextRevision ?? this.contextRevision,
    messageIds: messageIds ?? this.messageIds,
    legacyBaseline: legacyBaseline ?? this.legacyBaseline,
    entries: entries ?? this.entries,
  );

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: jsonVersion,
    fields: <String, Object?>{
      'generation': generation,
      'contextRevision': contextRevision,
      'messageIds': messageIds
          .map((id) => id?.toJson())
          .toList(growable: false),
      'legacyBaseline': legacyBaseline.toJson(),
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTokenAccountingState &&
          other.generation == generation &&
          other.contextRevision == contextRevision &&
          listEquals(other.messageIds, messageIds) &&
          other.legacyBaseline == legacyBaseline &&
          listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(
    generation,
    contextRevision,
    Object.hashAll(messageIds),
    legacyBaseline,
    Object.hashAll(entries),
  );
}

final class AgentUsageDimensionAggregate {
  const AgentUsageDimensionAggregate({
    required this.knownSubtotal,
    required this.contributorCount,
    required this.knownContributorCount,
    required this.missingContributorCount,
    required this.inconsistentContributorCount,
  });

  final int knownSubtotal;
  final int contributorCount;
  final int knownContributorCount;
  final int missingContributorCount;
  final int inconsistentContributorCount;

  LlmUsageCompleteness get completeness {
    if (missingContributorCount == 0 && inconsistentContributorCount == 0) {
      return LlmUsageCompleteness.complete;
    }
    return knownContributorCount == 0
        ? LlmUsageCompleteness.unavailable
        : LlmUsageCompleteness.partial;
  }

  int? get value =>
      completeness == LlmUsageCompleteness.complete ? knownSubtotal : null;
}

final class AgentUsageAggregate {
  AgentUsageAggregate._({
    required this.contributorCount,
    required this.input,
    required this.cacheRead,
    required this.cacheWrite,
    required this.requestContext,
    required this.output,
    required this.reasoning,
    required this.responseGenerated,
    required this.overall,
  });

  factory AgentUsageAggregate.fromUsages(Iterable<LlmUsage> source) {
    final usages = List<LlmUsage>.unmodifiable(source);
    AgentUsageDimensionAggregate dimension(
      LlmUsageMetric? Function(LlmUsage usage) select, {
      required bool Function(LlmUsage usage) inconsistent,
    }) {
      var subtotal = 0;
      var known = 0;
      var missing = 0;
      var contradictions = 0;
      for (final usage in usages) {
        final metric = select(usage);
        if (metric != null) {
          subtotal += metric.value;
          known += 1;
        } else if (inconsistent(usage)) {
          contradictions += 1;
        } else {
          missing += 1;
        }
      }
      return AgentUsageDimensionAggregate(
        knownSubtotal: subtotal,
        contributorCount: usages.length,
        knownContributorCount: known,
        missingContributorCount: missing,
        inconsistentContributorCount: contradictions,
      );
    }

    bool anyAnomaly(LlmUsage usage) => usage.anomalies.isNotEmpty;
    bool metricAnomaly(LlmUsage usage, LlmUsageMetricKind kind) => usage
        .anomalies
        .any((anomaly) => anomaly.metric == null || anomaly.metric == kind);
    return AgentUsageAggregate._(
      contributorCount: usages.length,
      input: dimension(
        (usage) => usage.input,
        inconsistent: (usage) => metricAnomaly(usage, LlmUsageMetricKind.input),
      ),
      cacheRead: dimension(
        (usage) => usage.cacheRead,
        inconsistent: (usage) =>
            metricAnomaly(usage, LlmUsageMetricKind.cacheRead),
      ),
      cacheWrite: dimension(
        (usage) => usage.cacheWrite,
        inconsistent: (usage) =>
            metricAnomaly(usage, LlmUsageMetricKind.cacheWrite),
      ),
      requestContext: dimension(
        (usage) => usage.requestContext,
        inconsistent: anyAnomaly,
      ),
      output: dimension(
        (usage) => usage.output,
        inconsistent: (usage) =>
            metricAnomaly(usage, LlmUsageMetricKind.output),
      ),
      reasoning: dimension(
        (usage) => usage.reasoning,
        inconsistent: (usage) =>
            metricAnomaly(usage, LlmUsageMetricKind.reasoning),
      ),
      responseGenerated: dimension(
        (usage) => usage.responseGenerated,
        inconsistent: anyAnomaly,
      ),
      overall: dimension((usage) => usage.overall, inconsistent: anyAnomaly),
    );
  }

  final int contributorCount;
  final AgentUsageDimensionAggregate input;
  final AgentUsageDimensionAggregate cacheRead;
  final AgentUsageDimensionAggregate cacheWrite;
  final AgentUsageDimensionAggregate requestContext;
  final AgentUsageDimensionAggregate output;
  final AgentUsageDimensionAggregate reasoning;
  final AgentUsageDimensionAggregate responseGenerated;
  final AgentUsageDimensionAggregate overall;

  LlmUsageRatio? get cacheHitRatio {
    final denominator = requestContext.value;
    final numerator = cacheRead.value;
    if (denominator == null || numerator == null || denominator <= 0) {
      return null;
    }
    return LlmUsageRatio(
      value: numerator / denominator,
      provenance: LlmUsageMetricProvenance.derivedFromProvider,
    );
  }
}

final class AgentActiveModelUsage {
  AgentActiveModelUsage({
    required this.attemptId,
    required this.model,
    required this.runId,
    required this.turnId,
    required this.retryOrdinal,
    required this.requestMessageId,
    required this.contextRevision,
    required this.usage,
  }) {
    if (retryOrdinal < 0 || contextRevision < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Active usage correlation is invalid.',
      );
    }
  }

  final ProviderAttemptId attemptId;
  final ModelRef model;
  final RunId runId;
  final TurnId turnId;
  final int retryOrdinal;
  final AgentTranscriptMessageId requestMessageId;
  final int contextRevision;
  final LlmUsage usage;
}

final class AgentRequestTokenView {
  const AgentRequestTokenView({
    required this.attemptId,
    required this.model,
    required this.runId,
    required this.turnId,
    required this.retryOrdinal,
    required this.requestMessageId,
    required this.requestMessageRetained,
    required this.contextRevision,
    required this.usage,
    required this.active,
  });

  final ProviderAttemptId attemptId;
  final ModelRef model;
  final RunId runId;
  final TurnId turnId;
  final int retryOrdinal;
  final AgentTranscriptMessageId requestMessageId;
  final bool requestMessageRetained;
  final int contextRevision;
  final LlmUsage usage;
  final bool active;

  LlmUsageMetric? get input => usage.input;
  LlmUsageMetric? get cacheRead => usage.cacheRead;
  LlmUsageMetric? get cacheWrite => usage.cacheWrite;
  LlmUsageMetric? get requestContext => usage.requestContext;
  LlmUsageCompleteness get completeness => usage.requestCompleteness;
  LlmUsageRatio? get cacheHitRatio => usage.cacheHitRatio;
}

final class AgentResponseTokenView {
  const AgentResponseTokenView({
    required this.attemptId,
    required this.model,
    required this.runId,
    required this.turnId,
    required this.responseMessageId,
    required this.responseMessageRetained,
    required this.usage,
  });

  final ProviderAttemptId attemptId;
  final ModelRef model;
  final RunId runId;
  final TurnId turnId;
  final AgentTranscriptMessageId responseMessageId;
  final bool responseMessageRetained;
  final LlmUsage usage;

  LlmUsageMetric? get output => usage.output;
  LlmUsageMetric? get reasoning => usage.reasoning;
  LlmUsageMetric? get responseGenerated => usage.responseGenerated;
  LlmUsageCompleteness get completeness => usage.responseCompleteness;
}

final class AgentRetainedContextMeasurement {
  AgentRetainedContextMeasurement({
    required this.contextRevision,
    required this.estimatorId,
    required this.estimatorVersion,
    this.estimate,
  }) {
    if (contextRevision < 0 ||
        estimatorId.trim().isEmpty ||
        estimatorVersion <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Retained-context measurement metadata is invalid.',
      );
    }
    if (estimate != null && estimate! < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Retained-context estimate must be non-negative.',
      );
    }
  }

  final int contextRevision;
  final String estimatorId;
  final int estimatorVersion;
  final int? estimate;
}

final class AgentRetainedContextView {
  const AgentRetainedContextView({
    required this.metric,
    required this.contextRevision,
    required this.sourceId,
    required this.sourceVersion,
    required this.providerAttemptId,
  });

  final LlmUsageMetric? metric;
  final int contextRevision;
  final String sourceId;
  final int sourceVersion;
  final ProviderAttemptId? providerAttemptId;

  int? get value => metric?.value;
  LlmUsageMetricProvenance? get provenance => metric?.provenance;
}

final class AgentModelUsageEntryView {
  const AgentModelUsageEntryView({
    required this.entry,
    required this.requestMessageRetained,
    required this.responseMessageRetained,
  });

  final AgentModelUsageEntry entry;
  final bool requestMessageRetained;
  final bool responseMessageRetained;
}

final class AgentModelUsageGroup {
  AgentModelUsageGroup({
    required this.model,
    required List<AgentModelUsageEntry> entries,
  }) : entries = List<AgentModelUsageEntry>.unmodifiable(entries),
       assistant = AgentUsageAggregate.fromUsages(
         entries
             .where(
               (entry) =>
                   entry.operationKind == AgentModelOperationKind.assistant,
             )
             .map((entry) => entry.usage),
       ),
       compaction = AgentUsageAggregate.fromUsages(
         entries
             .where(
               (entry) =>
                   entry.operationKind == AgentModelOperationKind.compaction,
             )
             .map((entry) => entry.usage),
       ),
       session = AgentUsageAggregate.fromUsages(
         entries.map((entry) => entry.usage),
       );

  final ModelRef model;
  final List<AgentModelUsageEntry> entries;
  final AgentUsageAggregate assistant;
  final AgentUsageAggregate compaction;
  final AgentUsageAggregate session;
}

final class AgentTokenAccountingSnapshot {
  AgentTokenAccountingSnapshot({
    required this.generation,
    required this.contextRevision,
    required this.currentRequest,
    required this.latestResponse,
    required this.retainedContext,
    required this.assistantConversation,
    required this.compaction,
    required this.session,
    required Map<ModelRef, AgentModelUsageGroup> byModel,
    required List<AgentModelUsageEntryView> ledger,
    required this.legacyBaseline,
    required this.compatibilityUsage,
  }) : byModel = Map<ModelRef, AgentModelUsageGroup>.unmodifiable(byModel),
       ledger = List<AgentModelUsageEntryView>.unmodifiable(ledger);

  final int generation;
  final int contextRevision;
  final AgentRequestTokenView? currentRequest;
  final AgentResponseTokenView? latestResponse;
  final AgentRetainedContextView retainedContext;
  final AgentUsageAggregate assistantConversation;
  final AgentUsageAggregate compaction;
  final AgentUsageAggregate session;
  final Map<ModelRef, AgentModelUsageGroup> byModel;
  final List<AgentModelUsageEntryView> ledger;
  final LlmUsage legacyBaseline;
  final LlmUsage compatibilityUsage;
}

/// Pure deterministic projection over persisted facts plus one active snapshot.
final class AgentTokenAccountingProjector {
  const AgentTokenAccountingProjector();

  AgentTokenAccountingSnapshot project({
    required AgentTokenAccountingState state,
    AgentActiveModelUsage? activeAssistant,
    AgentRetainedContextMeasurement? retainedContextMeasurement,
  }) {
    final retainedIds = state.messageIds
        .whereType<AgentTranscriptMessageId>()
        .toSet();
    final assistantEntries = state.entries
        .where(
          (entry) => entry.operationKind == AgentModelOperationKind.assistant,
        )
        .toList(growable: false);
    final compactionEntries = state.entries
        .where(
          (entry) => entry.operationKind == AgentModelOperationKind.compaction,
        )
        .toList(growable: false);

    AgentRequestTokenView? currentRequest;
    if (activeAssistant != null) {
      currentRequest = AgentRequestTokenView(
        attemptId: activeAssistant.attemptId,
        model: activeAssistant.model,
        runId: activeAssistant.runId,
        turnId: activeAssistant.turnId,
        retryOrdinal: activeAssistant.retryOrdinal,
        requestMessageId: activeAssistant.requestMessageId,
        requestMessageRetained: retainedIds.contains(
          activeAssistant.requestMessageId,
        ),
        contextRevision: activeAssistant.contextRevision,
        usage: activeAssistant.usage,
        active: true,
      );
    } else if (assistantEntries.isNotEmpty) {
      final entry = assistantEntries.last;
      currentRequest = AgentRequestTokenView(
        attemptId: entry.attemptId,
        model: entry.model,
        runId: entry.runId!,
        turnId: entry.turnId!,
        retryOrdinal: entry.retryOrdinal!,
        requestMessageId: entry.requestMessageId!,
        requestMessageRetained: retainedIds.contains(entry.requestMessageId),
        contextRevision: entry.contextRevision,
        usage: entry.usage,
        active: false,
      );
    }

    AgentResponseTokenView? latestResponse;
    for (final entry in assistantEntries.reversed) {
      final responseId = entry.responseMessageId;
      if (entry.outcome == AgentModelInvocationOutcome.completed &&
          responseId != null) {
        latestResponse = AgentResponseTokenView(
          attemptId: entry.attemptId,
          model: entry.model,
          runId: entry.runId!,
          turnId: entry.turnId!,
          responseMessageId: responseId,
          responseMessageRetained: retainedIds.contains(responseId),
          usage: entry.usage,
        );
        break;
      }
    }

    final models = <ModelRef, List<AgentModelUsageEntry>>{};
    for (final entry in state.entries) {
      models
          .putIfAbsent(entry.model, () => <AgentModelUsageEntry>[])
          .add(entry);
    }
    final sortedModels = models.keys.toList()
      ..sort((left, right) => left.toString().compareTo(right.toString()));
    final byModel = <ModelRef, AgentModelUsageGroup>{
      for (final model in sortedModels)
        model: AgentModelUsageGroup(model: model, entries: models[model]!),
    };

    final sessionUsages = <LlmUsage>[
      if (!state.legacyBaseline.isEmpty) state.legacyBaseline,
      ...state.entries.map((entry) => entry.usage),
      if (activeAssistant != null) activeAssistant.usage,
    ];
    final assistantUsages = <LlmUsage>[
      ...assistantEntries.map((entry) => entry.usage),
      if (activeAssistant != null) activeAssistant.usage,
    ];
    final sessionAggregate = AgentUsageAggregate.fromUsages(sessionUsages);
    return AgentTokenAccountingSnapshot(
      generation: state.generation,
      contextRevision: state.contextRevision,
      currentRequest: currentRequest,
      latestResponse: latestResponse,
      retainedContext: _retainedContext(
        currentRequest,
        retainedContextMeasurement,
        state.contextRevision,
      ),
      assistantConversation: AgentUsageAggregate.fromUsages(assistantUsages),
      compaction: AgentUsageAggregate.fromUsages(
        compactionEntries.map((entry) => entry.usage),
      ),
      session: sessionAggregate,
      byModel: byModel,
      ledger: state.entries
          .map(
            (entry) => AgentModelUsageEntryView(
              entry: entry,
              requestMessageRetained:
                  entry.requestMessageId != null &&
                  retainedIds.contains(entry.requestMessageId),
              responseMessageRetained:
                  entry.responseMessageId != null &&
                  retainedIds.contains(entry.responseMessageId),
            ),
          )
          .toList(growable: false),
      legacyBaseline: state.legacyBaseline,
      compatibilityUsage: activeAssistant == null
          ? state.compatibilityUsage
          : _compatibilityUsage(
              sessionAggregate,
              cacheMissEvidence: state.legacyBaseline.cacheMissEvidence,
            ),
    );
  }

  LlmUsage _compatibilityUsage(
    AgentUsageAggregate aggregate, {
    required LlmUsageMetric? cacheMissEvidence,
  }) {
    LlmUsageMetric? metric(AgentUsageDimensionAggregate dimension) =>
        dimension.value == null
        ? null
        : LlmUsageMetric.derivedFromProvider(dimension.value!);
    return LlmUsage(
      reportedInputTotal: metric(aggregate.requestContext),
      cacheRead: metric(aggregate.cacheRead),
      reportedOutputTotal: metric(aggregate.responseGenerated),
      reportedOverall: metric(aggregate.overall),
      cacheMissEvidence: cacheMissEvidence,
    );
  }

  AgentRetainedContextView _retainedContext(
    AgentRequestTokenView? request,
    AgentRetainedContextMeasurement? measurement,
    int contextRevision,
  ) {
    if (request != null &&
        request.contextRevision == contextRevision &&
        request.usage.requestContext != null) {
      return AgentRetainedContextView(
        metric: request.usage.requestContext,
        contextRevision: contextRevision,
        sourceId: 'provider',
        sourceVersion: 1,
        providerAttemptId: request.attemptId,
      );
    }
    if (measurement == null) {
      return AgentRetainedContextView(
        metric: null,
        contextRevision: contextRevision,
        sourceId: 'unavailable',
        sourceVersion: 1,
        providerAttemptId: null,
      );
    }
    if (measurement.contextRevision != contextRevision) {
      throwAgent(
        AgentErrorKind.configuration,
        'Retained-context measurement is stale.',
      );
    }
    return AgentRetainedContextView(
      metric: measurement.estimate == null
          ? null
          : LlmUsageMetric.estimated(measurement.estimate!),
      contextRevision: contextRevision,
      sourceId: measurement.estimatorId,
      sourceVersion: measurement.estimatorVersion,
      providerAttemptId: null,
    );
  }
}

T _enumValue<T extends Enum>(List<T> values, String name, String label) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throwAgent(AgentErrorKind.configuration, 'Unknown $label.');
}

Never _missingCorrelation(String label) => throwAgent(
  AgentErrorKind.configuration,
  'Persisted usage entry is missing $label.',
);

int _requireNonNegative(Map<String, Object?> map, String key) {
  final value = requireInt(map, key);
  if (value < 0) {
    throwAgent(AgentErrorKind.configuration, '$key must be non-negative.');
  }
  return value;
}
