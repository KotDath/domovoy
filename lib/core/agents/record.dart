import '../llm/catalog.dart';
import '../llm/continuation.dart';
import '../llm/errors.dart';
import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/usage.dart';
import 'definition.dart';
import 'errors.dart';
import 'ids.dart';
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
  }) : continuationEntries = List<LlmContinuationEntry>.unmodifiable(
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
    if (this.continuationEntries.isEmpty) {
      return;
    }
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

  factory AgentSessionRecord.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentSessionRecord(
      id: AgentSessionId.fromJson(map['id']),
      revision: requireInt(map, 'revision'),
      definition: AgentDefinition.fromJson(map['definition']),
      transcript: AgentTranscript.fromJson(map['transcript']),
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

  AgentSessionRecord copyWith({
    int? revision,
    AgentTranscript? transcript,
    LlmUsage? usage,
    int? modelTurns,
    int? toolAttempts,
    int? updatedAtMicros,
    List<LlmContinuationEntry>? continuationEntries,
  }) {
    return AgentSessionRecord(
      id: id,
      revision: revision ?? this.revision,
      definition: definition,
      transcript: transcript ?? this.transcript,
      usage: usage ?? this.usage,
      modelTurns: modelTurns ?? this.modelTurns,
      toolAttempts: toolAttempts ?? this.toolAttempts,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros ?? this.updatedAtMicros,
      continuationEntries: continuationEntries ?? this.continuationEntries,
    );
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
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
    },
  );

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
          listEquals(other.continuationEntries, continuationEntries);

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
  );

  @override
  String toString() =>
      'AgentSessionRecord(${id.value}, rev=$revision, '
      'continuations: ${continuationEntries.length})';
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
