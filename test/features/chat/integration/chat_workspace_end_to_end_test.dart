import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/application/chat_token_presenter.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';

void main() {
  test(
    'complete acknowledged journey survives compaction, restart, and deletion',
    () async {
      final storage = _MemoryJsonlStorage();
      final settings = _SettingsLauncher();
      final first = _stack(storage: storage, settings: settings);
      final controller = first.controller;
      final firstChat = AgentSessionId('journey-first');
      final secondChat = AgentSessionId('journey-second');

      expect((await controller.initialize()).isSuccess, isTrue);
      expect(controller.state.isEmpty, isTrue);
      expect((await controller.openSettings()).isSuccess, isTrue);
      expect(settings.opens, 1);
      expect((await controller.createChat(id: firstChat)).isSuccess, isTrue);
      expect(controller.state.selectedId, firstChat);

      expect((await controller.send('Inspect home status')).isSuccess, isTrue);
      expect(first.toolExecutor.executions, 1);
      final richTimeline = const ChatTimelineProjector().project(
        snapshot: controller.state.selectedSession!,
        liveRun: controller.state.liveRun,
      );
      expect(richTimeline.items.whereType<ChatReasoningItem>(), hasLength(2));
      expect(richTimeline.items.whereType<ChatToolItem>(), hasLength(1));
      expect(
        richTimeline.items.whereType<ChatAssistantItem>().map(
          (item) => item.text,
        ),
        containsAll(<String>['I will inspect it.', 'Everything is online.']),
      );

      expect(
        (await controller.changeReasoning(
          ReasoningMode.disabled,
          ReasoningEffort.modelDefault,
        )).isSuccess,
        isTrue,
      );
      final stoppedSend = controller.send('Keep watching until I stop');
      await first.deepSeekProvider.paused.future;
      await Future<void>.delayed(Duration.zero);
      final partialTimeline = const ChatTimelineProjector().project(
        snapshot: controller.state.selectedSession!,
        liveRun: controller.state.liveRun,
      );
      expect(
        partialTimeline.items.whereType<ChatAssistantItem>().last,
        isA<ChatAssistantItem>()
            .having((item) => item.text, 'text', 'Still watching')
            .having((item) => item.isPartial, 'isPartial', isTrue),
      );
      expect((await controller.stop()).isSuccess, isTrue);
      expect((await stoppedSend).status, ChatCommandStatus.cancelled);
      expect(controller.state.liveRun?.terminal, isA<AgentRunCancelled>());

      expect(
        (await controller.send('Give me the final status')).isSuccess,
        isTrue,
      );
      final beforeSwitch = controller.state.selectedSession!;
      expect(
        beforeSwitch.transcript.messages
            .expand((message) => message.parts)
            .whereType<LlmTextPart>()
            .map((part) => part.text),
        isNot(contains('Still watching')),
      );

      final target = AgentSessionSelection(
        model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        reasoningMode: ReasoningMode.disabled,
        reasoningEffort: ReasoningEffort.modelDefault,
      );
      expect(
        first.registry.requireModel(target.model).contextBound,
        lessThan(
          first.registry
              .requireModel(beforeSwitch.selection.model)
              .contextBound,
        ),
      );
      expect((await controller.changeSelection(target)).isSuccess, isTrue);
      final switched = controller.state.selectedSession!;
      expect(switched.selection, target);
      expect(
        switched.compactionState?.reason,
        AgentCompactionReason.modelSwitch,
      );
      expect(switched.compactionState?.beforeEstimate, 100);
      expect(switched.compactionState?.afterEstimate, 10);
      expect(first.openAiProvider.requests, isEmpty);

      final compactedTimeline = const ChatTimelineProjector().project(
        snapshot: switched,
        operationCompactions: controller.state.liveCompactions,
      );
      expect(
        compactedTimeline.items.whereType<ChatCompactionItem>(),
        hasLength(1),
      );
      expect(
        compactedTimeline.items.map((item) => item.key).toSet(),
        hasLength(compactedTimeline.items.length),
      );

      final tokens = const ChatTokenPresenter().present(
        accounting: switched.tokenAccounting,
        selectedModel: first.registry.requireModel(switched.selection.model),
      );
      expect(tokens.primaryGroups.map((group) => group.key), <String>[
        'current-request',
        'history',
        'latest-response',
      ]);
      final compactionTokens = tokens.supplementaryGroups.singleWhere(
        (group) => group.key == 'compaction',
      );
      expect(
        compactionTokens.values
            .singleWhere((value) => value.label == 'Всего')
            .display,
        '9',
      );
      expect(
        tokens.primaryGroups
            .singleWhere((group) => group.key == 'latest-response')
            .modelLabel,
        BuiltInLlmCatalog.deepSeekV4FlashModel.ref.toString(),
      );

      expect((await controller.createChat(id: secondChat)).isSuccess, isTrue);
      expect(controller.state.selectedId, secondChat);
      expect(controller.state.chats, hasLength(2));
      final beforeRestart = await first.store.load(firstChat);
      expect(beforeRestart, isNotNull);
      await controller.dispose();
      await first.runtime.close();

      final restarted = _stack(storage: storage, settings: _SettingsLauncher());
      expect((await restarted.controller.initialize()).isSuccess, isTrue);
      expect(
        restarted.controller.state.chats.map((chat) => chat.id),
        <AgentSessionId>[secondChat, firstChat],
      );
      expect(restarted.controller.state.selectedId, secondChat);
      expect(
        (await restarted.controller.selectChat(firstChat)).isSuccess,
        isTrue,
      );
      final restored = restarted.controller.state.selectedSession!;
      expect(restored.selection, target);
      expect(restored.transcript, beforeRestart!.transcript);
      expect(restored.compactionState, beforeRestart.compactionState);
      expect(
        restored.tokenAccounting.ledger,
        hasLength(switched.tokenAccounting.ledger.length),
      );
      expect(
        const ChatTimelineProjector()
            .project(snapshot: restored)
            .items
            .whereType<ChatCompactionItem>(),
        hasLength(1),
      );

      final firstIntent = restarted.controller.deletionIntentFor(firstChat)!;
      expect(
        (await restarted.controller.deleteChat(firstIntent)).isSuccess,
        isTrue,
      );
      expect(restarted.controller.state.selectedId, secondChat);
      expect(await restarted.store.load(firstChat), isNull);
      final secondIntent = restarted.controller.deletionIntentFor(secondChat)!;
      expect(
        (await restarted.controller.deleteChat(secondIntent)).isSuccess,
        isTrue,
      );
      expect(restarted.controller.state.chats, isEmpty);
      expect(restarted.controller.state.selectedSession, isNull);
      await restarted.controller.dispose();
      await restarted.runtime.close();

      final finalRestart = _stack(
        storage: storage,
        settings: _SettingsLauncher(),
      );
      expect((await finalRestart.controller.initialize()).isSuccess, isTrue);
      expect(finalRestart.controller.state.isEmpty, isTrue);
      expect(
        storage.payloads.values.join(),
        contains('"type":"domovoy.agent_session_operation"'),
      );
      expect(storage.payloads.values.join(), contains('"version":1'));
      await finalRestart.controller.dispose();
      await finalRestart.runtime.close();
    },
  );
}

