import 'dart:convert';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import '../../core/agents/agents.dart';
import '../../core/llm/llm.dart';
import '../../core/support/support.dart';
import '../mcp/local/local_mcp_definition.dart';

final class SupportMcpServerFactory implements LocalMcpServerFactory {
  SupportMcpServerFactory({
    required this.tickets,
    required this.sessions,
    required this.scopes,
  });
  final SupportRepository tickets;
  final AgentSessionRepository sessions;
  final SupportRunScopes scopes;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: 'support',
    displayName: 'Поддержка Domovoy',
    version: '1.0.0',
    registerTools: (server) {
      for (final name in ['get_user_context', 'get_ticket']) {
        server.registerTool(
          name,
          description: name == 'get_user_context'
              ? 'Read the local owner and the explicit technical snapshot of this ticket. No credentials.'
              : 'Read only this run’s selected ticket and bounded user/assistant text history. No other tickets, reasoning or tool payloads.',
          inputSchema: sdk.ToolInputSchema(
            properties: {},
            additionalProperties: false,
          ),
          annotations: const sdk.ToolAnnotations(
            readOnlyHint: true,
            destructiveHint: false,
            openWorldHint: false,
          ),
          callback: (args, extra) async {
            try {
              final key = extra.meta?['domovoy/runScope'] as String?;
              final bound = scopes.resolve(key);
              if (extra.signal.aborted || bound == null || args.isNotEmpty) {
                throw StateError('No scope');
              }
              final ticket = await tickets.load(bound.id);
              if (ticket == null ||
                  !ticket.ready ||
                  ticket.revision != bound.revision ||
                  ticket.sessionId != bound.sessionId ||
                  ticket.ownerId != bound.ownerId) {
                throw StateError('Ticket unavailable');
              }
              final result = <String, Object?>{
                'contextReceipt': newSupportId(),
                'ticketId': ticket.id,
                'sessionId': ticket.sessionId.value,
                'ticketRevision': ticket.revision,
                'snapshotObservedAt': ticket.snapshot.observedAt,
              };
              if (name == 'get_user_context') {
                result.addAll({
                  'ownerId': ticket.ownerId,
                  'kind': 'local_owner',
                  'snapshot': ticket.snapshot.toJson(),
                  'snapshotNotice':
                      'Explicit observation; may be stale. Configuration is not proof of availability.',
                });
              } else {
                final record = await sessions.load(ticket.sessionId);
                if (record == null ||
                    record.definition.id != AgentId('product-support')) {
                  throw StateError('Session unavailable');
                }
                result.addAll({
                  'ticket': ticket.toJson(),
                  'history': supportHistory(record.transcript),
                  'historyPolicy':
                      'Most recent 12 user/assistant text messages, 1500 characters each, 10000 total; reasoning and tools excluded. Previous assistant text is not documentation.',
                });
              }
              if (extra.signal.aborted ||
                  !identical(scopes.resolve(key), bound)) {
                throw StateError('Scope revoked');
              }
              scopes.recordRead(key!, name, result);
              return sdk.CallToolResult(
                // Receipt alone is insufficient: admission also correlates
                // the delivered SDK structured result with this scope.
                content: [sdk.TextContent(text: jsonEncode(result))],
                structuredContent: result,
              );
            } on Object {
              return sdk.CallToolResult(
                isError: true,
                content: [
                  sdk.TextContent(
                    text:
                        'Контекст поддержки недоступен: обращение или scope запуска недействительны.',
                  ),
                ],
              );
            }
          },
        );
      }
    },
  );
}

List<Map<String, Object?>> supportHistory(AgentTranscript transcript) {
  final result = <Map<String, Object?>>[];
  var remaining = 10000;
  for (
    var i = transcript.messages.length - 1;
    i >= 0 && result.length < 12 && remaining > 0;
    i--
  ) {
    final message = transcript.messages[i];
    if (message.role == LlmMessageRole.tool) continue;
    final text = message.parts
        .whereType<LlmTextPart>()
        .map((p) => p.text)
        .join('\n');
    if (text.isEmpty) continue;
    final limit = remaining < 1500 ? remaining : 1500;
    final excerpt = text.length > limit ? text.substring(0, limit) : text;
    remaining -= excerpt.length;
    result.add({
      'role': message.role.name,
      'origin': message.role == LlmMessageRole.user
          ? 'user_statement'
          : 'assistant_hypothesis',
      'messageIndex': i,
      'text': excerpt,
      'truncated': excerpt.length != text.length,
    });
  }
  return result.reversed.toList();
}
