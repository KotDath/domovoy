import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_run_preparer.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';

final class _DelayedPreparer implements ChatRunPreparer {
  final entered = Completer<void>(), release = Completer<void>();
  int settlements = 0;
  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async {
    entered.complete();
    await release.future;
    return ChatPreparedRun(
      options: AgentRunOptions(),
      onSettled: (_, terminal) async {
        expect(terminal, isNull);
        settlements++;
      },
    );
  }
}

final class _ImmediatePreparer implements ChatRunPreparer {
  _ImmediatePreparer(this.recordCompletedTurn);
  final bool recordCompletedTurn;
  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async => ChatPreparedRun(
    options: AgentRunOptions(),
    recordCompletedTurn: recordCompletedTurn,
  );
}

final class _FailingReceiptRepository implements RagTraceRepository {
  _FailingReceiptRepository(this.delegate, {this.failRequest = false});
  final RagTraceRepository delegate;
  final bool failRequest;
  @override
  Future<void> saveRequest(
    String project,
    String session,
    String id,
    Map<String, Object?> trace,
  ) async {
    if (failRequest) throw StateError('request disk failure');
    await delegate.saveRequest(project, session, id, trace);
  }

  @override
  Future<void> saveCompletion(
    String project,
    String session,
    String id,
    Map<String, Object?> completion,
  ) async {
    throw StateError('receipt disk failure');
  }

  @override
  Future<List<Map<String, dynamic>>> list(String project, String session) =>
      delegate.list(project, session);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'request persistence fails closed; receipt failure preserves accepted answer',
    () async {
      for (final failRequest in [false, true]) {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [textTurn('accepted answer')],
        );
        final repo = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repo);
        final storage = FakeMemoryJsonlStorage();
        final traces = JsonlRagTraceRepository(storage);
        final rag = RagChatController(
          coordinator: RagTurnCoordinator(
            repository: JsonlRagRepository(storage),
            models: FakeRagModels(),
          ),
          traces: _FailingReceiptRepository(traces, failRequest: failRequest),
          registry: runtime.registry,
        )..configure(enabled: false, neutral: true);
        final chat = ChatWorkspaceController(
          runtime: runtime,
          definition: testDefinition(),
          catalog: repo,
          repository: repo,
          registry: runtime.registry,
          runPreparer: rag,
        );
        await chat.initialize();
        await chat.createChat();
        await rag.attach(chat.state.selectedSession);
        final result = await chat.send('question');
        expect(result.isSuccess, !failRequest);
        expect(provider.requests.length, failRequest ? 0 : 1);
        expect(rag.busy, false);
        final saved = await traces.list(
          'default',
          chat.state.selectedId!.value,
        );
        expect(saved.length, failRequest ? 0 : 1);
        if (!failRequest) {
          expect(
            chat.state.selectedSession!.transcript.messages.last.role,
            LlmMessageRole.assistant,
          );
          expect(rag.error, contains('связь с источниками'));
          expect(saved.single['completion'], isNull);
        }
        await chat.dispose();
        rag.dispose();
        await runtime.close();
      }
    },
  );
  test(
    'prepared runs preserve memory callback unless explicitly suppressed',
    () async {
      for (final record in [true, false]) {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [textTurn('answer')],
        );
        final repo = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repo);
        var completed = 0;
        final chat = ChatWorkspaceController(
          runtime: runtime,
          definition: testDefinition(),
          catalog: repo,
          repository: repo,
          registry: runtime.registry,
          runPreparer: _ImmediatePreparer(record),
          onTurnCompleted: (_) async {
            completed++;
          },
        );
        await chat.initialize();
        await chat.createChat();
        expect((await chat.send('question')).isSuccess, true);
        await Future<void>.delayed(Duration.zero);
        expect(completed, record ? 1 : 0);
        await chat.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'stop and disposal discard a late preparation before user/model admission',
    () async {
      for (final disposing in [false, true]) {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [textTurn('unreachable')],
        );
        final repo = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repo);
        final preparer = _DelayedPreparer();
        final chat = ChatWorkspaceController(
          runtime: runtime,
          definition: testDefinition(),
          catalog: repo,
          repository: repo,
          registry: runtime.registry,
          runPreparer: preparer,
        );
        await chat.initialize();
        await chat.createChat();
        final id = chat.state.selectedId!;
        final sending = chat.send('cancel me');
        await preparer.entered.future;
        final stopping = disposing ? chat.dispose() : chat.stop();
        preparer.release.complete();
        await stopping;
        expect((await sending).isSuccess, isFalse);
        expect(provider.requests, isEmpty);
        expect((await repo.load(id))!.transcript.messages, isEmpty);
        expect(preparer.settlements, 1);
        await chat.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'neutral M0 saves the real request and accepted identity, source traces reopen',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('test answer')],
      );
      final repo = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repo);
      final storage = FakeMemoryJsonlStorage();
      final traceRepo = JsonlRagTraceRepository(storage);
      final rag = RagChatController(
        coordinator: RagTurnCoordinator(
          repository: JsonlRagRepository(storage),
          models: FakeRagModels(),
        ),
        traces: traceRepo,
        registry: runtime.registry,
      );
      rag.configure(enabled: false, neutral: true);
      final chat = ChatWorkspaceController(
        runtime: runtime,
        definition: testDefinition(systemPrompt: 'PROFILE_SHOULD_NOT_LEAK'),
        catalog: repo,
        repository: repo,
        registry: runtime.registry,
        runPreparer: rag,
      );
      await chat.initialize();
      await chat.createChat();
      await rag.attach(chat.state.selectedSession);
      final result = await chat.send('question');
      expect(result.isSuccess, true, reason: result.error?.message);
      expect(rag.busy, false);
      expect(
        provider.requests.single.context.systemPrompt,
        ragAnswerInstructions,
      );
      final saved = (await JsonlRagTraceRepository(
        storage,
      ).list('default', chat.state.selectedId!.value)).single;
      expect(saved['protocol'], 'm0');
      expect(saved['candidates'], isEmpty);
      expect(saved['request']['tools_count'], 0);
      expect(
        saved['request']['system_prompt'],
        isNot(contains('PROFILE_SHOULD_NOT_LEAK')),
      );
      expect(
        saved['completion']['accepted_message_id'],
        chat.state.selectedSession!.transcript.messageIds.last!.value,
      );
      expect(saved['completion']['answer'], 'test answer');
      await rag.attach(null);
      expect(rag.history, isEmpty);
      await chat.dispose();
      rag.dispose();
      await runtime.close();
    },
  );
}
