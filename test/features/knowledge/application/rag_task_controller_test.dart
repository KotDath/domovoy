import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_task_state_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';
import '../../../support/rag_grounding_fixture.dart';

final class _Extractor implements RagTaskExtractor {
  _Extractor({
    this.entered,
    this.release,
    this.fail = false,
    this.timeout = false,
  });
  final bool fail, timeout;
  final Completer<void>? entered, release;
  final inputs = <String>[];
  @override
  Future<RagTaskExtraction> extract(
    RagTaskState before,
    String input,
    CancellationToken cancellation,
  ) async {
    inputs.add(input);
    if (timeout) throw TimeoutException("Extractor timed out");
    if (fail) throw const FormatException("Extractor response rejected");
    entered?.complete();
    if (release != null) await release!.future;
    final time = input.contains('08:30') ? '08:30' : '09:00';
    return RagTaskExtraction(
      RagTaskPatch.parse(
        jsonEncode({
          'updates': [
            {'id': 'constraint.time', 'kind': 'constraint', 'quote': time},
          ],
        }),
        input,
        before,
      ),
      const {'fixture': true},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'on',
    'off',
    'late manual edit',
    'extractor failure',
    'extractor timeout',
  ]) {
    test(
      'task-state preparation $scenario respects scope and actual request',
      () async {
        final f = RagGroundingFixture();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: List.generate(4, (_) => textTurn(f.answer())),
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
              [1, 0],
            ],
            elapsedMs: 1,
            generation: 'fixture',
          ),
        );
        final states = JsonlRagTaskStateRepository(storage);
        final traces = JsonlRagTraceRepository(storage);
        final entered = scenario == 'late manual edit'
            ? Completer<void>()
            : null;
        final release = scenario == 'late manual edit'
            ? Completer<void>()
            : null;
        final extractor = _Extractor(
          entered: entered,
          release: release,
          fail: scenario == 'extractor failure',
          timeout: scenario == 'extractor timeout',
        );
        final rag =
            RagChatController(
              strictGrounding: true,
              taskStates: states,
              taskExtractorFactory: (_, before, after) => extractor,
              coordinator: RagTurnCoordinator(
                repository: corpus,
                models: FakeRagModels(),
              ),
              traces: traces,
              registry: runtime.registry,
            )..configure(
              enabled: true,
              neutral: true,
              strategy: ChunkStrategy.fixed,
              protocol: RagProtocol.m1,
              taskStateEnabled: scenario != 'off',
            );
        final chat = ChatWorkspaceController(
          runtime: runtime,
          definition: testDefinition(),
          catalog: sessions,
          repository: sessions,
          registry: runtime.registry,
          runPreparer: rag,
        );
        await chat.initialize();
        await chat.createChat();
        await rag.attach(chat.state.selectedSession);
        final scope = chat.state.selectedId!.value;
        if (scenario.startsWith('extractor')) {
          await rag.editTaskFact(
            'constraint.time',
            RagTaskFactKind.constraint,
            '09:00',
          );
        }
        final sending = chat.send(
          scenario.startsWith('extractor')
              ? 'Change chosen time to 08:30. What is the SOUL.md limit?'
              : 'Chosen time 09:00. What is the SOUL.md limit?',
        );
        if (entered != null) {
          await entered.future;
          await rag.editTaskFact(
            'constraint.time',
            RagTaskFactKind.constraint,
            '07:45',
          );
          release!.complete();
        }
        await sending;
        final saved = await states.load('default', scope);
        if (scenario == 'on') {
          expect(saved.facts.single.quote, '09:00');
          expect(
            provider.requests.single.context.systemPrompt,
            contains('USER_TASK_STATE_EVIDENCE_JSON'),
          );
          expect(
            provider.requests.single.context.systemPrompt,
            contains('09:00'),
          );
          final request = (await traces.list('default', scope)).single;
          expect(request['task_state']['session'], scope);
          expect(request['task_state']['revision'], 1);
          expect(
            request['retrieval_query'],
            'Chosen time 09:00. What is the SOUL.md limit?',
          );
          await chat.send(
            'Change chosen time to 08:30. What is the SOUL.md limit?',
          );
          expect(extractor.inputs, hasLength(2));
          expect(
            (await states.load('default', scope)).superseded.single.quote,
            '09:00',
          );
          final original = chat.state.selectedSession!.transcript.toJson();
          final stateBefore = (await states.load('default', scope)).toJson();
          final replay = await rag.replayLastQuestion(
            chat.state.selectedSession!,
            CancellationSource().token,
          );
          expect(replay.map((r) => r['accepted']), [true, true]);
          expect(
            extractor.inputs,
            hasLength(2),
            reason: 'Diagnostic does not invoke a fake extractor',
          );
          expect(chat.state.selectedSession!.transcript.toJson(), original);
          expect((await states.load('default', scope)).toJson(), stateBefore);
          expect(replay.first['tail'], replay.last['tail']);
          expect(
            replay.first['tail_message_ids'],
            replay.last['tail_message_ids'],
          );
          expect(provider.requests, hasLength(4));
          final off = provider.requests[2], on = provider.requests[3];
          expect(off.context.messages, on.context.messages);
          expect(off.context.messages, hasLength(3));
          expect(off.model, on.model);
          expect(off.generation.toJson(), on.generation.toJson());
          String removeState(String p) => p
              .replaceAll(
                RegExp(
                  r'USER_TASK_STATE_EVIDENCE_JSON\n.*?\nEND_USER_TASK_STATE_EVIDENCE',
                  dotAll: true,
                ),
                '',
              )
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .join('\n');
          expect(
            removeState(off.context.systemPrompt ?? ''),
            removeState(on.context.systemPrompt ?? ''),
          );
          final rows = await traces.list('default', scope);
          final diagnostic = rows
              .where((r) => r['diagnostic_replay'] == true)
              .toList();
          expect(diagnostic, hasLength(2));
          expect(
            diagnostic.every(
              (r) => r['completion']['accepted_message_id'] == null,
            ),
            true,
          );
          expect(
            diagnostic.every(
              (r) => r['completion']['replay_message_id'] != null,
            ),
            true,
          );
        } else if (scenario == 'off') {
          expect(extractor.inputs, isEmpty);
          expect(saved.facts, isEmpty);
          expect(
            provider.requests.single.context.systemPrompt,
            isNot(contains('USER_TASK_STATE_EVIDENCE_JSON')),
          );
        } else if (scenario.startsWith('extractor')) {
          expect(saved.revision, 1);
          expect(saved.facts.single.quote, '09:00');
          expect(rag.taskStateNotice, contains('не обновлена'));
          expect(provider.requests, hasLength(1));
          expect(
            provider.requests.single.context.systemPrompt,
            isNot(contains('USER_TASK_STATE_EVIDENCE_JSON')),
          );
          expect(chat.state.selectedSession!.transcript.messages, hasLength(2));
          final trace = (await traces.list('default', scope)).single;
          expect(trace['task_state_used'], false);
          expect(trace['task_state_update_notice'], contains('не обновлена'));
        } else {
          expect(saved.facts.single.quote, '07:45');
          expect(saved.facts.single.sourceKind, 'manual_user_edit');
          expect(provider.requests, isEmpty);
          expect(chat.state.selectedSession!.transcript.messages, isEmpty);
          expect(rag.error, contains('изменена'));
        }
        expect((await states.load('another-project', scope)).facts, isEmpty);
        expect((await states.load('default', 'another-chat')).facts, isEmpty);
        await chat.dispose();
        rag.dispose();
        await runtime.close();
      },
    );
  }
}