({
  ChatWorkspaceController controller,
  InMemoryAgentRuntime runtime,
  JsonlAgentSessionStore store,
  LlmProviderRegistry registry,
  _StoppableScriptedProvider deepSeekProvider,
  QueueScriptedLlmProvider openAiProvider,
  ScriptedToolExecutor toolExecutor,
})
_stack({
  required _MemoryJsonlStorage storage,
  required _SettingsLauncher settings,
}) {
  final store = JsonlAgentSessionStore(storage: storage);
  final deepSeekProvider = _StoppableScriptedProvider(
    id: BuiltInLlmCatalog.deepSeek,
    wireFamily: LlmWireFamily.openaiChatCompletions,
    turns: <_ScriptedTurn>[
      _ScriptedTurn(<LlmEvent>[
        const LlmReasoningDelta('Checking sensors.'),
        const LlmTextDelta('I will inspect it.'),
        LlmToolCallDelta(
          callId: ToolCallId('journey-inspect'),
          index: 0,
          name: 'home.inspect',
          argumentsFragment: '{"area":"all"}',
        ),
        LlmUsageUpdate(
          LlmUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
        ),
        LlmCompleted(
          finishReason: LlmFinishReason.toolCalls,
          usage: LlmUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
        ),
      ]),
      _ScriptedTurn(<LlmEvent>[
        const LlmReasoningDelta('The tool result is healthy.'),
        const LlmTextDelta('Everything is online.'),
        LlmUsageUpdate(
          LlmUsage(inputTokens: 3, outputTokens: 1, totalTokens: 4),
        ),
        LlmCompleted(
          finishReason: LlmFinishReason.stop,
          usage: LlmUsage(inputTokens: 3, outputTokens: 1, totalTokens: 4),
        ),
      ]),
      const _ScriptedTurn(<LlmEvent>[
        LlmReasoningDelta('Waiting for changes.'),
        LlmTextDelta('Still watching'),
      ], pauseUntilCancelled: true),
      _ScriptedTurn(
        textTurn(
          'Final status is stable.',
          usage: LlmUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5),
        ),
      ),
    ],
  );
  final openAiProvider = QueueScriptedLlmProvider(
    id: BuiltInLlmCatalog.openAi,
    wireFamily: LlmWireFamily.openaiResponses,
    turns: const <List<LlmEvent>>[],
  );
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(deepSeekProvider);
  registry.registerProvider(openAiProvider);
  final toolExecutor = ScriptedToolExecutor((
    invocation, {
    required cancellation,
    required liveness,
  }) async {
    liveness.reportProgress(detail: 'inspected');
    return ToolExecutionResult.success(<String, Object?>{'online': true});
  });
  final tools = AgentToolRegistry()
    ..register(
      AgentTool(
        descriptor: LlmToolDescriptor(
          name: 'home.inspect',
          parameters: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'area': <String, Object?>{'type': 'string'},
            },
          },
        ),
        executor: toolExecutor,
      ),
    );
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    tools: tools,
    repository: store,
    contextEstimator: const _JourneyEstimator(),
    compactionTrigger: const _NeverAutomaticCompaction(),
    modelSwitchFitPolicy: const _JourneyFitPolicy(),
    historyCompactor: _UsageReportingCompactor(),
  );
  final definition = testDefinition(
    model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    tools: <ToolId>[ToolId('home.inspect')],
    systemPrompt: '',
  );
  final controller = ChatWorkspaceController(
    runtime: runtime,
    definition: definition,
    catalog: store,
    repository: store,
    registry: registry,
    settingsLauncher: settings,
  );
  return (
    controller: controller,
    runtime: runtime,
    store: store,
    registry: registry,
    deepSeekProvider: deepSeekProvider,
    openAiProvider: openAiProvider,
    toolExecutor: toolExecutor,
  );
}

