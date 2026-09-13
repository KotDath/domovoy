import 'dart:convert';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/application/chat_token_presenter.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'fresh production stacks restore rich acknowledged workspace and deletion',
    () async {
      final storage = _MemoryJsonlStorage();
      final rich = _richWorkspaceRecord();
      final other = _plainRecord();

      final first = _stack(storage);
      await first.stack.repository.save(
        rich,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await first.stack.repository.save(
        other,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      storage.payloads[const JsonlSessionKeyCodec().encode(
            AgentSessionId('unreadable-neighbor'),
          )] =
          '{"record":"not-a-valid-session"}\n';
      expect(
        first.stack.runtime.historyCompactor,
        isA<OpenCodeSummaryCompactor>(),
      );
      expect(
        first.stack.runtime.compactionTrigger,
        isA<OpenCodeCompactionTrigger>(),
      );
      expect(
        first.stack.runtime.modelSwitchFitPolicy,
        isA<OpenCodeAgentModelSwitchFitPolicy>(),
      );
      await first.stack.runtime.close();
      first.client.close();

      final restarted = _stack(storage);
      final controller = _controller(restarted.stack);
      expect((await controller.initialize()).isSuccess, isTrue);
      expect(controller.state.chats.map((chat) => chat.id), <AgentSessionId>[
        rich.id,
        other.id,
      ]);
      expect(controller.state.catalogIssues, hasLength(1));
      expect(
        controller.state.catalogIssues.single.id,
        AgentSessionId('unreadable-neighbor'),
      );
      final snapshot = controller.state.selectedSession!;
      expect(snapshot.id, rich.id);
      expect(snapshot.lifecycle, AgentSessionLifecycle.idle);
      expect(snapshot.selection, rich.selection);
      expect(snapshot.title, 'Rich durable chat');
      expect(snapshot.transcript, rich.transcript);
      expect(
        snapshot.compactionState?.reason,
        AgentCompactionReason.modelSwitch,
      );
      expect(snapshot.tokenAccounting.ledger, hasLength(2));
      expect(
        snapshot.tokenAccounting.byModel.keys,
        containsAll(<ModelRef>[
          BuiltInLlmCatalog.gpt4oMiniModel.ref,
          BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        ]),
      );
      final timeline = const ChatTimelineProjector().project(
        snapshot: snapshot,
      );
      expect(timeline.items.whereType<ChatReasoningItem>(), hasLength(1));
      expect(timeline.items.whereType<ChatToolItem>(), hasLength(1));
      expect(timeline.items.whereType<ChatCompactionItem>(), hasLength(1));
      final tokens = const ChatTokenPresenter().present(
        accounting: snapshot.tokenAccounting,
        selectedModel: restarted.stack.registry.requireModel(
          snapshot.selection.model,
        ),
      );
      expect(tokens.primaryGroups, hasLength(3));
      expect(tokens.supplementaryGroups, hasLength(4));

      final otherIntent = controller.deletionIntentFor(other.id)!;
      expect((await controller.deleteChat(otherIntent)).isSuccess, isTrue);
      expect(await restarted.stack.repository.load(other.id), isNull);
      await controller.dispose();
      await restarted.stack.runtime.close();
      restarted.client.close();

      final afterDelete = _stack(storage);
      final restoredController = _controller(afterDelete.stack);
      expect((await restoredController.initialize()).isSuccess, isTrue);
      expect(restoredController.state.chats, hasLength(1));
      expect(restoredController.state.catalogIssues, hasLength(1));
      expect(restoredController.state.selectedId, rich.id);
      expect(
        restoredController.state.selectedSession!.selection,
        rich.selection,
      );
      expect(
        restoredController.state.selectedSession!.transcript,
        rich.transcript,
      );
      expect(await afterDelete.stack.repository.load(other.id), isNull);
      expect(storage.payloads.values.join(), contains('"version":1'));
      expect(storage.payloads.values.join(), contains('"version":2'));
      final persistedText = storage.payloads.values.join().toLowerCase();
      expect(persistedText, isNot(contains('api_key')));
      expect(persistedText, isNot(contains('authorization')));
      expect(persistedText, isNot(contains('opaque-continuation-secret')));

      final richIntent = restoredController.deletionIntentFor(rich.id)!;
      expect(
        (await restoredController.deleteChat(richIntent)).isSuccess,
        isTrue,
      );
      expect(restoredController.state.chats, isEmpty);
      expect(restoredController.state.selectedSession, isNull);
      await restoredController.dispose();
      await afterDelete.stack.runtime.close();
      afterDelete.client.close();

      final finalRestart = _stack(storage);
      final finalController = _controller(finalRestart.stack);
      expect((await finalController.initialize()).isSuccess, isTrue);
      expect(finalController.state.chats, isEmpty);
      expect(finalController.state.selectedSession, isNull);
      await finalController.dispose();
      await finalRestart.stack.runtime.close();
      finalRestart.client.close();
    },
  );
}

({ProductionAgentStack stack, http.Client client}) _stack(
  _MemoryJsonlStorage storage,
) {
  final client = http.Client();
  final store = JsonlAgentSessionStore(storage: storage);
  final stack = buildProductionAgentStack(
    httpClient: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(),
      readEnvironment: const MapEnvironmentReader({}).read,
    ),
    repository: store,
    catalog: store,
  );
  return (stack: stack, client: client);
}

