import 'dart:convert';
import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/support/support.dart';

/// Execution receipts are necessary but insufficient: require their exact
/// successful structured payloads in actual current-run tool result messages.
/// A handler followed by SDK/bridge failure leaves only a failure envelope,
/// which cannot satisfy this check. Provider text/arguments never count.
void requireSupportContext(
  AgentFinalAnswerDraft draft,
  SupportRunScopes scopes,
  AgentRunToolContext context,
  SupportTicket ticket,
  CancellationToken cancellation,
) {
  if (cancellation.isCancelled ||
      !identical(scopes.resolve(context.scopeKey), ticket)) {
    throwAgent(AgentErrorKind.cancelled, 'Контекст обращения отозван.');
  }
  final calls = <String, String>{};
  final delivered = <String>{};
  for (final message in draft.request.context.messages) {
    if (message.role == LlmMessageRole.assistant) {
      for (final call in message.parts.whereType<LlmToolCallPart>()) {
        if (supportToolIds.contains(call.name)) {
          calls[call.callId.value] = call.name;
        }
      }
    } else if (message.role == LlmMessageRole.tool) {
      for (final result in message.parts.whereType<LlmToolResultPart>()) {
        final name = calls[result.callId.value];
        if (name == null) continue;
        try {
          final envelope = jsonDecode(result.content) as Map<String, dynamic>;
          if (envelope.containsKey('error') ||
              envelope['contentTruncated'] == true) {
            continue;
          }
          final payload = envelope['structuredContent'] as Map<String, dynamic>;
          if (payload['ticketId'] == ticket.id &&
              payload['sessionId'] == ticket.sessionId.value &&
              payload['ticketRevision'] == ticket.revision &&
              payload['snapshotObservedAt'] == ticket.snapshot.observedAt &&
              scopes.delivered(
                context.scopeKey,
                name.replaceFirst('mcp_support__', ''),
                payload,
              )) {
            delivered.add(name);
          }
        } on Object {
          /* Unusable or failed delivery is never evidence. */
        }
      }
    }
  }
  if (draft.finishReason != LlmFinishReason.stop ||
      !delivered.containsAll(supportToolIds)) {
    throwAgent(
      AgentErrorKind.protocol,
      'Ответ поддержки не принят: нужны успешные MCP-вызовы контекста пользователя и обращения в текущем запуске. Проверьте инструменты и повторите вопрос.',
    );
  }
}
