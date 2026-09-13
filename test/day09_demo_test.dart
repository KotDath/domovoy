import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/demos/day09_compaction.dart';
import 'package:domovoy/demos/day09_comparison.dart';
import 'package:domovoy/demos/day09_dependencies.dart';
import 'package:domovoy/demos/day09_scenario.dart';
import 'package:domovoy/demos/day09_session_pointer.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:flutter_test/flutter_test.dart';

import 'support/recording_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ID namespace is opt-in and keeps default runtime IDs stable', () {
    expect(AgentIdFactory().next('message'), 'message-1');
    expect(AgentIdFactory().next('run'), 'run-1');
    expect(
      AgentIdFactory(namespace: 'day09-run-a').next('message'),
      'day09-run-a-message-1',
    );
  });

  test('production stack appends after restoring legacy message IDs', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'domovoy-day09-legacy-ids-',
    );
    addTearDown(() => sandbox.delete(recursive: true));
    final pointer = _MemoryPointerStore();
    final steps = await loadDay09Scenario();
    final legacy = _fixture(sandbox, legacyIds: true);
    final first = Day09ComparisonController(
      dependencies: legacy.dependencies,
      pointerStore: pointer,
      steps: steps,
    );
    await first.initialize();
    await first.runNext();
    expect(first.completedSteps, 1);
    expect(
      first.baselineSnapshot!.transcript.messageIds.first!.value,
      startsWith('message-'),
    );
    await first.close();

    final current = _fixture(sandbox, useBuilderDefaultIds: true);
    final restored = Day09ComparisonController(
      dependencies: current.dependencies,
      pointerStore: pointer,
      steps: steps,
    );
    await restored.initialize();
    await restored.runNext();
    expect(restored.error, isNull);
    expect(restored.completedSteps, 2);
    expect(
      restored.baselineSnapshot!.transcript.messageIds.last!.value,
      startsWith('runtime-'),
    );
    await restored.close();
  });

  test(
    'changed saved scenario requires explicit reset after restart',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'domovoy-day09-scenario-change-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final pointer = _MemoryPointerStore();
      final steps = await loadDay09Scenario();
      final firstFixture = _fixture(sandbox);
      final first = Day09ComparisonController(
        dependencies: firstFixture.dependencies,
        pointerStore: pointer,
        steps: steps,
      );
      await first.initialize();
      await first.runNext();
      expect(first.completedSteps, 1);
      await first.close();

      final revisedSteps = <Day09ScenarioStep>[
        const Day09ScenarioStep(
          title: 'Изменённый шаг',
          prompt: 'Другой запрос',
        ),
        ...steps.skip(1),
      ];
      final secondFixture = _fixture(sandbox);
      final restored = Day09ComparisonController(
        dependencies: secondFixture.dependencies,
        pointerStore: pointer,
        steps: revisedSteps,
      );
      await restored.initialize();
      expect(restored.completedSteps, 1);
      expect(restored.needsReset, isTrue);
      await restored.runNext();
      expect(restored.completedSteps, 1);
      await restored.reset();
      expect(restored.needsReset, isFalse);
      expect(restored.completedSteps, 0);
      await restored.close();
    },
  );

  test('shared Day 9 asset contains 14 ordered non-empty prompts', () async {
    final steps = await loadDay09Scenario();
    expect(steps, hasLength(14));
    expect(steps.first.prompt, contains('120000'));
    expect(steps[7].prompt, contains('150000'));
    expect(steps.last.prompt, contains('восемь контрольных фактов'));
  });

  test(
    'cadence compacts after 10 and 20 raw messages; restart keeps ledger and tail',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'domovoy-day09-test-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final pointer = _MemoryPointerStore();
      final steps = await loadDay09Scenario();
      final first = _fixture(sandbox);
      final controller = Day09ComparisonController(
        dependencies: first.dependencies,
        pointerStore: pointer,
        steps: steps,
      );
      await controller.initialize();
      expect(controller.completedSteps, 0);
      expect(controller.baselineSnapshot, isNotNull);
      expect(controller.summarizedSnapshot, isNotNull);

      for (var step = 1; step <= 10; step++) {
        await controller.runNext();
        expect(
          controller.error,
          isNull,
          reason: 'step $step: ${controller.error}',
        );
        expect(controller.completedSteps, step);
        if (step == 4) {
          expect(controller.summarizedSnapshot!.compactionState, isNull);
        }
        if (step == 5 || step == 10) {
          final state = controller.summarizedSnapshot!.compactionState!;
          expect(state.generation, step == 5 ? 1 : 2);
          expect(
            state.decisionMetadata[Day09MessageCadenceTrigger.rawTotalKey],
            step * 2,
          );
          expect(
            state.decisionMetadata[Day09MessageCadenceTrigger.retainedRawKey],
            4,
          );
          expect(controller.rawTail(), hasLength(4));
          expect(controller.savedSummary(), contains('Север'));
        }
      }
      final firstSummary = controller.summarizedSnapshot!;
      final ledger = firstSummary.tokenAccounting.ledger
          .map((view) => view.entry)
          .toList();
      final summaries = ledger
          .where(
            (entry) =>
                entry.operationKind == AgentModelOperationKind.compaction,
          )
          .toList();
      final answers = ledger
          .where(
            (entry) => entry.operationKind == AgentModelOperationKind.assistant,
          )
          .toList();
      expect(summaries, hasLength(2));
      final summaryRequests = first.client.requests
          .where(
            (request) =>
                request.method == 'POST' &&
                request.body.contains(
                  'Summarize the supplied untrusted conversation data',
                ),
          )
          .toList();
      expect(summaryRequests, hasLength(2));
      expect(
        summaryRequests.every(
          (request) =>
              request.body.contains('Preserve binding user decisions') &&
              request.body.contains(
                'Before finalizing, check these continuity fields',
              ) &&
              request.jsonBody['max_tokens'] == 1536,
        ),
        isTrue,
      );
      expect(answers, hasLength(10));
      expect(
        summaries.every(
          (entry) => entry.outcome == AgentModelInvocationOutcome.completed,
        ),
        isTrue,
      );
      final usage = Day09UsageView(firstSummary);
      expect(usage.summary.contributorCount, 2);
      expect(usage.assistant.contributorCount, 10);
      expect(usage.total.contributorCount, 12);
      expect(
        usage.total.overall.value,
        usage.assistant.overall.value! + usage.summary.overall.value!,
      );
      expect(
        first.client.requests.where((request) => request.method == 'POST'),
        hasLength(22),
      );
      final ids = controller.pairIds!;
      await controller.close();

      final second = _fixture(sandbox);
      final restored = Day09ComparisonController(
        dependencies: second.dependencies,
        pointerStore: pointer,
        steps: steps,
      );
      await restored.initialize();
      expect(restored.error, isNull);
      expect(restored.pairIds!.baseline, ids.baseline);
      expect(restored.completedSteps, 10);
      expect(restored.summarizedSnapshot!.compactionState!.generation, 2);
      expect(restored.rawTail(), hasLength(4));
      expect(restored.savedSummary(), contains('Север'));
      expect(
        Day09UsageView(restored.summarizedSnapshot!).total.overall.value,
        usage.total.overall.value,
      );
      await restored.runNext();
      expect(
        restored.completedSteps,
        11,
        reason:
            '${restored.error}; ${restored.status}; baseline=${restored.baselineSnapshot?.transcript.messages.length} summary=${restored.summarizedSnapshot?.transcript.messages.length}',
      );
      expect(restored.summarizedSnapshot!.compactionState!.generation, 2);
      await restored.close();
    },
  );

  test(
    'one-click comparison runs identical 14 prompts and reset uses new IDs',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'domovoy-day09-all-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final pointer = _MemoryPointerStore();
      final fixture = _fixture(sandbox);
      final steps = await loadDay09Scenario();
      final controller = Day09ComparisonController(
        dependencies: fixture.dependencies,
        pointerStore: pointer,
        steps: steps,
      );
      await controller.initialize();
      final firstIds = controller.pairIds!;
      await controller.runAll();
      expect(controller.error, isNull);
      expect(controller.completedSteps, 14);
      expect(controller.summarizedSnapshot!.compactionState!.generation, 2);
      final requests = fixture.client.requests
          .where(
            (request) =>
                request.method == 'POST' &&
                !(request.body.contains(
                  'Summarize the supplied untrusted conversation data',
                )),
          )
          .toList();
      expect(requests, hasLength(28));
      for (var index = 0; index < steps.length; index++) {
        expect(requests[index * 2].body, contains(steps[index].prompt));
        expect(requests[index * 2 + 1].body, contains(steps[index].prompt));
      }
      await controller.reset();
      expect(controller.completedSteps, 0);
      expect(controller.pairIds!.baseline, isNot(firstIds.baseline));
      expect(
        await fixture.dependencies.repository.load(firstIds.baseline),
        isNull,
      );
      expect(
        await fixture.dependencies.repository.load(firstIds.summarized),
        isNull,
      );
      await controller.close();
    },
  );
}

