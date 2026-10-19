import 'dart:convert';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/support/support_mcp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/support_harness.dart';

void main() {
  test(
    'actual HTTP SDK context is bound to one ticket, rejects model IDs and revoked scope',
    () async {
      final h = SupportHarness();
      addTearDown(h.close);
      final ticket = await h.create(description: 'Выбранное обращение');
      final other = await h.create(description: 'Не передавать другой тикет');
      await h.mcp!.initialize();
      final context = h.scopes.begin(ticket);
      final host = h.mcp!.host;
      final result = await host.callTool(
        modelToolName: 'mcp_support__get_ticket',
        arguments: {},
        cancellation: CancellationSource().token,
        requestMeta: {'domovoy/runScope': context.scopeKey},
      );
      expect(result.isError, false);
      expect(
        (result.structuredContent! as Map)['ticket'],
        containsPair('id', ticket.id),
      );
      expect(
        jsonEncode(result.structuredContent),
        isNot(contains(other.description)),
      );
      final injection = await host.callTool(
        modelToolName: 'mcp_support__get_ticket',
        arguments: {'ticketId': other.id},
        cancellation: CancellationSource().token,
        requestMeta: {'domovoy/runScope': context.scopeKey},
      );
      expect(injection.isError, true);
      h.scopes.end(context);
      final revoked = await host.callTool(
        modelToolName: 'mcp_support__get_user_context',
        arguments: {},
        cancellation: CancellationSource().token,
        requestMeta: {'domovoy/runScope': context.scopeKey},
      );
      expect(revoked.isError, true);
    },
  );

  test(
    'history is bounded plain text with provenance; reasoning/tool payloads excluded',
    () {
      final messages = <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.assistant,
          parts: [
            LlmReasoningPart('PRIVATE_REASONING'),
            LlmToolCallPart(
              callId: ToolCallId('old'),
              name: 'tool',
              arguments: 'TOOL_SECRET',
            ),
          ],
        ),
        LlmMessage(
          role: LlmMessageRole.tool,
          parts: [
            LlmToolResultPart(
              callId: ToolCallId('old'),
              content: 'PRIVATE_TOOL',
            ),
          ],
        ),
        for (var i = 0; i < 20; i++)
          LlmMessage(
            role: i.isEven ? LlmMessageRole.user : LlmMessageRole.assistant,
            parts: [LlmTextPart('text $i ${'x' * 2000}')],
          ),
      ];
      final history = supportHistory(AgentTranscript(messages: messages));
      expect(history.length, lessThanOrEqualTo(12));
      expect(
        history
            .map((r) => (r['text'] as String).length)
            .reduce((a, b) => a + b),
        lessThanOrEqualTo(10000),
      );
      expect(history.first['messageIndex'], greaterThan(1));
      expect(history.last['origin'], 'assistant_hypothesis');
      expect(history.last['truncated'], true);
      expect(jsonEncode(history), isNot(contains('PRIVATE')));
      expect(jsonEncode(history), isNot(contains('TOOL_SECRET')));
    },
  );
}
