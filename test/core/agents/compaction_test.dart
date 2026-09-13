import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('compaction extension foundation', () {
    test('contracts validate identities, values, and immutable inputs', () {
      final original = <LlmMessage>[_text(LlmMessageRole.user, 'hello')];
      final request = _request(original);
      final source = CancellationSource();
      final input = AgentContextEstimateInput(
        request: request,
        cancellation: source.token,
      );
      original.add(_text(LlmMessageRole.user, 'later'));
      expect(input.request.context.messages, hasLength(1));
      expect(
        () => input.request.context.messages.add(
          _text(LlmMessageRole.user, 'mutation'),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => AgentContextEstimate(
          value: -1,
          estimatorId: 'x',
          estimatorVersion: 1,
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentCompactionDecision.skip(triggerId: ' ', triggerVersion: 1),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentCompactionCandidate(
          strategyId: 'x',
          strategyVersion: 0,
          retainedSuffixBoundaryId: 'b',
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentCompactionInvocationReport(
          invocationOrdinal: -1,
          model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
          outcome: AgentModelInvocationOutcome.completed,
          usage: LlmUsage(),
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentCompactionNoChange(
          strategyId: 'ordered',
          strategyVersion: 1,
          reports: <AgentCompactionInvocationReport>[
            AgentCompactionInvocationReport(
              invocationOrdinal: 1,
              model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
              outcome: AgentModelInvocationOutcome.completed,
              usage: LlmUsage(),
            ),
          ],
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentCompactionStrategyException.cancelled(
          reports: <AgentCompactionInvocationReport>[
            AgentCompactionInvocationReport(
              invocationOrdinal: 0,
              model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
              outcome: AgentModelInvocationOutcome.failed,
              usage: LlmUsage(),
            ),
          ],
        ),
        throwsA(isA<AgentException>()),
      );

      final context = _context(messages: input.request.context.messages);
      expect(context.request.context.messages, hasLength(1));
      expect(context.protectedSeed, isEmpty);
      expect(context.generatedPrefix, isEmpty);
      expect(context.interactionGroups, hasLength(1));
      expect(context.continuationEntries, isEmpty);
      expect(
        () => context.interactionGroups.add(context.interactionGroups.single),
        throwsUnsupportedError,
      );
    });

    test('UTF-8 framing estimator is exact, versioned, and complete', () {
      const estimator = Utf8FramingAgentContextEstimator();
      for (final text in <String>['ASCII', 'Привет', '漢字', '😀']) {
        final request = _request(<LlmMessage>[
          _text(LlmMessageRole.user, text),
        ]);
        final estimate = estimator.estimate(
          AgentContextEstimateInput(
            request: request,
            cancellation: CancellationSource().token,
          ),
        );
        final expected =
            ((utf8.encode(canonicalJsonEncode(request.toJson())).length + 1) ~/
                2) +
            Utf8FramingAgentContextEstimator.requestFramingUnits;
        expect(estimate.value, expected, reason: text);
        expect(estimate.estimatorId, 'utf8-framing');
        expect(estimate.estimatorVersion, 1);
      }

      final base = _request(<LlmMessage>[_text(LlmMessageRole.user, 'a')]);
      final full = LlmRequestSnapshot(
        model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        context: LlmContext(
          systemPrompt: 'system context',
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'a much larger message'),
            _text(LlmMessageRole.assistant, 'answer'),
          ],
          tools: <LlmToolDescriptor>[
            LlmToolDescriptor(
              name: 'lookup',
              description: 'look up a value',
              parameters: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'query': <String, Object?>{'type': 'string'},
                },
              },
            ),
          ],
          continuationEntries: <LlmContinuationEntry>[
            _continuation(1, 'answer'),
          ],
        ),
        generation: LlmGenerationConfig.defaults,
      );
      int estimate(LlmRequestSnapshot value) => estimator
          .estimate(
            AgentContextEstimateInput(
              request: value,
              cancellation: CancellationSource().token,
            ),
          )
          .value;
      expect(estimate(full), greaterThan(estimate(base)));
      expect(estimate(full), estimate(full));
      final canonical = canonicalJsonEncode(full.toJson());
      expect(
        estimate(full),
        ((utf8.encode(canonical).length + 1) ~/ 2) +
            Utf8FramingAgentContextEstimator.requestFramingUnits,
      );
      expect(canonical, contains('system context'));
      expect(canonical, contains('lookup'));
      expect(canonical, contains('openai.responses.output_items.v1'));
    });

    test('estimator cancellation is observed', () {
      final cancellation = CancellationSource()..cancel();
      expect(
        () => const Utf8FramingAgentContextEstimator().estimate(
          AgentContextEstimateInput(
            request: _request(<LlmMessage>[]),
            cancellation: cancellation.token,
          ),
        ),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.cancelled,
          ),
        ),
      );
    });

    test('groups keep a complete tool cycle indivisible', () async {
      final messages = <LlmMessage>[
        _text(LlmMessageRole.user, 'first'),
        LlmMessage(
          role: LlmMessageRole.assistant,
          parts: <LlmContentPart>[
            LlmToolCallPart(
              callId: ToolCallId('c1'),
              name: 'lookup',
              arguments: '{}',
            ),
          ],
        ),
        LlmMessage(
          role: LlmMessageRole.tool,
          parts: <LlmContentPart>[
            LlmToolResultPart(callId: ToolCallId('c1'), content: 'ok'),
          ],
        ),
        _text(LlmMessageRole.assistant, 'done'),
        _text(LlmMessageRole.user, 'second'),
        _text(LlmMessageRole.assistant, 'answer'),
      ];
      final groups = partitionAgentInteractionGroups(
        messages: messages,
        startMessageIndex: 0,
      );
      expect(groups, hasLength(2));
      expect(groups.first.messages, hasLength(4));
      final context = _context(messages: messages);
      final result = RecentInteractionGroupsCompactor(
        1,
      ).compact(context, AgentCompactionDecision.manual());
      expect(
        (await result as AgentCompactionCandidate).retainedSuffixBoundaryId,
        context.interactionGroups.last.suffixBoundaryId,
      );
      expect(
        () => partitionAgentInteractionGroups(
          messages: messages.sublist(2),
          startMessageIndex: 0,
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => partitionAgentInteractionGroups(
          messages: messages.sublist(0, 2),
          startMessageIndex: 0,
        ),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'candidate preserves seed, remaps continuation, and honors target',
      () {
        final seed = <LlmMessage>[_text(LlmMessageRole.user, 'protected')];
        final messages = <LlmMessage>[
          ...seed,
          _text(LlmMessageRole.user, 'old'),
          _text(LlmMessageRole.assistant, 'old answer'),
          _text(LlmMessageRole.user, 'recent'),
          _text(LlmMessageRole.assistant, 'recent answer'),
        ];
        final continuations = <LlmContinuationEntry>[
          _continuation(2, 'old answer'),
          _continuation(4, 'recent answer'),
        ];
        final context = _context(
          messages: messages,
          protected: seed,
          continuations: continuations,
          model: BuiltInLlmCatalog.gpt4oMiniModel,
        );
        final candidate = AgentCompactionCandidate(
          strategyId: 'fake',
          strategyVersion: 1,
          retainedSuffixBoundaryId:
              context.interactionGroups.last.suffixBoundaryId,
        );
        final prepared = prepareAgentCompaction(
          context: context,
          decision: AgentCompactionDecision.manual(),
          candidate: candidate,
          estimator: const Utf8FramingAgentContextEstimator(),
          updatedAtMicros: 9,
        );
        expect(prepared.messages, <LlmMessage>[
          ...seed,
          _text(LlmMessageRole.user, 'recent'),
          _text(LlmMessageRole.assistant, 'recent answer'),
        ]);
        expect(prepared.continuationEntries, hasLength(1));
        expect(prepared.continuationEntries.single.assistantMessageIndex, 2);
        expect(
          prepared.continuationEntries.single.state.payload,
          continuations.last.state.payload,
        );
        expect(prepared.state.generatedPrefixCount, 0);
        expect(prepared.state.removedMessageCount, 2);

        expect(
          () => prepareAgentCompaction(
            context: context,
            decision: AgentCompactionDecision.compact(
              triggerId: 'tight',
              triggerVersion: 1,
              targetEstimate: 0,
            ),
            candidate: candidate,
            estimator: const Utf8FramingAgentContextEstimator(),
            updatedAtMicros: 9,
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
      'invalid boundaries, generated parts, and ineffective rewrites fail',
      () {
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'one'),
            _text(LlmMessageRole.assistant, 'answer'),
            _text(LlmMessageRole.user, 'two'),
          ],
        );
        PreparedAgentCompaction prepare(AgentCompactionCandidate candidate) =>
            prepareAgentCompaction(
              context: context,
              decision: AgentCompactionDecision.manual(),
              candidate: candidate,
              estimator: const Utf8FramingAgentContextEstimator(),
              updatedAtMicros: 1,
            );
        expect(
          () => prepare(
            AgentCompactionCandidate(
              strategyId: 'bad',
              strategyVersion: 1,
              retainedSuffixBoundaryId: 'message:1',
            ),
          ),
          throwsA(isA<AgentException>()),
        );
        expect(
          () => prepare(
            AgentCompactionCandidate(
              strategyId: 'bad',
              strategyVersion: 1,
              retainedSuffixBoundaryId:
                  context.interactionGroups.first.suffixBoundaryId,
            ),
          ),
          throwsA(isA<AgentException>()),
        );
        expect(
          () => prepare(
            AgentCompactionCandidate(
              strategyId: 'bad',
              strategyVersion: 1,
              retainedSuffixBoundaryId:
                  context.interactionGroups.last.suffixBoundaryId,
              generatedPrefix: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.assistant,
                  parts: <LlmContentPart>[LlmReasoningPart('private')],
                ),
              ],
            ),
          ),
          throwsA(isA<AgentException>()),
        );
      },
    );

    test(
      'repeated candidate replaces rather than accumulates generated prefix',
      () {
        final generated = _text(LlmMessageRole.assistant, 'old summary');
        final tail = <LlmMessage>[
          _text(LlmMessageRole.user, 'old'),
          _text(LlmMessageRole.assistant, 'old answer'),
          _text(LlmMessageRole.user, 'new'),
          _text(LlmMessageRole.assistant, 'new answer'),
        ];
        final prior = AgentCompactionState(
          generation: 1,
          generatedPrefixStart: 0,
          generatedPrefixCount: 1,
          reason: AgentCompactionReason.manual,
          triggerId: null,
          triggerVersion: null,
          strategyId: 'summary',
          strategyVersion: 1,
          estimatorId: 'utf8-framing',
          estimatorVersion: 1,
          removedMessageCount: 2,
          beforeEstimate: 1000,
          afterEstimate: 500,
          decisionMetadata: const <String, Object?>{},
          updatedAtMicros: 1,
        );
        final context = _context(
          messages: <LlmMessage>[generated, ...tail],
          generated: <LlmMessage>[generated],
          prior: prior,
        );
        final replacement = _text(LlmMessageRole.assistant, 'new summary');
        final prepared = prepareAgentCompaction(
          context: context,
          decision: AgentCompactionDecision.manual(),
          candidate: AgentCompactionCandidate(
            strategyId: 'summary',
            strategyVersion: 1,
            retainedSuffixBoundaryId:
                context.interactionGroups.last.suffixBoundaryId,
            generatedPrefix: <LlmMessage>[replacement],
          ),
          estimator: const Utf8FramingAgentContextEstimator(),
          updatedAtMicros: 2,
        );
        expect(prepared.messages.first, replacement);
        expect(prepared.messages, isNot(contains(generated)));
        expect(prepared.state.generation, 2);
        expect(prepared.state.generatedPrefixCount, 1);
      },
    );

    test(
      'recent-N is deterministic, supports zero, and reports no change',
      () async {
        expect(
          () => RecentInteractionGroupsCompactor(-1),
          throwsA(isA<AgentException>()),
        );
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'one'),
            _text(LlmMessageRole.assistant, 'a'),
            _text(LlmMessageRole.user, 'two'),
            _text(LlmMessageRole.assistant, 'b'),
            _text(LlmMessageRole.user, 'three'),
            _text(LlmMessageRole.assistant, 'c'),
          ],
        );
        final strategy = RecentInteractionGroupsCompactor(2);
        final decision = AgentCompactionDecision.manual();
        final first = await strategy.compact(context, decision);
        final second = await strategy.compact(context, decision);
        expect(first, isA<AgentCompactionCandidate>());
        expect(
          (first as AgentCompactionCandidate).retainedSuffixBoundaryId,
          context.interactionGroups[1].suffixBoundaryId,
        );
        expect(first.generatedPrefix, isEmpty);
        expect(
          (second as AgentCompactionCandidate).retainedSuffixBoundaryId,
          first.retainedSuffixBoundaryId,
        );

        final zero = await RecentInteractionGroupsCompactor(
          0,
        ).compact(context, decision);
        expect(
          (zero as AgentCompactionCandidate).retainedSuffixBoundaryId,
          context.endBoundaryId,
        );
        final unchanged = await strategy.compact(
          _context(messages: context.interactionGroups.last.messages),
          decision,
        );
        expect(unchanged, isA<AgentCompactionNoChange>());
      },
    );
  });

  group('OpenCode automatic trigger', () {
    test('uses default C/O/H/T/L pressure and overflow recovery', () {
      final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
      final contextBound = model.contextBound;
      final outputReserve = (contextBound * 0.10).ceil();
      final headroom = (contextBound * 0.05).ceil();
      final threshold = contextBound - outputReserve - headroom;
      final target = (threshold * 0.70).floor();
      final trigger = OpenCodeCompactionTrigger();

      final below = _context(
        messages: <LlmMessage>[_text(LlmMessageRole.user, 'below')],
        model: model,
        estimateValue: threshold,
        reason: AgentCompactionReason.preRequest,
      );
      final skipped = trigger.evaluate(below);
      expect(skipped.kind, AgentCompactionDecisionKind.skip);
      expect(skipped.triggerId, OpenCodeCompactionTrigger.id);
      expect(skipped.metadata, <String, Object?>{
        'contextBound': contextBound,
        'outputReserve': outputReserve,
        'headroom': headroom,
        'pressureThreshold': threshold,
        'postCompactionTarget': target,
      });

      final above = _context(
        messages: <LlmMessage>[_text(LlmMessageRole.user, 'above')],
        model: model,
        estimateValue: threshold + 1,
        reason: AgentCompactionReason.preRequest,
      );
      final compact = trigger.evaluate(above);
      expect(compact.kind, AgentCompactionDecisionKind.compact);
      expect(compact.targetEstimate, target);

      final overflow = _context(
        messages: <LlmMessage>[_text(LlmMessageRole.user, 'overflow')],
        model: model,
        estimateValue: 1,
        reason: AgentCompactionReason.providerOverflow,
      );
      expect(
        trigger.evaluate(overflow).kind,
        AgentCompactionDecisionKind.compact,
      );
    });

    test('honors configured reserves, explicit output cap, and validation', () {
      final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
      final trigger = OpenCodeCompactionTrigger(
        outputReserve: 100,
        headroom: 50,
        postCompactionRatio: 0.5,
      );
      final fixed = trigger.evaluate(
        _context(
          messages: <LlmMessage>[_text(LlmMessageRole.user, 'fixed')],
          model: model,
          estimateValue: model.contextBound,
          reason: AgentCompactionReason.preRequest,
        ),
      );
      expect(fixed.targetEstimate, ((model.contextBound - 150) * 0.5).floor());

      final explicit = trigger.evaluate(
        _context(
          messages: <LlmMessage>[_text(LlmMessageRole.user, 'explicit')],
          model: model,
          estimateValue: model.contextBound,
          reason: AgentCompactionReason.preRequest,
          generation: LlmGenerationConfig(maxOutputTokens: 200),
        ),
      );
      expect(explicit.metadata['outputReserve'], 200);
      expect(
        () => OpenCodeCompactionTrigger(outputReserve: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => OpenCodeCompactionTrigger(postCompactionRatio: 1),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'default runtime skips below pressure and compacts above it',
      () async {
        final belowProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('below')],
        );
        final belowCompactor = _RecordingCompactor(
          RecentInteractionGroupsCompactor(0),
        );
        final belowEvents = await testRuntime(
          provider: belowProvider,
          historyCompactor: belowCompactor,
        ).agent(testDefinition()).run('unchanged').events.toList();
        expect(belowCompactor.calls, 0);
        expect(belowProvider.requests.single.context.messages, <LlmMessage>[
          _text(LlmMessageRole.user, 'unchanged'),
        ]);
        expect(belowEvents.whereType<AgentAutomaticCompactionEvent>(), isEmpty);

        final aboveProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('old'), textTurn('above')],
        );
        final estimator = _MessageCountEstimator(multiplier: 400000);
        final aboveCompactor = _RecordingCompactor(
          RecentInteractionGroupsCompactor(1),
        );
        final session = await testRuntime(
          provider: aboveProvider,
          contextEstimator: estimator,
          historyCompactor: aboveCompactor,
        ).agent(testDefinition()).createSession();
        await session.run('old').events.drain<void>();
        final aboveEvents = await session.run('compact').events.toList();
        final automatic = aboveEvents
            .whereType<AgentAutomaticCompactionEvent>()
            .map((event) => event.compaction)
            .toList();
        expect(aboveCompactor.calls, 1);
        expect(aboveProvider.requests, hasLength(2));
        expect(aboveProvider.requests.last.context.messages, <LlmMessage>[
          _text(LlmMessageRole.user, 'compact'),
        ]);
        expect(automatic, hasLength(2));
        expect(automatic.first, isA<AgentCompactionStarted>());
        expect(automatic.last, isA<AgentCompactionSucceeded>());
        expect(automatic.first.reason, AgentCompactionReason.preRequest);
        expect(automatic.first.triggerId, OpenCodeCompactionTrigger.id);
        expect(automatic.first.strategyId, aboveCompactor.id);
        expect(automatic.first.estimatorId, estimator.id);
        expect(automatic.first.targetEstimate, 623902);
        expect((automatic.last as AgentCompactionSucceeded).generation, 1);
        expect(aboveEvents.last, isA<AgentRunCompleted>());
        await session.close();
      },
    );

    test(
      'rejects impossible reserves and protected target before provider',
      () async {
        final tiny = LlmModel(
          providerId: ProviderId('tiny'),
          id: ModelId('tiny'),
          name: 'Tiny',
          wireFamily: LlmWireFamily.openaiChatCompletions,
          capabilities: ModelCapabilities(
            supportsTextInput: true,
            reasoning: ModelReasoningCapability.unsupported,
            supportsTools: false,
          ),
          contextBound: 100,
          outputBound: 80,
        );
        expect(
          () => OpenCodeCompactionTrigger().evaluate(
            _context(
              messages: <LlmMessage>[_text(LlmMessageRole.user, 'tiny')],
              model: tiny,
              estimateValue: 100,
              reason: AgentCompactionReason.preRequest,
            ),
          ),
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.kind,
              'kind',
              AgentErrorKind.compaction,
            ),
          ),
        );

        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('must-not-run')],
        );
        final events =
            await testRuntime(
                  provider: provider,
                  contextEstimator: _MessageCountEstimator(multiplier: 1000000),
                  historyCompactor: RecentInteractionGroupsCompactor(0),
                )
                .agent(
                  testDefinition(
                    initialMessages: <LlmMessage>[
                      _text(LlmMessageRole.user, 'protected'),
                    ],
                  ),
                )
                .run('new')
                .events
                .toList();
        expect(provider.requests, isEmpty);
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.compaction,
        );
      },
    );
  });

  group('forced compaction runtime', () {
    test(
      'manual compaction bypasses skip trigger and retains exact recent N',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b'), textTurn('c')],
        );
        final trigger = _RecordingTrigger(compact: false);
        final compactor = _RecordingCompactor(
          RecentInteractionGroupsCompactor(1),
        );
        final estimator = _MessageCountEstimator();
        final session = await testRuntime(
          provider: provider,
          contextEstimator: estimator,
          compactionTrigger: trigger,
          historyCompactor: compactor,
        ).agent(testDefinition()).createSession();
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        await session.run('three').events.drain<void>();
        final automaticCalls = compactor.calls;
        final operation = session.compact();
        final eventFuture = operation.events.toList();
        expect(await operation.result, AgentCompactionOutcome.compacted);
        final events = await eventFuture;
        expect(compactor.calls, automaticCalls + 1);
        expect(trigger.calls, 3);
        expect(events.first, isA<AgentCompactionStarted>());
        expect(events.last, isA<AgentCompactionSucceeded>());
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last.reason, AgentCompactionReason.manual);
        expect(events.last.strategyId, compactor.id);
        expect(events.last.estimatorId, estimator.id);
        expect(session.snapshot.transcript.messages, <LlmMessage>[
          _text(LlmMessageRole.user, 'three'),
          _text(LlmMessageRole.assistant, 'c'),
        ]);
        expect(session.snapshot.compactionState?.generation, 1);
        final eventCount = events.length;
        await operation.cancel();
        await Future<void>.delayed(Duration.zero);
        expect(events.length, eventCount);
        await session.close();
      },
    );

    test(
      'manual no-change emits one terminal and changes no revision',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a')],
        );
        final repository = _CountingRepository();
        final session =
            await testRuntime(
                  provider: provider,
                  repository: repository,
                  historyCompactor: RecentInteractionGroupsCompactor(1),
                )
                .agent(testDefinition())
                .createSession(persistence: SessionPersistence.repository);
        await session.run('one').events.drain<void>();
        final revision = session.snapshot.revision;
        final saves = repository.saves;
        final operation = session.compact();
        final eventsFuture = operation.events.toList();
        expect(await operation.result, AgentCompactionOutcome.noChange);
        final events = await eventsFuture;
        expect(events.last, isA<AgentCompactionNoChangeEvent>());
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(session.snapshot.revision, revision);
        expect(session.snapshot.compactionState, isNull);
        expect(repository.saves, saves);
        await session.close();
      },
    );

    test('manual no-change usage is charged with all cache fields', () async {
      final usage = LlmUsage(
        inputTokens: 5,
        outputTokens: 3,
        totalTokens: 8,
        cacheHitTokens: 2,
        cacheMissTokens: 3,
      );
      final session = await testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        historyCompactor: _UsageNoChangeCompactor(usage),
      ).agent(testDefinition()).createSession();
      final operation = session.compact();
      final eventFuture = operation.events.toList();
      expect(await operation.result, AgentCompactionOutcome.noChange);
      final terminal = (await eventFuture).last as AgentCompactionNoChangeEvent;
      expect(terminal.usage, usage);
      expect(terminal.reports, hasLength(1));
      expect(session.snapshot.usage.inputTokens, usage.inputTokens);
      expect(session.snapshot.usage.outputTokens, usage.outputTokens);
      expect(session.snapshot.usage.totalTokens, usage.totalTokens);
      expect(session.snapshot.usage.cacheHitTokens, usage.cacheHitTokens);
      expect(session.snapshot.usage.cacheMissTokens, isNull);
      final entry = session.snapshot.tokenAccounting.ledger.single.entry;
      expect(entry.operationKind, AgentModelOperationKind.compaction);
      expect(entry.model, BuiltInLlmCatalog.deepSeekV4FlashModel.ref);
      expect(entry.compactionOperationId, operation.id);
      expect(entry.responseMessageId, isNull);
      expect(session.snapshot.compactionState, isNull);
      await session.close();
    });

    test(
      'manual multi-model reports become ordered separate entries',
      () async {
        final session = await testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          historyCompactor: _MultiInvocationNoChangeCompactor(),
        ).agent(testDefinition()).createSession();

        final operation = session.compact();
        final eventsFuture = operation.events.toList();
        expect(await operation.result, AgentCompactionOutcome.noChange);
        final terminal =
            (await eventsFuture).last as AgentCompactionNoChangeEvent;
        expect(terminal.reports, hasLength(2));
        expect(
          () => terminal.reports.add(terminal.reports.first),
          throwsUnsupportedError,
        );
        final entries = session.snapshot.tokenAccounting.ledger
            .map((view) => view.entry)
            .toList();
        expect(entries, hasLength(2));
        expect(entries.map((entry) => entry.sequence), <int>[1, 2]);
        expect(entries.map((entry) => entry.invocationOrdinal), <int>[0, 1]);
        expect(entries.map((entry) => entry.model), <ModelRef>[
          BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
          BuiltInLlmCatalog.gpt4oMiniModel.ref,
        ]);
        expect(
          entries.map((entry) => entry.outcome),
          <AgentModelInvocationOutcome>[
            AgentModelInvocationOutcome.completed,
            AgentModelInvocationOutcome.failed,
          ],
        );
        expect(
          entries.map((entry) => entry.compactionOperationId).toSet(),
          <AgentCompactionOperationId>{operation.id},
        );
        expect(
          entries.every((entry) => entry.responseMessageId == null),
          isTrue,
        );
        expect(
          session.snapshot.tokenAccounting.assistantConversation.overall.value,
          0,
        );
        expect(session.snapshot.tokenAccounting.compaction.overall.value, 5);
        expect(session.snapshot.tokenAccounting.session.overall.value, 5);
        expect(session.snapshot.tokenAccounting.byModel, hasLength(2));
        await session.close();
      },
    );

    test(
      'manual compactor usage exhausts operation quota before candidate commit',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn('one', usage: LlmUsage(totalTokens: 1)),
            textTurn('two', usage: LlmUsage(totalTokens: 1)),
          ],
        );
        final compactionUsage = LlmUsage(totalTokens: 5, cacheHitTokens: 2);
        final session =
            await testRuntime(
                  provider: provider,
                  historyCompactor: _UsageCandidateCompactor(compactionUsage),
                )
                .agent(testDefinition(budget: AgentTokenBudget(totalTokens: 5)))
                .createSession();
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        final before = session.snapshot.transcript;
        final operation = session.compact();
        final eventFuture = operation.events.toList();
        await expectLater(
          operation.result,
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.kind,
              'kind',
              AgentErrorKind.compaction,
            ),
          ),
        );
        final failed = (await eventFuture).last as AgentCompactionFailed;
        expect(failed.usage, compactionUsage);
        expect(session.snapshot.usage.totalTokens, 7);
        expect(session.snapshot.usage.cacheHitTokens, isNull);
        expect(
          session.snapshot.tokenAccounting.session.cacheRead.knownSubtotal,
          2,
        );
        expect(session.snapshot.transcript, before);
        expect(session.snapshot.compactionState, isNull);
        await session.close();
      },
    );

    test(
      'run and compaction races reject as typed busy without cancellation',
      () async {
        final providerGate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: providerGate,
        );
        final session = await testRuntime(
          provider: provider,
          historyCompactor: RecentInteractionGroupsCompactor(0),
        ).agent(testDefinition()).createSession();
        final run = session.run('one');
        await Future<void>.delayed(Duration.zero);
        expect(() => session.compact(), _busyError);
        providerGate.complete();
        await run.events.drain<void>();

        final gate = Completer<void>();
        final blocker = _GatedNoChangeCompactor(gate);
        final second = await testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[textTurn('unused')],
          ),
          historyCompactor: blocker,
        ).agent(testDefinition()).createSession();
        final operation = second.compact();
        final eventsFuture = operation.events.toList();
        await blocker.started.future;
        expect(() => second.run('two'), _busyError);
        expect(() => second.compact(), _busyError);
        gate.complete();
        expect(await operation.result, AgentCompactionOutcome.noChange);
        await eventsFuture;
        await session.close();
        await second.close();
      },
    );

    test(
      'caller cancellation reaches compactor and emits cancelled once',
      () async {
        final compactor = _CancellationCompactor();
        final session = await testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          historyCompactor: compactor,
        ).agent(testDefinition()).createSession();
        final before = session.snapshot;
        final operation = session.compact();
        final eventsFuture = operation.events.toList();
        await compactor.started.future;
        await operation.cancel();
        final events = await eventsFuture;
        await expectLater(
          operation.result,
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.kind,
              'kind',
              AgentErrorKind.cancelled,
            ),
          ),
        );
        expect(compactor.cancelled, isTrue);
        final cancelled = events.whereType<AgentCompactionCancelled>().single;
        expect(cancelled.reports, hasLength(1));
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(session.snapshot.transcript, before.transcript);
        final entry = session.snapshot.tokenAccounting.ledger.single.entry;
        expect(entry.operationKind, AgentModelOperationKind.compaction);
        expect(entry.outcome, AgentModelInvocationOutcome.cancelled);
        expect(entry.usage.totalTokens, 2);
        expect(entry.responseMessageId, isNull);
        expect(session.lifecycle, AgentSessionLifecycle.idle);
        await session.close();
      },
    );

    test('session close cancels active compaction', () async {
      final compactor = _CancellationCompactor();
      final session = await testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        historyCompactor: compactor,
      ).agent(testDefinition()).createSession();
      final operation = session.compact();
      final eventsFuture = operation.events.toList();
      await compactor.started.future;
      await session.close();
      final events = await eventsFuture;
      expect(compactor.cancelled, isTrue);
      expect(events.whereType<AgentCompactionCancelled>(), hasLength(1));
      expect(session.lifecycle, AgentSessionLifecycle.closed);
    });

    test(
      'repository save precedes exact atomic adoption and restore',
      () async {
        final repository = _CountingRepository();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
        );
        final runtime = testRuntime(
          provider: provider,
          repository: repository,
          historyCompactor: _UsageCandidateCompactor(LlmUsage(totalTokens: 3)),
        );
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        final oldRevision = session.snapshot.revision;
        final operation = session.compact();
        await operation.events.drain<void>();
        expect(await operation.result, AgentCompactionOutcome.compacted);
        expect(session.snapshot.revision, oldRevision + 1);
        final stored = await repository.load(session.id);
        expect(stored?.revision, session.snapshot.revision);
        expect(stored?.transcript, session.snapshot.transcript);
        expect(stored?.compactionState, session.snapshot.compactionState);
        expect(
          stored?.tokenAccounting.entries.last.operationKind,
          AgentModelOperationKind.compaction,
        );
        expect(stored?.tokenAccounting.entries.last.usage.totalTokens, 3);
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.transcript, session.snapshot.transcript);
        expect(restored.snapshot.compactionState?.generation, 1);
        expect(
          restored.snapshot.tokenAccounting.ledger.last.entry,
          session.snapshot.tokenAccounting.ledger.last.entry,
        );
        await restored.close();
      },
    );

    test('validation and conflict failures roll back live state', () async {
      final repository = _ConflictRepository();
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
      );
      final runtime = testRuntime(
        provider: provider,
        repository: repository,
        historyCompactor: RecentInteractionGroupsCompactor(1),
      );
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      await session.run('one').events.drain<void>();
      await session.run('two').events.drain<void>();
      final before = session.snapshot;
      repository.conflictNext = true;
      final operation = session.compact();
      final eventsFuture = operation.events.toList();
      await expectLater(operation.result, throwsA(isA<AgentException>()));
      final events = await eventsFuture;
      expect(
        (events.last as AgentCompactionFailed).error.kind,
        AgentErrorKind.conflict,
      );
      expect(session.snapshot.transcript, before.transcript);
      expect(session.snapshot.revision, before.revision);
      expect(session.snapshot.compactionState, before.compactionState);

      final badRuntime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
        ),
        historyCompactor: _InvalidBoundaryCompactor(),
      );
      final bad = await badRuntime.agent(testDefinition()).createSession();
      await bad.run('one').events.drain<void>();
      await bad.run('two').events.drain<void>();
      final badBefore = bad.snapshot;
      final badOperation = bad.compact();
      await badOperation.events.drain<void>();
      await expectLater(badOperation.result, throwsA(isA<AgentException>()));
      expect(bad.snapshot.transcript, badBefore.transcript);
      expect(bad.snapshot.compactionState, isNull);
      await session.close();
      await bad.close();
    });

    test(
      'failed candidate checkpoint still acknowledges its provider report',
      () async {
        final repository = _FailNextRepository();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
        );
        final session =
            await testRuntime(
                  provider: provider,
                  repository: repository,
                  historyCompactor: _UsageCandidateCompactor(
                    LlmUsage(totalTokens: 4),
                  ),
                )
                .agent(testDefinition())
                .createSession(persistence: SessionPersistence.repository);
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        final before = session.snapshot;
        repository.failNext = true;
        final operation = session.compact();
        final eventsFuture = operation.events.toList();
        await expectLater(operation.result, throwsA(isA<AgentException>()));
        final failed = (await eventsFuture).last as AgentCompactionFailed;
        expect(failed.error.kind, AgentErrorKind.persistence);
        expect(failed.error.message, isNot(contains('secret')));
        expect(session.snapshot.transcript, before.transcript);
        expect(session.snapshot.revision, before.revision + 1);
        final entry = session.snapshot.tokenAccounting.ledger.last.entry;
        expect(entry.operationKind, AgentModelOperationKind.compaction);
        expect(entry.usage.totalTokens, 4);
        final stored = await repository.load(session.id);
        expect(stored?.transcript, before.transcript);
        expect(stored?.tokenAccounting.entries.last, entry);
        await session.close();
      },
    );

    test('repository commit wins later caller cancellation', () async {
      final repository = _CommitWinsCompactionRepository();
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
      );
      final session =
          await testRuntime(
                provider: provider,
                repository: repository,
                historyCompactor: RecentInteractionGroupsCompactor(1),
              )
              .agent(testDefinition())
              .createSession(persistence: SessionPersistence.repository);
      await session.run('one').events.drain<void>();
      await session.run('two').events.drain<void>();
      repository.delayNext = true;
      final before = session.snapshot;
      final operation = session.compact();
      final eventsFuture = operation.events.toList();
      await repository.committed.future;
      final cancelling = operation.cancel();
      repository.acknowledge.complete();
      await cancelling;
      final events = await eventsFuture;
      expect(events.last, isA<AgentCompactionCancelled>());
      expect(session.snapshot.revision, before.revision + 1);
      expect(session.snapshot.compactionState?.generation, 1);
      final stored = await repository.load(session.id);
      expect(stored?.revision, session.snapshot.revision);
      expect(stored?.transcript, session.snapshot.transcript);
      await session.close();
    });

    test(
      'caller cancellation during save wins without live or durable swap',
      () async {
        final repository = _CancellationWinsRepository();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
        );
        final session =
            await testRuntime(
                  provider: provider,
                  repository: repository,
                  historyCompactor: RecentInteractionGroupsCompactor(1),
                )
                .agent(testDefinition())
                .createSession(persistence: SessionPersistence.repository);
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        final before = session.snapshot;
        final storedBefore = await repository.load(session.id);
        repository.cancelNext = true;
        final operation = session.compact();
        final eventsFuture = operation.events.toList();
        await repository.started.future;
        await operation.cancel();
        final events = await eventsFuture;
        expect(events.last, isA<AgentCompactionCancelled>());
        expect(session.snapshot.transcript, before.transcript);
        expect(session.snapshot.revision, before.revision);
        expect(session.snapshot.compactionGeneration, 0);
        final storedAfter = await repository.load(session.id);
        expect(storedAfter, storedBefore);
        await session.close();
      },
    );

    test(
      'custom trigger and estimator swap independently at safe boundary',
      () async {
        final trigger = _RecordingTrigger(compact: true);
        final estimator = _MessageCountEstimator(multiplier: 1000);
        final compactor = _RecordingCompactor(
          RecentInteractionGroupsCompactor(1),
        );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
        );
        final session = await testRuntime(
          provider: provider,
          contextEstimator: estimator,
          compactionTrigger: trigger,
          historyCompactor: compactor,
        ).agent(testDefinition()).createSession();
        await session.run('one').events.drain<void>();
        await session.run('two').events.drain<void>();
        expect(trigger.calls, 2);
        expect(compactor.calls, 2);
        expect(estimator.calls, greaterThanOrEqualTo(3));
        expect(provider.requests.last.context.messages, <LlmMessage>[
          _text(LlmMessageRole.user, 'two'),
        ]);
        expect(trigger.lastContext?.reason, AgentCompactionReason.preRequest);
        expect(trigger.lastContext?.runId, isNotNull);
        expect(trigger.lastContext?.currentEstimate.estimatorId, estimator.id);
        expect(trigger.lastContext?.targetEstimate, isNull);
        expect(compactor.lastDecision?.triggerId, trigger.id);
        expect(compactor.lastContext?.targetEstimate, 1000000);
        await session.close();
      },
    );

    test('unconfigured runtime retains ordinary request behavior', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
      );
      final session = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).createSession();
      await session.run('one').events.drain<void>();
      await session.run('two').events.drain<void>();
      expect(provider.requests.last.context.messages, hasLength(3));
      expect(
        () => session.compact(),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.configuration,
          ),
        ),
      );
      await session.close();
    });
  });

  group('compaction record codec', () {
    test('legacy absence restores as generation zero', () {
      final record = _record(
        transcript: AgentTranscript(
          messages: <LlmMessage>[_text(LlmMessageRole.user, 'legacy')],
        ),
      );
      const codec = AgentSessionCodec();
      final encoded = codec.encode(record);
      expect(encoded, isNot(contains('compactionState')));
      final restored = codec.decode(encoded);
      expect(restored.compactionState, isNull);
      expect(restored.compactionGeneration, 0);
      expect(restored.transcript, record.transcript);
    });

    test('summary and truncation provenance round-trip', () {
      for (final generated in <List<LlmMessage>>[
        <LlmMessage>[_text(LlmMessageRole.assistant, 'summary')],
        const <LlmMessage>[],
      ]) {
        final messages = <LlmMessage>[
          ...generated,
          _text(LlmMessageRole.user, 'tail'),
          _text(LlmMessageRole.assistant, 'answer'),
        ];
        final state = AgentCompactionState(
          generation: 2,
          generatedPrefixStart: 0,
          generatedPrefixCount: generated.length,
          reason: AgentCompactionReason.manual,
          triggerId: null,
          triggerVersion: null,
          strategyId: generated.isEmpty ? 'recent' : 'summary',
          strategyVersion: 1,
          estimatorId: 'utf8-framing',
          estimatorVersion: 1,
          removedMessageCount: 4,
          beforeEstimate: 100,
          afterEstimate: 50,
          decisionMetadata: const <String, Object?>{'mode': 'safe'},
          updatedAtMicros: 2,
        );
        final record = _record(
          transcript: AgentTranscript(messages: messages),
          state: state,
        );
        const codec = AgentSessionCodec();
        expect(codec.decode(codec.encode(record)), record);
      }
    });

    test('malformed prefix, generation, and continuation are rejected', () {
      final generated = _text(LlmMessageRole.assistant, 'summary');
      final state = AgentCompactionState(
        generation: 1,
        generatedPrefixStart: 0,
        generatedPrefixCount: 1,
        reason: AgentCompactionReason.manual,
        triggerId: null,
        triggerVersion: null,
        strategyId: 'summary',
        strategyVersion: 1,
        estimatorId: 'utf8-framing',
        estimatorVersion: 1,
        removedMessageCount: 1,
        beforeEstimate: 100,
        afterEstimate: 50,
        decisionMetadata: const <String, Object?>{},
        updatedAtMicros: 1,
      );
      final record = _record(
        transcript: AgentTranscript(
          messages: <LlmMessage>[generated, _text(LlmMessageRole.user, 'tail')],
        ),
        state: state,
      );
      const codec = AgentSessionCodec();
      final badRange = Map<String, Object?>.from(codec.encode(record));
      final badState = Map<String, Object?>.from(
        badRange['compactionState']! as Map,
      );
      badState['generatedPrefixCount'] = 9;
      badRange['compactionState'] = badState;
      expect(() => codec.decode(badRange), throwsA(isA<AgentException>()));

      final badGeneration = Map<String, Object?>.from(codec.encode(record));
      final generationState = Map<String, Object?>.from(
        badGeneration['compactionState']! as Map,
      );
      generationState['generation'] = 0;
      badGeneration['compactionState'] = generationState;
      expect(() => codec.decode(badGeneration), throwsA(anything));

      final openAiRecord = AgentSessionRecord(
        id: AgentSessionId('continuation'),
        revision: 1,
        definition: testDefinition(model: BuiltInLlmCatalog.gpt4oMiniModel.ref),
        transcript: AgentTranscript(
          messages: <LlmMessage>[
            generated,
            _text(LlmMessageRole.user, 'q'),
            _text(LlmMessageRole.assistant, 'a'),
          ],
        ),
        usage: LlmUsage(),
        modelTurns: 1,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 2,
        compactionState: state,
      );
      final badContinuation = Map<String, Object?>.from(
        codec.encode(openAiRecord),
      );
      badContinuation['continuationEntries'] = <Object?>[
        _continuation(0, 'summary').toJson(),
      ];
      expect(
        () => codec.decode(badContinuation),
        throwsA(isA<AgentException>()),
      );
    });
  });
}

