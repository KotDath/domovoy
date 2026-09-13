import '../llm/json.dart';
import '../llm/messages.dart';
import '../llm/usage.dart';
import 'compaction.dart';
import 'definition.dart';
import 'events.dart';
import 'ids.dart';
import 'selection.dart';
import 'token_accounting.dart';

final class AgentTranscript {
  AgentTranscript({
    List<LlmMessage> messages = const <LlmMessage>[],
    List<AgentTranscriptMessageId?>? messageIds,
  }) : messages = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(messages),
       ),
       messageIds = List<AgentTranscriptMessageId?>.unmodifiable(
         messageIds ??
             List<AgentTranscriptMessageId?>.filled(messages.length, null),
       ) {
    if (this.messageIds.length != this.messages.length) {
      throw ArgumentError(
        'Transcript message identities must align with messages.',
      );
    }
    final assigned = <AgentTranscriptMessageId>{};
    if (this.messageIds.whereType<AgentTranscriptMessageId>().any(
      (id) => !assigned.add(id),
    )) {
      throw ArgumentError('Transcript message identities must be unique.');
    }
  }

  factory AgentTranscript.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentTranscript(
      messages: requireList(map, 'messages').map(LlmMessage.fromJson).toList(),
    );
  }

  static const jsonType = 'agent.transcript';

  final List<LlmMessage> messages;
  final List<AgentTranscriptMessageId?> messageIds;

  AgentTranscript append(
    LlmMessage message, {
    AgentTranscriptMessageId? messageId,
  }) => AgentTranscript(
    messages: <LlmMessage>[...messages, message],
    messageIds: <AgentTranscriptMessageId?>[...messageIds, messageId],
  );

  AgentTranscript withMessageIds(List<AgentTranscriptMessageId?> identities) =>
      AgentTranscript(messages: messages, messageIds: identities);

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'messages': messages.map((message) => message.toJson()).toList(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTranscript &&
          listEquals(other.messages, messages) &&
          listEquals(other.messageIds, messageIds);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(messages), Object.hashAll(messageIds));
}

final class AgentSessionSnapshot {
  AgentSessionSnapshot({
    required this.id,
    required this.definition,
    required this.lifecycle,
    required this.transcript,
    required this.usage,
    required this.modelTurns,
    required this.toolAttempts,
    required this.revision,
    required this.compactionState,
    AgentSessionSelection? selection,
    this.title,
    AgentTokenAccountingSnapshot? tokenAccounting,
  }) : selection =
           selection ?? AgentSessionSelection.fromDefinition(definition),
       tokenAccounting =
           tokenAccounting ??
           const AgentTokenAccountingProjector().project(
             state: AgentTokenAccountingState.legacy(
               transcriptMessageCount: transcript.messages.length,
               usage: usage,
             ),
           );

  final AgentSessionId id;
  final AgentDefinition definition;
  final AgentSessionLifecycle lifecycle;
  final AgentTranscript transcript;
  final LlmUsage usage;
  final int modelTurns;
  final int toolAttempts;
  final int revision;
  final AgentCompactionState? compactionState;
  final AgentSessionSelection selection;
  final String? title;
  final AgentTokenAccountingSnapshot tokenAccounting;

  int get compactionGeneration => compactionState?.generation ?? 0;
}
