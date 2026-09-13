import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('OpenCode summary compactor', () {
    test('configuration bounds are validated', () {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      );
      final invocation = RegistryAgentSummaryLlmInvocation(_registry(provider));
      expect(
        () => OpenCodeSummaryCompactor(llm: invocation, recentGroupCount: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => OpenCodeSummaryCompactor(llm: invocation, maxInputCharacters: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => OpenCodeSummaryCompactor(llm: invocation, maxOutputCharacters: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => OpenCodeSummaryCompactor(llm: invocation, maxOutputTokens: 0),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'same-model request is bounded, non-privileged, and continuation-free',
      () async {
        final usage = LlmUsage(
          inputTokens: 11,
          outputTokens: 7,
          totalTokens: 18,
          cacheHitTokens: 3,
          cacheMissTokens: 8,
        );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.openAi,
          wireFamily: LlmWireFamily.openaiResponses,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              LlmUsageUpdate(LlmUsage(totalTokens: 10)),
              LlmUsageUpdate(usage),
              LlmTextDelta(
                _summaryPayload(objective: 'Keep the recent answer'),
              ),
              LlmCompleted(finishReason: LlmFinishReason.stop, usage: usage),
            ],
          ],
        );
        final registry = _registry(provider);
        final protected = _text(LlmMessageRole.user, 'protected-secret');
        final messages = <LlmMessage>[
          protected,
          _text(LlmMessageRole.user, 'old question'),
          _text(LlmMessageRole.assistant, 'old answer'),
          _text(LlmMessageRole.user, 'recent question'),
          _text(LlmMessageRole.assistant, 'recent answer'),
        ];
        final context = _context(
          messages: messages,
          protected: <LlmMessage>[protected],
          continuations: <LlmContinuationEntry>[
            _continuation(2, 'opaque-continuation-secret'),
          ],
          model: BuiltInLlmCatalog.gpt4oMiniModel,
        );
        final compactor = OpenCodeSummaryCompactor(
          llm: RegistryAgentSummaryLlmInvocation(registry),
          maxOutputTokens: 123,
        );

        final candidate =
            await compactor.compact(context, AgentCompactionDecision.manual())
                as AgentCompactionCandidate;
        expect(candidate.strategyId, compactor.id);
        expect(candidate.usage, usage);
        expect(candidate.reports, hasLength(1));
        expect(candidate.reports.single.invocationOrdinal, 0);
        expect(candidate.reports.single.model, context.selectedModel.ref);
        expect(
          candidate.reports.single.outcome,
          AgentModelInvocationOutcome.completed,
        );
        expect(candidate.reports.single.usage, usage);
        expect(
          candidate.retainedSuffixBoundaryId,
          context.interactionGroups.last.suffixBoundaryId,
        );
        expect(candidate.generatedPrefix, hasLength(1));
        expect(candidate.generatedPrefix.single.role, LlmMessageRole.assistant);
        expect(
          candidate.generatedPrefix.single.parts,
          everyElement(isA<LlmTextPart>()),
        );

        final request = provider.requests.single;
        expect(request.model, context.selectedModel.ref);
        expect(request.generation.maxOutputTokens, 123);
        expect(request.context.systemPrompt, isNull);
        expect(request.context.tools, isEmpty);
        expect(request.context.continuationEntries, isEmpty);
        expect(request.context.messages, hasLength(1));
        expect(request.context.messages.single.role, LlmMessageRole.user);
        final prompt =
            request.context.messages.single.parts.single as LlmTextPart;
        expect(prompt.text, contains('old question'));
        expect(prompt.text, isNot(contains('recent question')));
        expect(prompt.text, isNot(contains('protected-secret')));
        expect(prompt.text, isNot(contains('opaque-continuation-secret')));

        final generatedText =
            candidate.generatedPrefix.single.parts.single as LlmTextPart;
        final generated =
            jsonDecode(generatedText.text) as Map<String, Object?>;
        expect(generated['type'], OpenCodeSummaryCompactor.summaryType);
        expect(generated['version'], OpenCodeSummaryCompactor.summaryVersion);
        expect(generated['objective'], 'Keep the recent answer');
        expect(candidate.metadata['summaryModel'], 'gpt-4o-mini');
      },
    );

    test('alternate registered model is selected by the strategy', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.openAi,
        wireFamily: LlmWireFamily.openaiResponses,
        turns: <List<LlmEvent>>[
          textTurn(_summaryPayload(objective: 'Alternate model summary')),
        ],
      );
      final registry = _registry(provider);
      final context = _context(
        messages: <LlmMessage>[
          _text(LlmMessageRole.user, 'old'),
          _text(LlmMessageRole.assistant, 'old answer'),
          _text(LlmMessageRole.user, 'recent'),
        ],
      );
      final compactor = OpenCodeSummaryCompactor(
        llm: RegistryAgentSummaryLlmInvocation(registry),
        modelSelector: FixedAgentSummaryModelSelector(
          BuiltInLlmCatalog.gpt4oMiniModel.ref,
        ),
      );

      final result = await compactor.compact(
        context,
        AgentCompactionDecision.manual(),
      );
      expect(result, isA<AgentCompactionCandidate>());
      expect(
        provider.requests.single.model,
        BuiltInLlmCatalog.gpt4oMiniModel.ref,
      );
      expect(
        result.metadata,
        containsPair('summaryModelProvider', BuiltInLlmCatalog.openAi.value),
      );
      expect(result.reports.single.model, BuiltInLlmCatalog.gpt4oMiniModel.ref);
    });

    test(
      'empty, invalid, failed, oversized, and over-bound results fail safely',
      () async {
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'old'),
            _text(LlmMessageRole.assistant, 'answer'),
            _text(LlmMessageRole.user, 'recent'),
          ],
        );
        final billed = LlmUsage(totalTokens: 9, cacheHitTokens: 4);

        Future<AgentCompactionStrategyException> failureFor(
          List<LlmEvent> events, {
          int maxOutputCharacters = 16384,
        }) async {
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[events],
          );
          final registry = _registry(provider);
          try {
            await OpenCodeSummaryCompactor(
              llm: RegistryAgentSummaryLlmInvocation(registry),
              maxOutputCharacters: maxOutputCharacters,
            ).compact(context, AgentCompactionDecision.manual());
          } on AgentCompactionStrategyException catch (error) {
            return error;
          }
          fail('Expected summary compaction to fail.');
        }

        final empty = await failureFor(<LlmEvent>[
          LlmUsageUpdate(billed),
          LlmCompleted(finishReason: LlmFinishReason.stop, usage: billed),
        ]);
        expect(empty.error.kind, AgentErrorKind.compaction);
        expect(empty.usage, billed);
        expect(empty.reports.single.model, context.selectedModel.ref);
        expect(
          empty.reports.single.outcome,
          AgentModelInvocationOutcome.failed,
        );

        final invalid = await failureFor(<LlmEvent>[
          const LlmTextDelta('{"objective":"missing sections"}'),
          LlmCompleted(finishReason: LlmFinishReason.stop, usage: billed),
        ]);
        expect(invalid.usage, billed);

        final failed = await failureFor(<LlmEvent>[
          LlmUsageUpdate(billed),
          LlmFailed(
            LlmError(
              kind: LlmErrorKind.provider,
              message: 'provider-secret-detail',
            ),
          ),
        ]);
        expect(failed.toString(), isNot(contains('provider-secret-detail')));
        expect(failed.usage, billed);
        expect(failed.reports, hasLength(1));

        final oversized = await failureFor(<LlmEvent>[
          const LlmTextDelta('0123456789'),
          const LlmCompleted(finishReason: LlmFinishReason.stop),
        ], maxOutputCharacters: 5);
        expect(oversized.error.kind, AgentErrorKind.compaction);

        final inputProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        );
        final inputRegistry = _registry(inputProvider);
        await expectLater(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(inputRegistry),
            maxInputCharacters: 10,
          ).compact(context, AgentCompactionDecision.manual()),
          throwsA(isA<AgentCompactionStrategyException>()),
        );
        expect(inputProvider.requests, isEmpty);

        await expectLater(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(inputRegistry),
            maxOutputTokens:
                BuiltInLlmCatalog.deepSeekV4FlashModel.outputBound + 1,
          ).compact(context, AgentCompactionDecision.manual()),
          throwsA(isA<AgentCompactionStrategyException>()),
        );
        expect(inputProvider.requests, isEmpty);

        await expectLater(
          OpenCodeSummaryCompactor(
            llm: _IncompleteSummaryInvocation(),
          ).compact(context, AgentCompactionDecision.manual()),
          throwsA(isA<AgentCompactionStrategyException>()),
        );
      },
    );

    test(
      'inflated summary is rejected by strategy-neutral validation',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(_summaryPayload(objective: _repeat('x', 1000))),
          ],
        );
        final registry = _registry(provider);
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'a'),
            _text(LlmMessageRole.assistant, 'b'),
            _text(LlmMessageRole.user, 'c'),
          ],
        );
        final candidate = await OpenCodeSummaryCompactor(
          llm: RegistryAgentSummaryLlmInvocation(registry),
        ).compact(context, AgentCompactionDecision.manual());
        expect(
          () => prepareAgentCompaction(
            context: context,
            decision: AgentCompactionDecision.manual(),
            candidate: candidate as AgentCompactionCandidate,
            estimator: const Utf8FramingAgentContextEstimator(),
            updatedAtMicros: 1,
          ),
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.kind,
              'kind',
              AgentErrorKind.compaction,
            ),
          ),
        );
      },
    );

    test(
      'repeated summary replaces prior prefix and no-source returns no-change',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(_summaryPayload(objective: 'Replacement')),
          ],
        );
        final registry = _registry(provider);
        final seed = _text(LlmMessageRole.user, 'protected');
        final oldSummary = _text(
          LlmMessageRole.assistant,
          canonicalJsonEncode(<String, Object?>{
            'type': OpenCodeSummaryCompactor.summaryType,
            'version': 1,
            'objective': 'Old summary',
            'constraintsAndDecisions': <String>[],
            'facts': <String>[],
            'relevantToolOutcomes': <String>[],
            'pendingWork': <String>[],
          }),
        );
        final context = _context(
          messages: <LlmMessage>[
            seed,
            oldSummary,
            _text(LlmMessageRole.user, 'old ${_repeat('x', 4000)}'),
            _text(LlmMessageRole.assistant, 'answer ${_repeat('y', 4000)}'),
            _text(LlmMessageRole.user, 'recent'),
          ],
          protected: <LlmMessage>[seed],
          generated: <LlmMessage>[oldSummary],
          prior: AgentCompactionState(
            generation: 1,
            generatedPrefixStart: 1,
            generatedPrefixCount: 1,
            reason: AgentCompactionReason.manual,
            triggerId: null,
            triggerVersion: null,
            strategyId: 'older-summary',
            strategyVersion: 1,
            estimatorId: Utf8FramingAgentContextEstimator.defaultId,
            estimatorVersion: Utf8FramingAgentContextEstimator.defaultVersion,
            removedMessageCount: 2,
            beforeEstimate: 1000,
            afterEstimate: 500,
            decisionMetadata: const <String, Object?>{},
            updatedAtMicros: 1,
          ),
        );
        final compactor = OpenCodeSummaryCompactor(
          llm: RegistryAgentSummaryLlmInvocation(registry),
        );
        final candidate =
            await compactor.compact(context, AgentCompactionDecision.manual())
                as AgentCompactionCandidate;
        final prompt =
            provider.requests.single.context.messages.single.parts.single
                as LlmTextPart;
        expect(prompt.text, contains('Old summary'));
        final prepared = prepareAgentCompaction(
          context: context,
          decision: AgentCompactionDecision.manual(),
          candidate: candidate,
          estimator: const Utf8FramingAgentContextEstimator(),
          updatedAtMicros: 2,
        );
        expect(prepared.messages, isNot(contains(oldSummary)));
        expect(prepared.state.generation, 2);
        expect(prepared.state.generatedPrefixCount, 1);
        expect(
          prepared.messages[prepared.state.generatedPrefixStart],
          candidate.generatedPrefix.single,
        );

        final noChangeProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        );
        final noChange =
            await OpenCodeSummaryCompactor(
              llm: RegistryAgentSummaryLlmInvocation(
                _registry(noChangeProvider),
              ),
            ).compact(
              _context(
                messages: <LlmMessage>[
                  _text(LlmMessageRole.user, 'only current group'),
                ],
              ),
              AgentCompactionDecision.manual(),
            );
        expect(noChange, isA<AgentCompactionNoChange>());
        expect(noChangeProvider.requests, isEmpty);
      },
    );

    test('cancellation reaches the summary invocation', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: <LlmEvent>[LlmUsageUpdate(LlmUsage(totalTokens: 4))],
        gate: gate,
      );
      final registry = _registry(provider);
      final cancellation = CancellationSource();
      final context = _context(
        messages: <LlmMessage>[
          _text(LlmMessageRole.user, 'old'),
          _text(LlmMessageRole.assistant, 'answer'),
          _text(LlmMessageRole.user, 'recent'),
        ],
        cancellation: cancellation.token,
      );
      final future = OpenCodeSummaryCompactor(
        llm: RegistryAgentSummaryLlmInvocation(registry),
      ).compact(context, AgentCompactionDecision.manual());
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests, hasLength(1));
      cancellation.cancel();
      try {
        await future;
        fail('Expected summary compaction cancellation.');
      } on AgentCompactionStrategyException catch (error) {
        expect(error.error.kind, AgentErrorKind.cancelled);
        expect(error.reports, hasLength(1));
        expect(error.reports.single.model, context.selectedModel.ref);
        expect(error.reports.single.invocationOrdinal, 0);
        expect(
          error.reports.single.outcome,
          AgentModelInvocationOutcome.cancelled,
        );
        expect(error.reports.single.usage.totalTokens, 4);
      }
    });

    test('summary, recent-N, and custom no-LLM share one contract', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          textTurn(_summaryPayload(objective: 'Summary')),
        ],
      );
      final context = _context(
        messages: <LlmMessage>[
          _text(LlmMessageRole.user, 'old'),
          _text(LlmMessageRole.assistant, 'answer'),
          _text(LlmMessageRole.user, 'recent'),
        ],
      );
      final strategies = <AgentHistoryCompactor>[
        OpenCodeSummaryCompactor(
          llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
        ),
        RecentInteractionGroupsCompactor(1),
        _CustomNoLlmCompactor(),
      ];
      final results = <AgentCompactionStrategyResult>[];
      for (final strategy in strategies) {
        results.add(
          await strategy.compact(context, AgentCompactionDecision.manual()),
        );
      }
      expect(
        (results.first as AgentCompactionCandidate).generatedPrefix,
        hasLength(1),
      );
      expect((results[1] as AgentCompactionCandidate).generatedPrefix, isEmpty);
      expect((results[2] as AgentCompactionCandidate).generatedPrefix, isEmpty);
      expect(results.first.reports, hasLength(1));
      expect(results[1].reports, isEmpty);
      expect(results[2].reports, isEmpty);
      expect(provider.requests, hasLength(1));
    });
  });
}