final _busyError = throwsA(
  isA<AgentException>().having(
    (error) => error.error.kind,
    'kind',
    AgentErrorKind.busy,
  ),
);

LlmMessage _text(LlmMessageRole role, String text) =>
    LlmMessage(role: role, parts: <LlmContentPart>[LlmTextPart(text)]);

LlmRequestSnapshot _request(
  List<LlmMessage> messages, {
  LlmModel? model,
  List<LlmContinuationEntry> continuations = const <LlmContinuationEntry>[],
  LlmGenerationConfig? generation,
}) => LlmRequestSnapshot(
  model: (model ?? BuiltInLlmCatalog.deepSeekV4FlashModel).ref,
  context: LlmContext(
    systemPrompt: 'system',
    messages: messages,
    continuationEntries: continuations,
  ),
  generation: generation ?? LlmGenerationConfig.defaults,
);

AgentCompactionContext _context({
  required List<LlmMessage> messages,
  List<LlmMessage> protected = const <LlmMessage>[],
  List<LlmMessage> generated = const <LlmMessage>[],
  List<LlmContinuationEntry> continuations = const <LlmContinuationEntry>[],
  AgentCompactionState? prior,
  LlmModel? model,
  AgentCompactionReason reason = AgentCompactionReason.manual,
  int? estimateValue,
  LlmGenerationConfig? generation,
}) {
  final selected = model ?? BuiltInLlmCatalog.deepSeekV4FlashModel;
  final request = _request(
    messages,
    model: selected,
    continuations: continuations,
    generation: generation,
  );
  const estimator = Utf8FramingAgentContextEstimator();
  final cancellation = CancellationSource();
  final start = protected.length + generated.length;
  return AgentCompactionContext(
    operationId: AgentCompactionOperationId('operation'),
    sessionId: AgentSessionId('session'),
    reason: reason,
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
    currentEstimate: estimateValue == null
        ? estimator.estimate(
            AgentContextEstimateInput(
              request: request,
              cancellation: cancellation.token,
            ),
          )
        : AgentContextEstimate(
            value: estimateValue,
            estimatorId: Utf8FramingAgentContextEstimator.defaultId,
            estimatorVersion: Utf8FramingAgentContextEstimator.defaultVersion,
          ),
    targetEstimate: null,
    cancellation: cancellation.token,
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
            'id': 'message-$index',
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

AgentSessionRecord _record({
  required AgentTranscript transcript,
  AgentCompactionState? state,
}) => AgentSessionRecord(
  id: AgentSessionId('record'),
  revision: 1,
  definition: testDefinition(),
  transcript: transcript,
  usage: LlmUsage(),
  modelTurns: 0,
  toolAttempts: 0,
  createdAtMicros: 1,
  updatedAtMicros: 2,
  compactionState: state,
);

final class _MessageCountEstimator implements AgentContextEstimator {
  _MessageCountEstimator({this.multiplier = 100});

  final int multiplier;
  @override
  final String id = 'message-count';
  var calls = 0;

  @override
  int get version => 1;

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) {
    calls += 1;
    if (input.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    return AgentContextEstimate(
      value: input.request.context.messages.length * multiplier,
      estimatorId: id,
      estimatorVersion: 1,
    );
  }
}

final class _RecordingTrigger implements AgentCompactionTrigger {
  _RecordingTrigger({required this.compact});

  final bool compact;
  final String id = 'recording-trigger';
  var calls = 0;
  AgentCompactionContext? lastContext;

  @override
  AgentCompactionDecision evaluate(AgentCompactionContext context) {
    calls += 1;
    lastContext = context;
    return compact
        ? AgentCompactionDecision.compact(
            triggerId: id,
            triggerVersion: 1,
            targetEstimate: 1000000,
          )
        : AgentCompactionDecision.skip(triggerId: id, triggerVersion: 1);
  }
}

final class _RecordingCompactor implements AgentHistoryCompactor {
  _RecordingCompactor(this.delegate);

  final AgentHistoryCompactor delegate;
  var calls = 0;
  AgentCompactionContext? lastContext;
  AgentCompactionDecision? lastDecision;

  @override
  String get id => delegate.id;

  @override
  int get version => delegate.version;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) {
    calls += 1;
    lastContext = context;
    lastDecision = decision;
    return delegate.compact(context, decision);
  }
}

final class _GatedNoChangeCompactor implements AgentHistoryCompactor {
  _GatedNoChangeCompactor(this.gate);

  final Completer<void> gate;
  final Completer<void> started = Completer<void>();

  @override
  String get id => 'gated';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    started.complete();
    await gate.future;
    return AgentCompactionNoChange(strategyId: id, strategyVersion: version);
  }
}