ChatWorkspaceController _controller(ProductionAgentStack stack) =>
    ChatWorkspaceController(
      runtime: stack.runtime,
      definition: stack.promptDefinition,
      catalog: stack.catalog,
      repository: stack.repository,
      registry: stack.registry,
    );

AgentSessionRecord _richWorkspaceRecord() {
  final ids = <AgentTranscriptMessageId>[
    AgentTranscriptMessageId('summary'),
    AgentTranscriptMessageId('question'),
    AgentTranscriptMessageId('tool-call'),
    AgentTranscriptMessageId('tool-result'),
    AgentTranscriptMessageId('final-answer'),
  ];
  final callId = ToolCallId('restart-tool');
  final transcript = AgentTranscript(
    messages: <LlmMessage>[
      _message(LlmMessageRole.assistant, <LlmContentPart>[
        LlmTextPart('Committed compact summary'),
      ]),
      _message(LlmMessageRole.user, <LlmContentPart>[
        LlmTextPart('Inspect durable state'),
      ]),
      _message(LlmMessageRole.assistant, <LlmContentPart>[
        LlmReasoningPart('Check the acknowledged JSONL record.'),
        LlmToolCallPart(
          callId: callId,
          name: 'workspace.inspect',
          arguments: '{"scope":"durable"}',
        ),
      ]),
      _message(LlmMessageRole.tool, <LlmContentPart>[
        LlmToolResultPart(callId: callId, content: '{"status":"ok"}'),
      ]),
      _message(LlmMessageRole.assistant, <LlmContentPart>[
        LlmTextPart('The durable state is acknowledged.'),
      ]),
    ],
    messageIds: ids,
  );
  final accounting = AgentTokenAccountingState(
    generation: 1,
    contextRevision: 3,
    messageIds: ids,
    legacyBaseline: LlmUsage(),
    entries: <AgentModelUsageEntry>[
      AgentModelUsageEntry.compaction(
        sequence: 1,
        attemptId: ProviderAttemptId('switch-compaction-attempt'),
        model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: LlmUsage(totalTokens: 5),
        contextRevision: 1,
        compactionOperationId: AgentCompactionOperationId('switch-compaction'),
        invocationOrdinal: 0,
      ),
      AgentModelUsageEntry.assistant(
        sequence: 2,
        attemptId: ProviderAttemptId('target-response-attempt'),
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: LlmUsage(totalTokens: 7),
        contextRevision: 2,
        runId: RunId('target-run'),
        turnId: TurnId('target-turn'),
        retryOrdinal: 0,
        requestMessageId: ids[1],
        responseMessageId: ids[4],
      ),
    ],
  );
  return AgentSessionRecord(
    id: AgentSessionId('rich-chat'),
    revision: 0,
    definition: PromptWorkspace.definition(
      reasoningMode: ReasoningMode.disabled,
    ),
    selection: AgentSessionSelection(
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      reasoningMode: ReasoningMode.enabled,
      reasoningEffort: ReasoningEffort.high,
    ),
    title: 'Rich durable chat',
    transcript: transcript,
    usage: accounting.compatibilityUsage,
    modelTurns: 2,
    toolAttempts: 1,
    createdAtMicros: 1,
    updatedAtMicros: 20,
    compactionState: AgentCompactionState(
      generation: 1,
      generatedPrefixStart: 0,
      generatedPrefixCount: 1,
      reason: AgentCompactionReason.modelSwitch,
      triggerId: 'opencode-model-switch-fit',
      triggerVersion: 1,
      strategyId: 'opencode-structured-summary',
      strategyVersion: 1,
      estimatorId: Utf8FramingAgentContextEstimator.defaultId,
      estimatorVersion: Utf8FramingAgentContextEstimator.defaultVersion,
      removedMessageCount: 2,
      beforeEstimate: 100,
      afterEstimate: 50,
      decisionMetadata: const <String, Object?>{
        'fitThreshold': 80,
        'postCompactionTarget': 60,
      },
      updatedAtMicros: 20,
    ),
    tokenAccounting: accounting,
  );
}

AgentSessionRecord _plainRecord() => AgentSessionRecord(
  id: AgentSessionId('other-chat'),
  revision: 0,
  definition: PromptWorkspace.definition(),
  title: 'Other durable chat',
  transcript: AgentTranscript(
    messages: <LlmMessage>[
      _message(LlmMessageRole.user, <LlmContentPart>[
        LlmTextPart('Other question'),
      ]),
      _message(LlmMessageRole.assistant, <LlmContentPart>[
        LlmTextPart('Other answer'),
      ]),
    ],
  ),
  usage: LlmUsage(),
  modelTurns: 1,
  toolAttempts: 0,
  createdAtMicros: 2,
  updatedAtMicros: 10,
);

LlmMessage _message(LlmMessageRole role, List<LlmContentPart> parts) =>
    LlmMessage(role: role, parts: parts);

final class _MemoryJsonlStorage implements JsonlStreamStorage {
  final Map<String, String> payloads = <String, String>{};

  @override
  Future<void> cleanup(String key) async {}

  @override
  Future<List<String>> listKeys() async => payloads.keys.toList();

  @override
  Future<void> publish(String key, List<int> contents) async {
    payloads[key] = utf8.decode(contents);
  }

  @override
  Future<Stream<List<int>>?> read(String key) async {
    final value = payloads[key];
    return value == null ? null : Stream<List<int>>.value(utf8.encode(value));
  }
}
