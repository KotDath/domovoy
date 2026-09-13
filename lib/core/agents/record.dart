import '../llm/catalog.dart';
import '../llm/continuation.dart';
import '../llm/errors.dart';
import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/messages.dart';
import '../llm/usage.dart';
import 'compaction.dart';
import 'definition.dart';
import 'errors.dart';
import 'ids.dart';
import 'token_accounting.dart';
import 'transcript.dart';

final class AgentSessionRecord {
  AgentSessionRecord({
    required this.id,
    required this.revision,
    required this.definition,
    required this.transcript,
    required this.usage,
    required this.modelTurns,
    required this.toolAttempts,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    List<LlmContinuationEntry> continuationEntries =
        const <LlmContinuationEntry>[],
    this.compactionState,
    AgentTokenAccountingState? tokenAccounting,
  }) : tokenAccounting =
           tokenAccounting ??
           AgentTokenAccountingState.legacy(
             transcriptMessageCount: transcript.messages.length,
             usage: usage,
           ),
       continuationEntries = List<LlmContinuationEntry>.unmodifiable(
         List<LlmContinuationEntry>.from(continuationEntries),
       ) {
    if (revision < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session revision must be non-negative.',
      );
    }
    if (modelTurns < 0 || toolAttempts < 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session counters must be non-negative.',
      );
    }
    if (this.continuationEntries.isNotEmpty) {
      try {
        validateContinuationEntries(
          messages: transcript.messages,
          entries: this.continuationEntries,
          origin: definition.model,
          wireFamily: _wireFamilyFor(definition, this.continuationEntries),
        );
      } on LlmException catch (error) {
        throwAgent(AgentErrorKind.configuration, error.error.message);
      }
    }
    if (compactionState != null) {
      validateAgentCompactionState(
        messages: transcript.messages,
        protectedSeed: definition.initialMessages,
        state: compactionState!,
        continuationEntries: this.continuationEntries,
      );
    }
    if (this.tokenAccounting.messageIds.length != transcript.messages.length ||
        !listEquals(this.tokenAccounting.messageIds, transcript.messageIds)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Accounting message identities do not align with the transcript.',
      );
    }
    if (this.tokenAccounting.compatibilityUsage != usage) {
      throwAgent(
        AgentErrorKind.configuration,
        'Compatibility usage disagrees with token accounting.',
      );
    }
    final retainedRoles = <AgentTranscriptMessageId, LlmMessageRole>{};
    for (var index = 0; index < transcript.messages.length; index += 1) {
      final messageId = transcript.messageIds[index];
      if (messageId != null) {
        retainedRoles[messageId] = transcript.messages[index].role;
      }
    }
    for (final entry in this.tokenAccounting.entries) {
      final responseId = entry.responseMessageId;
      final responseRole = responseId == null
          ? null
          : retainedRoles[responseId];
      if (responseRole != null && responseRole != LlmMessageRole.assistant) {
        throwAgent(
          AgentErrorKind.configuration,
          'A retained response identity must reference an assistant message.',
        );
      }
    }
  }

  factory AgentSessionRecord.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    var transcript = AgentTranscript.fromJson(map['transcript']);
    final accounting = map['tokenAccounting'] == null
        ? null
        : AgentTokenAccountingState.fromJson(map['tokenAccounting']);
    if (accounting != null) {
      if (accounting.messageIds.length != transcript.messages.length) {
        throwAgent(
          AgentErrorKind.configuration,
          'Accounting message identities do not align with the transcript.',
        );
      }
      transcript = transcript.withMessageIds(accounting.messageIds);
    }
    return AgentSessionRecord(
      id: AgentSessionId.fromJson(map['id']),
      revision: requireInt(map, 'revision'),
      definition: AgentDefinition.fromJson(map['definition']),
      transcript: transcript,
      usage: LlmUsage.fromJson(map['usage']),
      modelTurns: requireInt(map, 'modelTurns'),
      toolAttempts: requireInt(map, 'toolAttempts'),
      createdAtMicros: requireInt(map, 'createdAtMicros'),
      updatedAtMicros: requireInt(map, 'updatedAtMicros'),
      continuationEntries: map['continuationEntries'] == null
          ? const <LlmContinuationEntry>[]
          : requireList(
              map,
              'continuationEntries',
            ).map(LlmContinuationEntry.fromJson).toList(),
      compactionState: map['compactionState'] == null
          ? null
          : AgentCompactionState.fromJson(map['compactionState']),
      tokenAccounting: accounting,
    );
  }

  static const jsonType = 'agent.session_record';

  final AgentSessionId id;
  final int revision;
  final AgentDefinition definition;
  final AgentTranscript transcript;
  final LlmUsage usage;
  final int modelTurns;
  final int toolAttempts;
  final int createdAtMicros;
  final int updatedAtMicros;
  final List<LlmContinuationEntry> continuationEntries;
  final AgentCompactionState? compactionState;
  final AgentTokenAccountingState tokenAccounting;

  int get compactionGeneration => compactionState?.generation ?? 0;
  int get accountingGeneration => tokenAccounting.generation;
  int get contextRevision => tokenAccounting.contextRevision;

  AgentTokenAccountingSnapshot projectTokenAccounting({
    AgentActiveModelUsage? activeAssistant,
    AgentRetainedContextMeasurement? retainedContextMeasurement,
  }) => const AgentTokenAccountingProjector().project(
    state: tokenAccounting,
    activeAssistant: activeAssistant,
    retainedContextMeasurement: retainedContextMeasurement,
  );

  AgentSessionRecord copyWith({
    int? revision,
    AgentTranscript? transcript,
    LlmUsage? usage,
    int? modelTurns,
    int? toolAttempts,
    int? updatedAtMicros,
    List<LlmContinuationEntry>? continuationEntries,
    AgentCompactionState? compactionState,
    bool clearCompactionState = false,
    AgentTokenAccountingState? tokenAccounting,
  }) {
    final nextTranscript = transcript ?? this.transcript;
    final nextUsage = usage ?? this.usage;
    final nextAccounting =
        tokenAccounting ??
        (this.tokenAccounting.generation == 0
            ? AgentTokenAccountingState.legacy(
                transcriptMessageCount: nextTranscript.messages.length,
                usage: nextUsage,
              )
            : this.tokenAccounting);
    return AgentSessionRecord(
      id: id,
      revision: revision ?? this.revision,
      definition: definition,
      transcript: nextTranscript,
      usage: nextUsage,
      modelTurns: modelTurns ?? this.modelTurns,
      toolAttempts: toolAttempts ?? this.toolAttempts,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros ?? this.updatedAtMicros,
      continuationEntries: continuationEntries ?? this.continuationEntries,
      compactionState: clearCompactionState
          ? null
          : (compactionState ?? this.compactionState),
      tokenAccounting: nextAccounting,
    );
  }

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'id': id.toJson(),
      'revision': revision,
      'definition': definition.toJson(),
      'transcript': transcript.toJson(),
      'usage': usage.toJson(),
      'modelTurns': modelTurns,
      'toolAttempts': toolAttempts,
      'createdAtMicros': createdAtMicros,
      'updatedAtMicros': updatedAtMicros,
      'continuationEntries': continuationEntries
          .map((entry) => entry.toJson())
          .toList(),
    };
    if (compactionState != null) {
      fields['compactionState'] = compactionState!.toJson();
    }
    if (tokenAccounting.generation > 0) {
      fields['tokenAccounting'] = tokenAccounting.toJson();
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSessionRecord &&
          other.id == id &&
          other.revision == revision &&
          other.definition == definition &&
          other.transcript == transcript &&
          other.usage == usage &&
          other.modelTurns == modelTurns &&
          other.toolAttempts == toolAttempts &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          listEquals(other.continuationEntries, continuationEntries) &&
          other.compactionState == compactionState &&
          other.tokenAccounting == tokenAccounting;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    definition,
    transcript,
    usage,
    modelTurns,
    toolAttempts,
    createdAtMicros,
    updatedAtMicros,
    Object.hashAll(continuationEntries),
    compactionState,
    tokenAccounting,
  );

  @override
  String toString() =>
      'AgentSessionRecord(${id.value}, rev=$revision, '
      'continuations: ${continuationEntries.length}, '
      'compaction: ${compactionState?.generation ?? 0}, '
      'accounting: ${tokenAccounting.generation})';
}

LlmWireFamily _wireFamilyFor(
  AgentDefinition definition,
  List<LlmContinuationEntry> entries,
) {
  for (final model in BuiltInLlmCatalog.models) {
    if (model.ref == definition.model) {
      return model.wireFamily;
    }
  }
  return entries.first.state.wireFamily;
}

final class AgentSessionCodec {
  const AgentSessionCodec();

  Map<String, Object?> encode(AgentSessionRecord record) =>
      freezeJsonMap(record.toJson());

  AgentSessionRecord decode(Object? json) => AgentSessionRecord.fromJson(json);
}
