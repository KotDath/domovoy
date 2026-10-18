import 'dart:async';
import 'dart:convert';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/support/application/support_catalog.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/support/support_manual.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/features/support/application/support_run_preparer.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/agent_harness.dart';
import '../../../support/rag_fakes.dart';
import '../../../support/support_harness.dart';

void main() {
  const userTool = 'mcp_support__get_user_context';
  const ticketTool = 'mcp_support__get_ticket';
  List<List<LlmEvent>> successful({String suffix = ''}) => [
    toolTurn(name: userTool, callId: 'u$suffix'),
    toolTurn(name: ticketTool, callId: 't$suffix'),
    textTurn('На Android используйте Streamable HTTPS (руководство MCP).'),
  ];

  test(
    'real composition preserves other streams, support uses HTTP, SDK results reach safe isolated provider and replay',
    () async {
      final h = SupportHarness(
        turns: [
          ...successful(),
          ...successful(suffix: 'follow'),
        ],
      );
      addTearDown(h.close);
      final first = await h.create(description: 'Секрет первого обращения');
      final second = await h.create(description: 'Описание второго обращения');
      await h.controller.initialize();
      await h.controller.select(second);
      final result = await h.controller.send('Какой транспорт выбрать?');
      expect(result.isSuccess, true, reason: h.chat.state.error?.message);
      expect(
        h.mcp!.localServers.endpointFor('support'),
        isA<LocalMcpHttpEndpoint>(),
      );
      expect(
        h.mcp!.localServers.endpointFor('arxiv'),
        isA<LocalMcpStreamEndpoint>(),
      );
      expect(
        h.mcp!.localServers.endpointFor('digest'),
        isA<LocalMcpStreamEndpoint>(),
      );
      final finalRequest = h.provider.requests[2];
      expect(
        finalRequest.context.tools.map((t) => t.name).toSet(),
        supportToolIds,
      );
      final encoded = jsonEncode(finalRequest.snapshot().toJson());
      expect(encoded, contains('Описание второго обращения'));
      expect(encoded, isNot(contains('Секрет первого обращения')));
      expect(encoded, contains('DOCUMENT_EVIDENCE'));
      expect(encoded, contains('android'));
      expect(encoded, isNot(contains('domovoy/runScope')));
      expect(h.controller.sources.single['protocol'], 'm1');
      expect(h.controller.sources.single['fingerprint'], 'fake-v1');
      final record = (await h.sessions.load(second.sessionId))!;
      final results = record.transcript.messages
          .expand((m) => m.parts)
          .whereType<LlmToolResultPart>()
          .toList();
      expect(results, hasLength(2));
      final content = jsonDecode(results.last.content) as Map;
      expect(content['structuredContent']['ticket']['id'], second.id);
      expect(content['structuredContent']['ticket']['id'], isNot(first.id));
      expect(record.modelTurns, 3);
      // A follow-up uses the same persisted session, fresh current-run scope and
      // bounded plain history delivered through MCP, rather than old payloads.
      expect(
        (await h.controller.send('А на моём устройстве?')).isSuccess,
        true,
      );
      final follow = jsonEncode(h.provider.requests.last.snapshot().toJson());
      expect(follow, contains('user_statement'));
      expect(follow, contains('assistant_hypothesis'));
      expect(h.provider.requests[3].context.messages, hasLength(1));
      final freshStore = JsonlAgentSessionStore(storage: h.sessions.storage);
      expect(
        (await freshStore.load(
          second.sessionId,
        ))!.transcript.messages.last.parts.whereType<LlmTextPart>().single.text,
        contains('Streamable HTTPS'),
      );
      expect(
        (await SupportSessionCatalog(h.sessions).list()).available,
        isEmpty,
      );
      final normal = ChatWorkspaceController(
        runtime: h.runtime,
        definition: testDefinition(),
        catalog: h.sessions,
        repository: h.sessions,
        registry: h.runtime.registry,
      );
      addTearDown(normal.dispose);
      expect((await normal.restoreChat(second.sessionId)).isSuccess, false);
    },
  );

  test(
    'server executed through HTTP but structured delivery omitted by bridge cannot satisfy final precondition',
    () async {
      final h = SupportHarness(turns: successful());
      addTearDown(h.close);
      final ticket = await h.create();
      await h.mcp!.initialize();
      h.mcp!.bridge.detachFrom(h.runtime.tools);
      final damaged = McpAgentToolBridge(
        host: h.mcp!.host,
        digestScopeConnectionIds: {'support'},
        mapper: const McpToolResultMapper(maxStructuredCharacters: 16),
      );
      damaged.attachTo(h.runtime.tools);
      addTearDown(() {
        damaged.detachFrom(h.runtime.tools);
        damaged.dispose();
      });
      await h.controller.initialize();
      await h.controller.select(ticket);
      expect((await h.controller.send('Вопрос')).isSuccess, false);
      final finalRequest = h.provider.requests.last;
      final results = finalRequest.context.messages
          .expand((m) => m.parts)
          .whereType<LlmToolResultPart>();
      expect(results, hasLength(2));
      for (final result in results) {
        final envelope = jsonDecode(result.content) as Map;
        // Content text proves actual server result crossed the SDK, but its
        // structured delivery was truncated, so the receipt cannot be accepted.
        expect(jsonEncode(envelope['content']), contains('contextReceipt'));
        expect(envelope['structuredContent']['omitted'], true);
      }
      expect(h.preparer.error, contains('MCP'));
    },
  );

  for (final mode in ['none', 'one', 'error']) {
    test(
      '$mode context results reject final answer and reasoning, retain actual usage/tools in fresh replay',
      () async {
        final turns = <List<LlmEvent>>[
          if (mode != 'none')
            toolTurn(
              name: userTool,
              callId: 'u',
              usage: LlmUsage(inputTokens: 1, outputTokens: 1),
            ),
          if (mode == 'error')
            toolTurn(
              name: ticketTool,
              callId: 'bad',
              arguments: '{"ticketId":"other"}',
              usage: LlmUsage(inputTokens: 1, outputTokens: 1),
            ),
          [
            const LlmReasoningDelta('REJECTED_REASONING'),
            ...textTurn(
              'REJECTED_FINAL',
              usage: LlmUsage(inputTokens: 7, outputTokens: 4),
            ),
          ],
        ];
        final h = SupportHarness(turns: turns);
        addTearDown(h.close);
        final ticket = await h.create();
        await h.controller.initialize();
        await h.controller.select(ticket);
        final result = await h.controller.send('Вопрос');
        expect(result.isSuccess, false);
        expect(h.preparer.error, contains('MCP'));
        final fresh = JsonlAgentSessionStore(storage: h.sessions.storage);
        final record = (await fresh.load(ticket.sessionId))!;
        final transcript = jsonEncode(record.transcript.toJson());
        expect(transcript, isNot(contains('REJECTED_FINAL')));
        expect(transcript, isNot(contains('REJECTED_REASONING')));
        expect(record.modelTurns, turns.length);
        expect(
          record.usage.outputTokens,
          mode == 'none'
              ? 4
              : mode == 'one'
              ? 5
              : 6,
        );
        if (mode != 'none') expect(transcript, contains('structuredContent'));
      },
    );
  }

  test(
    'status/snapshot changes are explicit and resolved ticket cannot send until reopened',
    () async {
      final h = SupportHarness(turns: successful());
      addTearDown(h.close);
      final ticket = await h.create();
      await h.controller.initialize();
      await h.controller.select(ticket);
      await h.controller.setStatus(SupportStatus.awaitingVerification);
      await h.controller.setStatus(SupportStatus.resolved);
      expect((await h.tickets.load(ticket.id))!.status, SupportStatus.resolved);
      await h.controller.send('Не отправляется');
      expect(h.provider.requests, isEmpty);
      await h.controller.setStatus(SupportStatus.open);
      expect((await h.controller.send('Продолжим')).isSuccess, true);
      expect(
        (await h.tickets.load(ticket.id))!.snapshot.toJson(),
        supportSnapshot.toJson(),
      );
      expect((await h.tickets.load(ticket.id))!.status, SupportStatus.open);
    },
  );

  test(
    'index reuses content/model identity and rebuilds for changed model',
    () async {
      final models = _CountingModels();
      final h = SupportHarness(
        models: models,
        turns: [
          ...successful(),
          ...successful(suffix: '2'),
          ...successful(suffix: '3'),
        ],
      );
      addTearDown(h.close);
      final ticket = await h.create();
      await h.controller.initialize();
      await h.controller.select(ticket);
      expect((await h.controller.send('Первый вопрос')).isSuccess, true);
      final indexed = models.documentEmbeddings;
      expect(indexed, greaterThan(0));
      expect((await h.controller.send('Второй вопрос')).isSuccess, true);
      expect(models.documentEmbeddings, indexed);
      models.version = 'changed';
      expect((await h.controller.send('Третий вопрос')).isSuccess, true);
      expect(models.documentEmbeddings, greaterThan(indexed));
      expect(h.controller.sources.last['fingerprint'], 'changed');
      models.fail = true;
      expect(
        (await h.controller.send('Без embedding сервиса')).isSuccess,
        false,
      );
      expect(h.provider.requests.length, 9);
      expect(h.preparer.error, contains('эмбеддингов'));
    },
  );

  test(
    'manual content invalidation rebuilds without touching another corpus',
    () async {
      final models = _CountingModels();
      var manualText = '# FAQ\nИсходный текст руководства.';
      final h = SupportHarness(
        models: models,
        turns: [
          ...successful(),
          ...successful(suffix: 'changed'),
        ],
        manualLoader: () async => SupportManual('same-human-revision', [
          RagDocument(
            source: 'domovoy://manual/test',
            title: 'FAQ',
            text: manualText,
          ),
        ]),
      );
      addTearDown(h.close);
      final repository = JsonlRagRepository(h.ragStorage);
      await repository.saveDocuments('user-project', 'personal-corpus', [
        RagDocument(
          source: 'private',
          title: 'PRIVATE',
          text: 'Never used by support',
        ),
      ]);
      final ticket = await h.create();
      await h.controller.initialize();
      await h.controller.select(ticket);
      expect((await h.controller.send('Вопрос')).isSuccess, true);
      final generation = (await repository.loadIndex(
        supportRagProject,
        supportRagCorpus,
        ChunkStrategy.structure,
      ))!.generation;
      manualText = '# FAQ\nОбновлённый текст руководства.';
      expect((await h.controller.send('Другой вопрос')).isSuccess, true);
      expect(
        (await repository.loadIndex(
          supportRagProject,
          supportRagCorpus,
          ChunkStrategy.structure,
        ))!.generation,
        isNot(generation),
      );
      expect(
        (await repository.documents(
          'user-project',
          'personal-corpus',
        )).single.text,
        'Never used by support',
      );
      expect(
        jsonEncode(h.provider.requests.last.snapshot().toJson()),
        isNot(contains('Never used by support')),
      );
    },
  );

  test(
    'cancel while building index does not dispatch provider and can retry',
    () async {
      final models = _CountingModels()..block = Completer<void>();
      final h = SupportHarness(models: models);
      addTearDown(h.close);
      final ticket = await h.create();
      await h.controller.initialize();
      await h.controller.select(ticket);
      final sending = h.controller.send('Вопрос');
      await models.started.future;
      final stopping = h.controller.stop();
      models.block!.complete();
      await stopping;
      await sending;
      expect(h.provider.requests, isEmpty);
      expect(h.preparer.busy, false);
      expect(h.preparer.progress, contains('отменена'));
      expect((await h.tickets.load(ticket.id))!.ready, true);
    },
  );
}

final class _CountingModels implements RagModelProvider {
  final delegate = FakeRagModels();
  int documentEmbeddings = 0;
  String version = 'fake-v1';
  bool fail = false;
  Completer<void>? block;
  final started = Completer<void>();
  @override
  Future<RagModelInfo> health(CancellationToken cancellation) async {
    if (fail) throw StateError('offline');
    return RagModelInfo(version, 2, 'test');
  }

  @override
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken cancellation, {
    bool reranker = false,
  }) => delegate.tokenize(text, cancellation);
  @override
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken cancellation, {
    bool query = false,
  }) async {
    if (!query) documentEmbeddings += texts.length;
    if (!started.isCompleted) started.complete();
    if (block != null) await block!.future;
    checkRagCancellation(cancellation.isCancelled);
    return delegate.embed(texts, model, cancellation, query: query);
  }
}
