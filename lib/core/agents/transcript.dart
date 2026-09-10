import '../llm/json.dart';
import '../llm/messages.dart';
import '../llm/usage.dart';
import 'definition.dart';
import 'events.dart';
import 'ids.dart';

final class AgentTranscript {
  AgentTranscript({List<LlmMessage> messages = const <LlmMessage>[]})
    : messages = List<LlmMessage>.unmodifiable(List<LlmMessage>.from(messages));

  factory AgentTranscript.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentTranscript(
      messages: requireList(map, 'messages').map(LlmMessage.fromJson).toList(),
    );
  }

  static const jsonType = 'agent.transcript';

  final List<LlmMessage> messages;

  AgentTranscript append(LlmMessage message) {
    return AgentTranscript(messages: <LlmMessage>[...messages, message]);
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'messages': messages.map((message) => message.toJson()).toList(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTranscript && listEquals(other.messages, messages);

  @override
  int get hashCode => Object.hashAll(messages);
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
  });

  final AgentSessionId id;
  final AgentDefinition definition;
  final AgentSessionLifecycle lifecycle;
  final AgentTranscript transcript;
  final LlmUsage usage;
  final int modelTurns;
  final int toolAttempts;
  final int revision;
}
