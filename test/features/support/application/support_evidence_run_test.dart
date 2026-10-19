import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/index_builder.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/support/application/support_run_preparer.dart';
import 'package:domovoy/infrastructure/llm/openai_compatible/chat_completions_dialect.dart';
import 'package:domovoy/infrastructure/llm/openai_compatible/openai_chat_completions_llm_provider.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/support/support_manual.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

import '../../../support/agent_harness.dart';
import '../../../support/support_evidence_fixture.dart';
import '../../../support/support_harness.dart';

void main() {
  test(
    'ordinary multipart query reaches production wire assembly with exact saved neighbor evidence; shared M1 unchanged',
    () async {
      final base = fixture(
        texts: [
          '# Notifications\n',
          '## Channels\nOpen Preferences to enable a delivery channel.\n',
          '## Quiet hours\nSet the schedule in the notification composer.\n',
          '## Reset\nRestore default settings.\n',
          '## Advanced\nAdditional configuration.\n',
          '## Reference\nMore information.\n',
        ],
      );
      final models = QueryOnlyModels();
      final manual = SupportManual(
        'ordinary-manual',
        base.documents,
        packageVersion: 'test',
      );
      final index = RagIndex(
        fingerprint: 'embedding',
        dimension: 2,
        strategy: ChunkStrategy.structure,
        chunks: base.chunks,
        documents: base.documents,
        elapsedMs: 0,
        generation: ragIndexIdentity(
          base.documents,
          QueryOnlyModels.info,
          ChunkStrategy.structure,
          manual.revision,
        ),
        // Actual local dense search picks these five, leaving the needed sibling
        // outside top5. No query text classifier or preselected hit list.
        vectors: [
          for (var i = 0; i < base.chunks.length; i++)
            i == 2 ? [-1, 0] : [1, i == 1 ? 0 : i + 1],
        ],
      );
      final h = SupportHarness(
        models: models,
        manualLoader: () async => manual,
        turns: [
          toolTurn(name: 'mcp_support__get_user_context', callId: 'u'),
          toolTurn(name: 'mcp_support__get_ticket', callId: 't'),
          textTurn('Offline boundary verification; no answer-quality claim.'),
        ],
      );
      addTearDown(h.close);
      final repository = JsonlRagRepository(h.ragStorage);
      await repository.saveDocuments(
        supportRagProject,
        supportRagCorpus,
        index.documents,
      );
      await repository.publishIndex(supportRagProject, supportRagCorpus, index);
      final ticket = await h.create(
        subject: 'Notification setup',
        description: 'Channels and scheduling',
      );
      await h.controller.initialize();
      await h.controller.select(ticket);
      const question =
          'How do I enable a delivery channel and configure quiet hours?';
      final result = await h.controller.send(question);
      expect(result.isSuccess, true, reason: h.chat.state.error?.message);
      expect(h.provider.requests, hasLength(3));
      final traces = await JsonlRagTraceRepository(
        h.ragStorage,
      ).list(supportRagProject, ticket.sessionId.value);
      final trace = traces.single;
      final context = trace['context'] as String;
      final original = h.preparer.evidence!.turn;
      expect(original.evidence, hasLength(5));
      expect(original.context, isNot(contains('Set the schedule')));
      expect(
        context,
        contains('Set the schedule in the notification composer.'),
      );
      expect(
        trace['candidates'].take(5).toList(),
        original.toJson()['candidates'],
      );
      expect(
        trace['final_evidence_ids'].toSet().length,
        trace['final_evidence_ids'].length,
      );
      expect(trace['context_bytes'], utf8.encode(context).length);
      expect(utf8.encode(context).length, lessThanOrEqualTo(24000));
      for (final request in h.provider.requests) {
        expect(request.context.systemPrompt, contains(context));
        final body = buildChatCompletionsBody(
          request: request,
          model: BuiltInLlmCatalog.deepSeekV4FlashModel,
          dialect: ChatCompletionsDialect.deepSeek,
        );
        final system =
            (body['messages'] as List).firstWhere(
                  (m) => m['role'] == 'system',
                )['content']
                as String;
        expect(system, contains(context));
        final sent = evidencePayload(
          system.substring(system.indexOf('UNTRUSTED_DOCUMENT_EVIDENCE_JSON')),
        );
        expect(sent, contains(containsPair('text', index.chunks[2].text)));
      }
      final shared = await RagTurnCoordinator(
        repository: repository,
        models: models,
      ).prepare(original.request, CancellationSource().token);
      expect(shared.context, original.context);
      expect(
        shared.evidence.map((e) => e.chunk.id),
        original.evidence.map((e) => e.chunk.id),
      );
      // Safe fixture-only capture retained in gate log, explicitly offline.
      debugPrint(
        jsonEncode({
          'kind': 'offline_production_assembled_request_capture',
          'wire_body': buildChatCompletionsBody(
            request: h.provider.requests.last,
            model: BuiltInLlmCatalog.deepSeekV4FlashModel,
            dialect: ChatCompletionsDialect.deepSeek,
          ),
          'persisted_trace': trace,
        }),
      );
    },
  );
}

class QueryOnlyModels implements RagModelProvider {
  static const info = RagModelInfo('embedding', 2, 'offline fixture');
  @override
  Future<RagModelInfo> health(CancellationToken cancellation) async => info;
  @override
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken cancellation, {
    bool query = false,
  }) async {
    if (!query) throw StateError('An immutable index must be reused');
    return [
      for (final _ in texts) [1, 0],
    ];
  }

  @override
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken cancellation, {
    bool reranker = false,
  }) async => throw StateError('No rebuilding in this fixture');
}
