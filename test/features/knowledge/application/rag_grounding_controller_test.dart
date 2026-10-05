import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_final_answer_gate.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';
import '../../../support/rag_grounding_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'wrong source and collapsed whitespace get exact repair data, never acceptance',
    () async {
      final f = RagGroundingFixture();
      final gate = RagFinalAnswerGate(
        turn: f.turn,
        persistDiagnostic: (_) async {},
      );
      final req = LlmRequest(
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        context: LlmContext(),
      ).snapshot();
      final broken = jsonEncode(
        f.json(id: 'wrong-id', quote: 'SOUL.md  допускает 4000 символов.'),
      );
      final result = await gate.evaluate(
        AgentFinalAnswerDraft(
          text: broken,
          request: req,
          finishReason: LlmFinishReason.stop,
          repairAttempt: false,
        ),
        CancellationSource().token,
      );
      expect(gate.accepted, isNull);
      final repair = (result as AgentFinalAnswerRejected).repairRequest!;
      final payload = jsonDecode(
        (repair.context.messages.single.parts.single as LlmTextPart).text,
      );
      final hint = (payload['exact_quote_repair_hints'] as List).single;
      expect(hint['suggested_chunk_id'], f.chunk.id);
      expect(hint['actual_exact_quote'], RagGroundingFixture.quote);
      final second = await gate.evaluate(
        AgentFinalAnswerDraft(
          text: broken,
          request: repair.snapshot(),
          finishReason: LlmFinishReason.stop,
          repairAttempt: true,
        ),
        CancellationSource().token,
      );
      expect((second as AgentFinalAnswerRejected).repairRequest, isNull);
      expect(gate.accepted, isNull);
    },
  );

  test(
    'unavailable history quote is explicitly removed, never broadened to old sources',
    () async {
      final f = RagGroundingFixture();
      final gate = RagFinalAnswerGate(
        turn: f.turn,
        persistDiagnostic: (_) async {},
      );
      final req = LlmRequest(
        model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
        context: LlmContext(),
      ).snapshot();
      final result = await gate.evaluate(
        AgentFinalAnswerDraft(
          text: jsonEncode(
            f.json(quote: 'A quotation from a different historical document.'),
          ),
          request: req,
          finishReason: LlmFinishReason.stop,
          repairAttempt: false,
        ),
        CancellationSource().token,
      );
      final repair = (result as AgentFinalAnswerRejected).repairRequest!;
      final payload = jsonDecode(
        (repair.context.messages.single.parts.single as LlmTextPart).text,
      );
      final hint = (payload['exact_quote_repair_hints'] as List).single;
      expect(hint['action'], 'remove_unmatched_citation');
      expect(hint.containsKey('actual_exact_quote'), false);
      expect(gate.accepted, isNull);
    },
  );

  test('repair hints preserve exact Markdown and line breaks', () async {
    const original =
        '**Spring forward.** If time does not exist,\n  the run is **skipped**.';
    final doc = RagDocument(source: 'dst.md', title: 'DST', text: original);
    final chunk = RagChunk(
      documentId: doc.id,
      documentRevision: doc.revision,
      source: doc.source,
      title: doc.title,
      section: 'DST',
      start: 0,
      end: original.length,
      text: original,
      strategy: ChunkStrategy.fixed,
      tokens: 30,
      ordinal: 0,
    );
    final f = RagGroundingFixture();
    final turn = RagPreparedTurn(
      request: f.turn.request,
      generation: 'g',
      fingerprint: 'fp',
      candidates: [RagHit(chunk, .9)],
      evidence: [RagHit(chunk, .9)],
      context: ragEvidenceContext([RagHit(chunk, .9)]),
      timings: {},
      exclusions: {},
    );
    final gate = RagFinalAnswerGate(
      turn: turn,
      persistDiagnostic: (_) async {},
    );
    final req = LlmRequest(
      model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
      context: LlmContext(),
    ).snapshot();
    final raw = jsonEncode({
      'status': 'answered',
      'claims': [
        {
          'text': 'The run is skipped.',
          'evidence': [
            {
              'chunk_id': chunk.id,
              'quote':
                  'Spring forward. If time does not exist, the run is skipped.',
            },
          ],
        },
      ],
    });
    final result = await gate.evaluate(
      AgentFinalAnswerDraft(
        text: raw,
        request: req,
        finishReason: LlmFinishReason.stop,
        repairAttempt: false,
      ),
      CancellationSource().token,
    );
    expect(gate.accepted, isNull);
    final repair = (result as AgentFinalAnswerRejected).repairRequest!;
    final payload = jsonDecode(
      (repair.context.messages.single.parts.single as LlmTextPart).text,
    );
    expect(
      (payload['exact_quote_repair_hints'] as List)
          .single['actual_exact_quote'],
      original,
    );
  });

  test('whitespace JSON draft has only one strict text-mode repair', () async {
    final f = RagGroundingFixture();
    final gate = RagFinalAnswerGate(
      turn: f.turn,
      persistDiagnostic: (_) async {},
    );
    final req = LlmRequest(
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      context: LlmContext(),
      generation: LlmGenerationConfig(
        responseFormat: LlmResponseFormat.jsonObject,
        reasoningMode: ReasoningMode.disabled,
        temperature: 0,
        maxOutputTokens: 2048,
      ),
    ).snapshot();
    final first = await gate.evaluate(
      AgentFinalAnswerDraft(
        text: '   ',
        request: req,
        finishReason: LlmFinishReason.stop,
        repairAttempt: false,
      ),
      CancellationSource().token,
    );
    final repair = (first as AgentFinalAnswerRejected).repairRequest!;
    expect(repair.generation.responseFormat, LlmResponseFormat.text);
    expect(repair.generation.maxOutputTokens, 2048);
    expect(repair.generation.temperature, 0);
    final invalid = await gate.evaluate(
      AgentFinalAnswerDraft(
        text: 'Still invalid',
        request: repair.snapshot(),
        finishReason: LlmFinishReason.stop,
        repairAttempt: true,
      ),
      CancellationSource().token,
    );
    expect((invalid as AgentFinalAnswerRejected).repairRequest, isNull);
    expect(gate.accepted, isNull);
    final accepted = await gate.evaluate(
      AgentFinalAnswerDraft(
        text: f.answer(),
        request: repair.snapshot(),
        finishReason: LlmFinishReason.stop,
        repairAttempt: true,
      ),
      CancellationSource().token,
    );
    expect(accepted, isA<AgentFinalAnswerAccepted>());
  });
  for (final mode in ['valid', 'wrong ID', 'wrong quote', 'empty']) {
    test(
      'production preparation persists $mode outcome separately from drafts',
      () async {
        final f = RagGroundingFixture();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [textTurn(f.answer()), textTurn(f.answer())],
        );
        final sessions = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: sessions);
        final storage = FakeMemoryJsonlStorage();
        final corpus = JsonlRagRepository(storage);
        await corpus.saveDocuments('default', 'domovoy', [f.document]);
        await corpus.publishIndex(
          'default',
          'domovoy',
          RagIndex(
            fingerprint: 'fake-v1',
            dimension: 2,
            strategy: ChunkStrategy.fixed,
            chunks: [f.chunk],
            documents: [f.document],
            vectors: [
              mode == 'empty' ? [-1, 0] : [1, 0],
            ],
            elapsedMs: 1,
            generation: 'fixture',
          ),
        );
        final traces = JsonlRagTraceRepository(storage);
        final rag =
            RagChatController(
              strictGrounding: true,
              defaultRetrieval: const RagRetrievalConfig(denseThreshold: .5),
              coordinator: RagTurnCoordinator(
                repository: corpus,
                models: FakeRagModels(),
              ),
              traces: traces,
              registry: runtime.registry,
            )..configure(
              enabled: true,
              protocol: RagProtocol.m2,
              strategy: ChunkStrategy.fixed,
              groundingFault: mode == 'wrong ID'
                  ? RagGroundingFault.wrongChunkId
                  : mode == 'wrong quote'
                  ? RagGroundingFault.wrongQuote
                  : RagGroundingFault.none,
            );
        var memoryCallbacks = 0;
        final chat = ChatWorkspaceController(
          runtime: runtime,
          definition: testDefinition(),
          catalog: sessions,
          repository: sessions,
          registry: runtime.registry,
          runPreparer: rag,
          onTurnCompleted: (_) async {
            memoryCallbacks++;
          },
        );
        await chat.initialize();
        await chat.createChat();
        await rag.attach(chat.state.selectedSession);
        await chat.send('Лимит SOUL.md?');
        final saved = await JsonlRagTraceRepository(
          storage,
        ).list('default', chat.state.selectedId!.value);
        final messages = chat.state.selectedSession!.transcript.messages;
        expect(memoryCallbacks, 0);
        expect(rag.busy, false);
        if (mode == 'valid') {
          expect(provider.requests, hasLength(1));
          expect(messages, hasLength(2));
          expect(saved.single['completion']['grounding']['status'], 'answered');
          expect(saved.single['diagnostic']['accepted'], true);
          expect(
            saved.single['completion']['answer'],
            contains('Источник: facts.md'),
          );
        } else if (mode == 'empty') {
          expect(provider.requests, isEmpty);
          expect(messages, hasLength(2));
          expect(saved.single['physical_answer_requests'], 0);
          expect(saved.single['completion']['reason'], 'insufficient_evidence');
          expect(saved.single['completion']['grounding']['claims'], isEmpty);
          expect(chat.state.selectedSession!.tokenAccounting.ledger, isEmpty);
        } else {
          expect(provider.requests, hasLength(2));
          expect(messages, hasLength(1));
          expect(saved, hasLength(2));
          for (final row in saved) {
            expect(row['diagnostic']['accepted'], false);
            expect(row['diagnostic']['fault_injection'], isNot('none'));
            expect(row['completion']['accepted_message_id'], isNull);
            expect(row['completion']['answer'], isNull);
          }
          expect(saved.last['diagnostic']['repair_attempt'], true);
        }
        final sessionId = chat.state.selectedId!;
        await chat.dispose();
        rag.dispose();
        final restored = await runtime
            .agent(testDefinition())
            .restoreSession(sessionId);
        expect(restored.snapshot.transcript.messages.length, messages.length);
        if (mode.startsWith('wrong')) {
          expect(restored.snapshot.transcript.messages, hasLength(1));
        }
        await runtime.close();
      },
    );
  }
}
