import 'dart:convert';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/support/application/support_context_precondition.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/support_harness.dart';

void main() {
  test(
    'server success without exact successful SDK delivery, malformed result, stale/wrong scope never establishes consumption',
    () async {
      final h = SupportHarness(withMcp: false);
      addTearDown(h.close);
      final ticket = await h.create();
      final other = await h.create(subject: 'Другой тикет');
      final context = h.scopes.begin(ticket);
      final payloads = <String, Map<String, Object?>>{};
      for (final tool in ['get_user_context', 'get_ticket']) {
        final payload = <String, Object?>{
          'contextReceipt': newSupportId(),
          'ticketId': ticket.id,
          'sessionId': ticket.sessionId.value,
          'ticketRevision': ticket.revision,
          'snapshotObservedAt': ticket.snapshot.observedAt,
          'data': 'server-executed',
        };
        h.scopes.recordRead(context.scopeKey, tool, payload);
        payloads[tool] = payload;
      }
      AgentFinalAnswerDraft draft({
        String mode = 'success',
      }) => AgentFinalAnswerDraft(
        text: 'draft',
        finishReason: LlmFinishReason.stop,
        repairAttempt: false,
        request: LlmRequest(
          model: h.service.definition.model,
          generation: LlmGenerationConfig.defaults,
          context: LlmContext(
            messages: [
              LlmMessage(
                role: LlmMessageRole.user,
                parts: [LlmTextPart('question')],
              ),
              for (final tool in payloads.keys) ...[
                LlmMessage(
                  role: LlmMessageRole.assistant,
                  parts: [
                    LlmToolCallPart(
                      callId: ToolCallId(tool),
                      name: 'mcp_support__$tool',
                      arguments: '{}',
                    ),
                  ],
                ),
                if (mode != 'lost')
                  LlmMessage(
                    role: LlmMessageRole.tool,
                    parts: [
                      LlmToolResultPart(
                        callId: ToolCallId(tool),
                        content: mode == 'malformed'
                            ? '{'
                            : jsonEncode(
                                mode == 'error'
                                    ? {
                                        'error': 'SDK delivery failed',
                                        'details': {
                                          'structuredContent': payloads[tool],
                                        },
                                      }
                                    : {
                                        'structuredContent': mode == 'changed'
                                            ? {
                                                ...payloads[tool]!,
                                                'data': 'modified',
                                              }
                                            : payloads[tool],
                                      },
                              ),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ).snapshot(),
      );
      for (final mode in ['lost', 'malformed', 'error', 'changed']) {
        expect(
          () => requireSupportContext(
            draft(mode: mode),
            h.scopes,
            context,
            ticket,
            CancellationSource().token,
          ),
          throwsA(isA<AgentException>()),
          reason: mode,
        );
      }
      requireSupportContext(
        draft(),
        h.scopes,
        context,
        ticket,
        CancellationSource().token,
      );
      expect(
        () => requireSupportContext(
          draft(),
          h.scopes,
          context,
          other,
          CancellationSource().token,
        ),
        throwsA(isA<AgentException>()),
      );
      final freshContext = h.scopes.begin(ticket);
      expect(
        () => requireSupportContext(
          draft(),
          h.scopes,
          freshContext,
          ticket,
          CancellationSource().token,
        ),
        throwsA(isA<AgentException>()),
      );
      h.scopes.end(context);
      expect(
        () => requireSupportContext(
          draft(),
          h.scopes,
          context,
          ticket,
          CancellationSource().token,
        ),
        throwsA(isA<AgentException>()),
      );
    },
  );
}