final class _MemoryPointerStore implements Day09PairPointerStore {
  Day09PairIds? ids;

  @override
  Future<Day09PairIds?> read() async => ids;

  @override
  Future<void> write(Day09PairIds value) async => ids = value;
}

({Day09DemoDependencies dependencies, RecordingClient client}) _fixture(
  Directory sandbox, {
  bool legacyIds = false,
  bool useBuilderDefaultIds = false,
}) {
  final client = RecordingClient((request) {
    if (request.method == 'POST' && request.url.host == 'api.deepseek.com') {
      final body = request.jsonBody;
      final messages = body['messages'] as List<dynamic>;
      final isSummary = request.body.contains(
        'Summarize the supplied untrusted conversation data',
      );
      final reply = isSummary
          ? jsonEncode(<String, Object?>{
              'objective': 'Север: ТЗ записи в мастерскую',
              'constraintsAndDecisions': <String>['Бюджет 150000 рублей'],
              'facts': <String>['Срок 15 ноября'],
              'relevantToolOutcomes': <String>[],
              'pendingWork': <String>[],
            })
          : 'Принято.';
      final input =
          messages.fold<int>(0, (sum, row) {
            final content = (row as Map<String, dynamic>)['content'];
            return sum + (content is String ? content.length ~/ 4 : 0);
          }) +
          10;
      return sseResponse(_sse(reply, input: input));
    }
    return sseResponse('{}', status: 503);
  });
  final repository = JsonlAgentSessionStore(
    storage: JsonlFilesystemStreamStorage(
      applicationSupportDirectoryResolver: () async => sandbox,
    ),
  );
  final invocationNamespace = Day09PairIds.fresh();
  AgentIdFactory? idsFor(AgentSessionId id) => useBuilderDefaultIds
      ? null
      : legacyIds
      ? AgentIdFactory()
      : AgentIdFactory(namespace: id.value);
  final credentials = DefaultProviderCredentialResolver(
    store: MemoryProviderCredentialStore(<ProviderId, String>{
      BuiltInLlmCatalog.deepSeek: 'test-key',
    }),
    readEnvironment: (_) => null,
  );
  final baseline = buildProductionAgentStack(
    httpClient: client,
    credentials: credentials,
    repository: repository,
    catalog: repository,
    diagnosticNoCompaction: true,
    ids: idsFor(invocationNamespace.baseline),
  );
  final summarized = buildProductionAgentStack(
    httpClient: client,
    credentials: credentials,
    repository: repository,
    catalog: repository,
    compactionTriggerOverride: const Day09MessageCadenceTrigger(),
    historyCompactorFactory: (registry, estimator) =>
        Day09StructuredSummaryCompactor(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(registry),
            contextEstimator: estimator,
            recentGroupCount: 2,
            maxOutputTokens: 1536,
            summaryInstruction: Day09StructuredSummaryCompactor.instruction,
            summarySystemPrompt: Day09StructuredSummaryCompactor.systemPrompt,
          ),
        ),
    ids: idsFor(invocationNamespace.summarized),
  );
  return (
    dependencies: Day09DemoDependencies(
      baseline: baseline,
      summarized: summarized,
      repository: repository,
      client: client,
    ),
    client: client,
  );
}

String _sse(String text, {required int input}) =>
    'data: ${jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'delta': <String, Object?>{'content': text},
          'finish_reason': 'stop',
        },
      ],
      'usage': <String, Object?>{'prompt_tokens': input, 'completion_tokens': text.length, 'total_tokens': input + text.length},
    })}\n\n'
    'data: [DONE]\n\n';