final class _CancellationCompactor implements AgentHistoryCompactor {
  final Completer<void> started = Completer<void>();
  var cancelled = false;

  @override
  String get id => 'cancellable';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    started.complete();
    await context.cancellation.whenCancelled;
    cancelled = true;
    throw AgentCompactionStrategyException.cancelled(
      reports: <AgentCompactionInvocationReport>[
        AgentCompactionInvocationReport(
          invocationOrdinal: 0,
          model: context.selectedModel.ref,
          outcome: AgentModelInvocationOutcome.cancelled,
          usage: LlmUsage(totalTokens: 2),
        ),
      ],
    );
  }
}

final class _InvalidBoundaryCompactor implements AgentHistoryCompactor {
  @override
  String get id => 'invalid-boundary';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async => AgentCompactionCandidate(
    strategyId: id,
    strategyVersion: version,
    retainedSuffixBoundaryId: 'partial-message-index',
  );
}

final class _UsageNoChangeCompactor implements AgentHistoryCompactor {
  _UsageNoChangeCompactor(this.reportedUsage);

  final LlmUsage reportedUsage;

  @override
  String get id => 'usage-no-change';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async => AgentCompactionNoChange(
    strategyId: id,
    strategyVersion: version,
    reports: <AgentCompactionInvocationReport>[
      AgentCompactionInvocationReport(
        invocationOrdinal: 0,
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: reportedUsage,
      ),
    ],
  );
}