LlmProviderRegistry _registry(LlmProvider provider) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(provider);
  return registry;
}

String _summaryPayload({required String objective}) =>
    jsonEncode(<String, Object?>{
      'objective': objective,
      'constraintsAndDecisions': <String>['Keep extension boundaries'],
      'facts': <String>['The recent group remains verbatim'],
      'relevantToolOutcomes': <String>[],
      'pendingWork': <String>['Continue safely'],
    });

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

LlmMessage _text(LlmMessageRole role, String text) =>
    LlmMessage(role: role, parts: <LlmContentPart>[LlmTextPart(text)]);

AgentCompactionContext _context({
  required List<LlmMessage> messages,
  List<LlmMessage> protected = const <LlmMessage>[],
  List<LlmMessage> generated = const <LlmMessage>[],
  List<LlmContinuationEntry> continuations = const <LlmContinuationEntry>[],
  AgentCompactionState? prior,
  LlmModel? model,
  CancellationToken? cancellation,
}) {
  final selected = model ?? BuiltInLlmCatalog.deepSeekV4FlashModel;
  final token = cancellation ?? CancellationSource().token;
  final request = LlmRequestSnapshot(
    model: selected.ref,
    context: LlmContext(
      systemPrompt: 'protected-system-secret',
      messages: messages,
      tools: <LlmToolDescriptor>[
        LlmToolDescriptor(
          name: 'secret-tool',
          parameters: const <String, Object?>{'type': 'object'},
        ),
      ],
      continuationEntries: continuations,
    ),
    generation: LlmGenerationConfig.defaults,
  );
  const estimator = Utf8FramingAgentContextEstimator();
  final start = protected.length + generated.length;
  return AgentCompactionContext(
    operationId: AgentCompactionOperationId('summary-operation'),
    sessionId: AgentSessionId('summary-session'),
    reason: AgentCompactionReason.manual,
    selectedModel: selected,
    request: request,
    protectedSeed: protected,
    generatedPrefix: generated,
    interactionGroups: partitionAgentInteractionGroups(
      messages: messages,
      startMessageIndex: start,
    ),
    continuationEntries: continuations,
    priorState: prior,
    currentEstimate: estimator.estimate(
      AgentContextEstimateInput(request: request, cancellation: token),
    ),
    targetEstimate: null,
    cancellation: token,
  );
}

LlmContinuationEntry _continuation(int index, String text) =>
    LlmContinuationEntry(
      assistantMessageIndex: index,
      state: LlmProviderTurnState(
        origin: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        wireFamily: LlmWireFamily.openaiResponses,
        format: openaiResponsesOutputItemsV1,
        payload: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'message',
            'id': 'opaque-$index',
            'role': 'assistant',
            'content': <Map<String, Object?>>[
              <String, Object?>{
                'type': 'output_text',
                'text': text,
                'annotations': <Object?>[],
              },
            ],
          },
        ],
      ),
    );

final class _CustomNoLlmCompactor implements AgentHistoryCompactor {
  @override
  String get id => 'custom-no-llm';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async => AgentCompactionCandidate(
    strategyId: id,
    strategyVersion: version,
    retainedSuffixBoundaryId: context.interactionGroups.last.suffixBoundaryId,
  );
}

final class _IncompleteSummaryInvocation implements AgentSummaryLlmInvocation {
  @override
  LlmModel resolve(ModelRef model) => BuiltInLlmCatalog.deepSeekV4FlashModel;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) => Stream<LlmEvent>.value(
    LlmTextDelta(_summaryPayload(objective: 'missing terminal')),
  );
}