final class _ScriptedTurn {
  const _ScriptedTurn(this.events, {this.pauseUntilCancelled = false});

  final List<LlmEvent> events;
  final bool pauseUntilCancelled;
}

final class _StoppableScriptedProvider implements LlmProvider {
  _StoppableScriptedProvider({
    required this.id,
    required this.wireFamily,
    required this.turns,
  });

  @override
  final ProviderId id;

  @override
  final LlmWireFamily wireFamily;

  final List<_ScriptedTurn> turns;
  final List<LlmRequest> requests = <LlmRequest>[];
  final Completer<void> paused = Completer<void>();
  var _index = 0;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    final turn = turns[_index++];
    for (final event in turn.events) {
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
      yield event;
      if (event.isTerminal) return;
    }
    if (!turn.pauseUntilCancelled) {
      yield const LlmCompleted(finishReason: LlmFinishReason.stop);
      return;
    }
    if (!paused.isCompleted) paused.complete();
    if (!cancellation.isCancelled) {
      final cancelled = Completer<void>();
      final registration = cancellation.register(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      try {
        await cancelled.future;
      } finally {
        registration.dispose();
      }
    }
    yield const LlmCancelled();
  }
}

final class _JourneyEstimator implements AgentContextEstimator {
  const _JourneyEstimator();

  @override
  String get id => 'journey-estimator';

  @override
  int get version => 1;

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) =>
      AgentContextEstimate(
        value: input.request.context.messages.length > 2 ? 100 : 10,
        estimatorId: id,
        estimatorVersion: version,
      );
}

final class _NeverAutomaticCompaction implements AgentCompactionTrigger {
  const _NeverAutomaticCompaction();

  @override
  AgentCompactionDecision evaluate(AgentCompactionContext context) =>
      AgentCompactionDecision.skip(
        triggerId: 'journey-skip',
        triggerVersion: 1,
      );
}

final class _JourneyFitPolicy implements AgentModelSwitchFitPolicy {
  const _JourneyFitPolicy();

  @override
  String get id => 'journey-target-fit';

  @override
  int get version => 1;

  @override
  AgentModelSwitchFit evaluate(AgentModelSwitchFitInput input) =>
      AgentModelSwitchFit(
        contextBound: input.model.contextBound,
        outputReserve: 1,
        headroom: 1,
        fitThreshold: 50,
        compactionTarget: 40,
        policyId: id,
        policyVersion: version,
      );
}

final class _UsageReportingCompactor implements AgentHistoryCompactor {
  final RecentInteractionGroupsCompactor _delegate =
      RecentInteractionGroupsCompactor(1);

  @override
  String get id => 'journey-usage-compactor';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    final result = await _delegate.compact(context, decision);
    if (result case AgentCompactionCandidate(
      :final retainedSuffixBoundaryId,
      :final generatedPrefix,
      :final generatedPrefixMessageIds,
    )) {
      return AgentCompactionCandidate(
        strategyId: id,
        strategyVersion: version,
        retainedSuffixBoundaryId: retainedSuffixBoundaryId,
        generatedPrefix: generatedPrefix,
        generatedPrefixMessageIds: generatedPrefixMessageIds,
        reports: <AgentCompactionInvocationReport>[
          AgentCompactionInvocationReport(
            invocationOrdinal: 0,
            model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
            outcome: AgentModelInvocationOutcome.completed,
            usage: LlmUsage(totalTokens: 9),
          ),
        ],
      );
    }
    return result;
  }
}

final class _SettingsLauncher implements ChatSettingsLauncher {
  var opens = 0;

  @override
  Future<void> openSettings() async {
    opens += 1;
  }
}

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