final class _UsageCandidateCompactor implements AgentHistoryCompactor {
  _UsageCandidateCompactor(this.reportedUsage);

  final LlmUsage reportedUsage;

  @override
  String get id => 'usage-candidate';

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
    reports: <AgentCompactionInvocationReport>[
      AgentCompactionInvocationReport(
        invocationOrdinal: 0,
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: reportedUsage,
      ),
    ],
  );
}

final class _MultiInvocationNoChangeCompactor implements AgentHistoryCompactor {
  @override
  String get id => 'multi-invocation-no-change';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async => AgentCompactionNoChange(
    strategyId: id,
    strategyVersion: version,
    reports: <AgentCompactionInvocationReport>[
      AgentCompactionInvocationReport(
        invocationOrdinal: 0,
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: LlmUsage(totalTokens: 2),
      ),
      AgentCompactionInvocationReport(
        invocationOrdinal: 1,
        model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        outcome: AgentModelInvocationOutcome.failed,
        usage: LlmUsage(totalTokens: 3),
      ),
    ],
  );
}

class _CountingRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository inner = InMemoryAgentSessionRepository();
  var saves = 0;

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => inner.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    saves += 1;
    return inner.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }
}

final class _ConflictRepository extends _CountingRepository {
  var conflictNext = false;

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (conflictNext) {
      conflictNext = false;
      throwAgent(AgentErrorKind.conflict, 'concurrent update');
    }
    return super.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }
}

final class _FailNextRepository extends _CountingRepository {
  var failNext = false;

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (failNext) {
      failNext = false;
      return Future<void>.error(StateError('repository-secret'));
    }
    return super.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }
}

final class _CommitWinsCompactionRepository extends _CountingRepository {
  var delayNext = false;
  final Completer<void> committed = Completer<void>();
  final Completer<void> acknowledge = Completer<void>();

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (!delayNext) {
      return super.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    delayNext = false;
    saves += 1;
    await inner.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: CancellationSource().token,
    );
    committed.complete();
    await acknowledge.future;
  }
}

final class _CancellationWinsRepository extends _CountingRepository {
  var cancelNext = false;
  final Completer<void> started = Completer<void>();

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (!cancelNext) {
      return super.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    cancelNext = false;
    saves += 1;
    final wait = Completer<void>();
    final registration = cancellation.register(() {
      if (!wait.isCompleted) {
        wait.completeError(
          AgentException(
            AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
          ),
        );
      }
    });
    started.complete();
    try {
      await wait.future;
    } finally {
      registration.dispose();
    }
  }
}
