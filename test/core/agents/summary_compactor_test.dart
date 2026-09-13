import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/llm/openai_responses/openai_responses.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/recording_http_client.dart';
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
        () => OpenCodeSummaryCompactor(llm: invocation, headroom: 0),
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
      expect(
        () =>
            OpenCodeSummaryCompactor(llm: invocation, maxSummaryInvocations: 0),
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
          _text(LlmMessageRole.user, 'old ${_repeat('x', 1000)}'),
          _text(LlmMessageRole.assistant, 'old answer ${_repeat('y', 1000)}'),
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
            headroom: context.selectedModel.contextBound,
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
        await expectLater(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(registry),
          ).compact(context, AgentCompactionDecision.manual()),
          throwsA(
            isA<AgentCompactionStrategyException>().having(
              (error) => error.error.kind,
              'kind',
              AgentErrorKind.compaction,
            ),
          ),
        );
      },
    );

    test('capacity uses every catalog model output bound and headroom', () {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      );
      final compactor = OpenCodeSummaryCompactor(
        llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
        maxOutputTokens: 200000,
      );
      for (final model in BuiltInLlmCatalog.models) {
        final outputAllowance = model.outputBound < 200000
            ? model.outputBound
            : 200000;
        final resolvedHeadroom = (model.contextBound * 0.05).ceil() < 1024
            ? 1024
            : (model.contextBound * 0.05).ceil();
        expect(
          compactor.inputCapacityFor(model),
          model.contextBound - outputAllowance - resolvedHeadroom,
          reason: model.ref.toString(),
        );
      }
      final configured = OpenCodeSummaryCompactor(
        llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
        maxOutputTokens: 500,
        headroom: 250,
      );
      expect(
        configured.inputCapacityFor(BuiltInLlmCatalog.gpt4oMiniModel),
        BuiltInLlmCatalog.gpt4oMiniModel.contextBound - 750,
      );
    });

    test(
      'production defaults compact histories beyond the former cap for each provider',
      () async {
        const estimator = Utf8FramingAgentContextEstimator();
        final messages = <LlmMessage>[
          for (var index = 0; index < 40; index++) ...<LlmMessage>[
            _text(LlmMessageRole.user, 'question-$index ${_repeat('q', 3500)}'),
            _text(
              LlmMessageRole.assistant,
              'answer-$index ${_repeat('a', 3500)}',
            ),
          ],
        ];
        expect(
          messages
              .expand((message) => message.parts)
              .whereType<LlmTextPart>()
              .fold<int>(0, (total, part) => total + part.text.length),
          greaterThan(262144),
        );

        for (final model in <LlmModel>[
          BuiltInLlmCatalog.deepSeekV4FlashModel,
          BuiltInLlmCatalog.kimiK26Model,
          BuiltInLlmCatalog.gpt4oMiniModel,
        ]) {
          final provider = QueueScriptedLlmProvider(
            id: model.providerId,
            wireFamily: model.wireFamily,
            turns: List<List<LlmEvent>>.generate(
              32,
              (index) => textTurn(
                _summaryPayload(objective: '${model.id.value}-$index'),
                usage: LlmUsage(totalTokens: index + 1),
              ),
            ),
          );
          final compactor = OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
            contextEstimator: estimator,
          );
          final context = _context(
            messages: messages,
            model: model,
            estimator: estimator,
          );

          final candidate =
              await compactor.compact(context, AgentCompactionDecision.manual())
                  as AgentCompactionCandidate;

          expect(provider.requests, isNotEmpty, reason: model.ref.toString());
          expect(provider.requests.length, lessThanOrEqualTo(32));
          expect(candidate.reports, hasLength(provider.requests.length));
          expect(
            candidate.metadata['summarizedGroupCount'],
            39,
            reason: model.ref.toString(),
          );
          for (final request in provider.requests) {
            final estimate = estimator.estimate(
              AgentContextEstimateInput(
                request: request.snapshot(),
                cancellation: context.cancellation,
              ),
            );
            expect(
              estimate.value,
              lessThanOrEqualTo(compactor.inputCapacityFor(model)),
              reason: model.ref.toString(),
            );
          }
        }
      },
    );

    test(
      'maximal complete-group batches roll summaries and aggregate exact usage',
      () async {
        final turns = List<List<LlmEvent>>.generate(8, (index) {
          final usage = LlmUsage(
            inputTokens: index + 1,
            outputTokens: 1,
            totalTokens: index + 2,
          );
          return textTurn(
            _summaryPayload(objective: 'rolling-$index'),
            usage: usage,
          );
        });
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: turns,
        );
        final estimator = _PromptLengthEstimator();
        final messages = <LlmMessage>[
          for (var index = 0; index < 7; index++) ...<LlmMessage>[
            _text(LlmMessageRole.user, 'question-$index ${_repeat('q', 260)}'),
            if (index == 2) ...<LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.assistant,
                parts: <LlmContentPart>[
                  LlmToolCallPart(
                    callId: ToolCallId('call-$index'),
                    name: 'lookup',
                    arguments: '{"index":$index}',
                  ),
                ],
              ),
              LlmMessage(
                role: LlmMessageRole.tool,
                parts: <LlmContentPart>[
                  LlmToolResultPart(
                    callId: ToolCallId('call-$index'),
                    content: 'tool-result-$index ${_repeat('t', 120)}',
                  ),
                ],
              ),
            ],
            _text(
              LlmMessageRole.assistant,
              'answer-$index ${_repeat('a', 260)}',
            ),
          ],
        ];
        const capacity = 2100;
        final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
        final context = _context(
          messages: messages,
          estimator: estimator,
          model: model,
        );
        final compactor = OpenCodeSummaryCompactor(
          llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
          contextEstimator: estimator,
          headroom: model.contextBound - 4096 - capacity,
        );

        final candidate =
            await compactor.compact(context, AgentCompactionDecision.manual())
                as AgentCompactionCandidate;

        expect(candidate.reports.length, greaterThan(1));
        expect(candidate.reports.length, lessThanOrEqualTo(6));
        expect(
          candidate.reports.map((report) => report.invocationOrdinal),
          List<int>.generate(candidate.reports.length, (index) => index),
        );
        expect(
          candidate.reports.map((report) => report.usage.totalTokens),
          List<int>.generate(candidate.reports.length, (index) => index + 2),
        );
        expect(
          candidate.usage!.totalTokens,
          candidate.reports.fold<int>(
            0,
            (total, report) => total + report.usage.totalTokens!,
          ),
        );
        for (final request in provider.requests) {
          expect(
            estimator.valueFor(request.snapshot()),
            lessThanOrEqualTo(capacity),
          );
        }
        for (var index = 1; index < provider.requests.length; index++) {
          final prompt = _requestPrompt(provider.requests[index]);
          expect(prompt, contains('rolling-${index - 1}'));
          expect(prompt, isNot(contains('rolling-${index - 2}')));
        }
        final toolRequest = provider.requests.singleWhere(
          (request) => _requestPrompt(request).contains('tool-result-2'),
        );
        final toolPrompt = _requestPrompt(toolRequest);
        expect(toolPrompt, contains('tool-result-2'));
        expect(toolPrompt, contains('answer-2'));
      },
    );

    test('required-reasoning turn state is accepted and discarded', () async {
      const opaqueSecret = 'opaque-reasoning-secret';
      final turnState = LlmProviderTurnState(
        origin: BuiltInLlmCatalog.gpt5MiniModel.ref,
        wireFamily: LlmWireFamily.openaiResponses,
        format: openaiResponsesOutputItemsV1,
        payload: const <Map<String, Object?>>[
          <String, Object?>{
            'type': 'reasoning',
            'id': 'reasoning-summary',
            'encrypted_content': opaqueSecret,
          },
        ],
      );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.openAi,
        wireFamily: LlmWireFamily.openaiResponses,
        turns: <List<LlmEvent>>[
          <LlmEvent>[
            LlmReasoningDelta('private reasoning'),
            LlmTextDelta(_summaryPayload(objective: 'reasoning summary')),
            LlmCompleted(
              finishReason: LlmFinishReason.stop,
              turnState: turnState,
            ),
          ],
        ],
      );
      final context = _context(
        messages: <LlmMessage>[
          _text(LlmMessageRole.user, 'old ${_repeat('x', 1000)}'),
          _text(LlmMessageRole.assistant, 'answer ${_repeat('y', 1000)}'),
          _text(LlmMessageRole.user, 'recent'),
        ],
      );
      final candidate =
          await OpenCodeSummaryCompactor(
                llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
                modelSelector: FixedAgentSummaryModelSelector(
                  BuiltInLlmCatalog.gpt5MiniModel.ref,
                ),
              ).compact(context, AgentCompactionDecision.manual())
              as AgentCompactionCandidate;

      expect(
        provider.requests.single.generation.reasoningMode,
        ReasoningMode.enabled,
      );
      expect(provider.requests.single.context.continuationEntries, isEmpty);
      expect(
        candidate.generatedPrefix.toString(),
        isNot(contains(opaqueSecret)),
      );
      expect(candidate.metadata.toString(), isNot(contains(opaqueSecret)));
      expect(
        candidate.reports.single.model,
        BuiltInLlmCatalog.gpt5MiniModel.ref,
      );
    });

    test(
      'real Responses reasoning completion is summarized without state replay',
      () async {
        const opaqueSecret = 'encrypted-real-summary-secret';
        final summary = _summaryPayload(objective: 'real Responses summary');
        final client = RecordingClient(
          (_) => sseResponse(
            'event: response.output_item.done\n'
            'data: ${jsonEncode(<String, Object?>{
              'type': 'response.output_item.done',
              'output_index': 0,
              'item': <String, Object?>{'type': 'reasoning', 'id': 'rs_summary', 'status': 'completed', 'encrypted_content': opaqueSecret},
            })}\n\n'
            'event: response.output_item.done\n'
            'data: ${jsonEncode(<String, Object?>{
              'type': 'response.output_item.done',
              'output_index': 1,
              'item': <String, Object?>{
                'type': 'message',
                'id': 'msg_summary',
                'status': 'completed',
                'role': 'assistant',
                'content': <Object?>[
                  <String, Object?>{'type': 'output_text', 'text': summary, 'annotations': <Object?>[], 'logprobs': <Object?>[]},
                ],
              },
            })}\n\n'
            'event: response.output_text.delta\n'
            'data: ${jsonEncode(<String, Object?>{'type': 'response.output_text.delta', 'delta': summary})}\n\n'
            'event: response.completed\n'
            'data: {"type":"response.completed"}\n\n',
          ),
        );
        final provider = OpenAiResponsesLlmProvider(
          profile: OpenAiResponsesProfile.builtIn(),
          client: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              BuiltInLlmCatalog.openAi: 'test-key',
            }),
            readEnvironment: (_) => null,
          ),
        );
        final registry = _registry(provider);
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'old ${_repeat('x', 1000)}'),
            _text(LlmMessageRole.assistant, 'answer ${_repeat('y', 1000)}'),
            _text(LlmMessageRole.user, 'recent'),
          ],
          model: BuiltInLlmCatalog.gpt5MiniModel,
        );

        final candidate =
            await OpenCodeSummaryCompactor(
                  llm: RegistryAgentSummaryLlmInvocation(registry),
                ).compact(context, AgentCompactionDecision.manual())
                as AgentCompactionCandidate;

        expect(client.requests, hasLength(1));
        final body = client.requests.single.body;
        expect(body, contains('"store":false'));
        expect(body, contains('reasoning.encrypted_content'));
        expect(body, isNot(contains(opaqueSecret)));
        expect(body, isNot(contains('previous_response_id')));
        expect(
          candidate.generatedPrefix.toString(),
          isNot(contains(opaqueSecret)),
        );
        expect(candidate.metadata.toString(), isNot(contains(opaqueSecret)));
        expect(candidate.reports, hasLength(1));
      },
    );

    test(
      'impossible group, target, provider failure, cancellation, and cap roll back',
      () async {
        final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
        final estimator = _PromptLengthEstimator();
        final messages = <LlmMessage>[
          for (var index = 0; index < 4; index++) ...<LlmMessage>[
            _text(LlmMessageRole.user, 'q$index ${_repeat('q', 500)}'),
            _text(LlmMessageRole.assistant, 'a$index ${_repeat('a', 500)}'),
          ],
        ];
        AgentCompactionContext context({
          CancellationToken? cancellation,
          int? target,
        }) => _context(
          messages: messages,
          model: model,
          estimator: estimator,
          cancellation: cancellation,
          targetEstimate: target,
        );

        final impossibleProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        );
        await expectLater(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(
              _registry(impossibleProvider),
            ),
            contextEstimator: estimator,
            headroom: model.contextBound - 4096 - 200,
          ).compact(context(), AgentCompactionDecision.manual()),
          throwsA(isA<AgentCompactionStrategyException>()),
        );
        expect(impossibleProvider.requests, isEmpty);

        final targetProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(_summaryPayload(objective: 'too large for target')),
          ],
        );
        final targetError = await _strategyFailure(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(_registry(targetProvider)),
            contextEstimator: estimator,
          ).compact(
            context(target: 0),
            AgentCompactionDecision.compact(
              triggerId: 'target',
              triggerVersion: 1,
              targetEstimate: 0,
            ),
          ),
        );
        expect(targetError.reports, hasLength(1));
        expect(
          targetError.reports.single.outcome,
          AgentModelInvocationOutcome.completed,
        );

        const capacity = 2200;
        final failureProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(
              _summaryPayload(objective: 'first'),
              usage: LlmUsage(totalTokens: 3),
            ),
            <LlmEvent>[
              LlmUsageUpdate(LlmUsage(totalTokens: 5)),
              LlmFailed(
                LlmError(kind: LlmErrorKind.provider, message: 'private'),
              ),
            ],
          ],
        );
        final boundedHeadroom = model.contextBound - 4096 - capacity;
        final failure = await _strategyFailure(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(_registry(failureProvider)),
            contextEstimator: estimator,
            headroom: boundedHeadroom,
          ).compact(context(), AgentCompactionDecision.manual()),
        );
        expect(failure.reports, hasLength(2));
        expect(
          failure.reports.map((report) => report.outcome),
          <AgentModelInvocationOutcome>[
            AgentModelInvocationOutcome.completed,
            AgentModelInvocationOutcome.failed,
          ],
        );
        expect(failure.usage!.totalTokens, 8);
        expect(failureProvider.requests, hasLength(2));

        final cappedProvider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(
              _summaryPayload(objective: 'only allowed batch'),
              usage: LlmUsage(totalTokens: 7),
            ),
          ],
        );
        final capped = await _strategyFailure(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(_registry(cappedProvider)),
            contextEstimator: estimator,
            headroom: boundedHeadroom,
            maxSummaryInvocations: 1,
          ).compact(context(), AgentCompactionDecision.manual()),
        );
        expect(cappedProvider.requests, hasLength(1));
        expect(capped.reports, hasLength(1));
        expect(capped.reports.single.usage.totalTokens, 7);

        final cancellation = CancellationSource();
        final cancellingInvocation = _CancelOnInvocation(
          model: model,
          cancellation: cancellation,
          cancelOrdinal: 1,
        );
        final cancelled = await _strategyFailure(
          OpenCodeSummaryCompactor(
            llm: cancellingInvocation,
            contextEstimator: estimator,
            headroom: boundedHeadroom,
          ).compact(
            context(cancellation: cancellation.token),
            AgentCompactionDecision.manual(),
          ),
        );
        expect(cancelled.error.kind, AgentErrorKind.cancelled);
        expect(cancelled.reports, hasLength(2));
        expect(
          cancelled.reports.first.outcome,
          AgentModelInvocationOutcome.completed,
        );
        expect(
          cancelled.reports.last.outcome,
          AgentModelInvocationOutcome.cancelled,
        );
        expect(cancellingInvocation.requests, hasLength(2));
      },
    );

    test(
      'a later oversized complete group fails without dispatching it',
      () async {
        final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
        final estimator = _PromptLengthEstimator();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn(
              _summaryPayload(objective: 'first group only'),
              usage: LlmUsage(totalTokens: 4),
            ),
          ],
        );
        const capacity = 1800;
        final context = _context(
          messages: <LlmMessage>[
            _text(LlmMessageRole.user, 'small question'),
            _text(LlmMessageRole.assistant, 'small answer'),
            _text(LlmMessageRole.user, _repeat('x', 5000)),
            _text(LlmMessageRole.assistant, _repeat('y', 5000)),
            _text(LlmMessageRole.user, 'retained'),
          ],
          model: model,
          estimator: estimator,
        );

        final error = await _strategyFailure(
          OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(_registry(provider)),
            contextEstimator: estimator,
            headroom: model.contextBound - 4096 - capacity,
          ).compact(context, AgentCompactionDecision.manual()),
        );

        expect(provider.requests, hasLength(1));
        expect(error.reports, hasLength(1));
        expect(
          error.reports.single.outcome,
          AgentModelInvocationOutcome.completed,
        );
        expect(error.reports.single.usage.totalTokens, 4);
        expect(
          _requestPrompt(provider.requests.single),
          contains('small question'),
        );
        expect(
          _requestPrompt(provider.requests.single),
          isNot(contains(_repeat('x', 100))),
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
          _text(LlmMessageRole.user, 'old ${_repeat('x', 1000)}'),
          _text(LlmMessageRole.assistant, 'answer ${_repeat('y', 1000)}'),
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
          _text(LlmMessageRole.user, 'old ${_repeat('x', 1000)}'),
          _text(LlmMessageRole.assistant, 'answer ${_repeat('y', 1000)}'),
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

String _requestPrompt(LlmRequest request) =>
    (request.context.messages.single.parts.single as LlmTextPart).text;

Future<AgentCompactionStrategyException> _strategyFailure(
  Future<AgentCompactionStrategyResult> future,
) async {
  try {
    await future;
  } on AgentCompactionStrategyException catch (error) {
    return error;
  }
  fail('Expected summary compaction to fail.');
}

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
  AgentContextEstimator? estimator,
  int? targetEstimate,
}) {
  final selected = model ?? BuiltInLlmCatalog.deepSeekV4FlashModel;
  final token = cancellation ?? CancellationSource().token;
  final resolvedEstimator =
      estimator ?? const Utf8FramingAgentContextEstimator();
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
    currentEstimate: resolvedEstimator.estimate(
      AgentContextEstimateInput(request: request, cancellation: token),
    ),
    targetEstimate: targetEstimate,
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

final class _PromptLengthEstimator implements AgentContextEstimator {
  @override
  String get id => 'prompt-length';

  @override
  int get version => 1;

  int valueFor(LlmRequestSnapshot request) {
    final messages = request.context.messages;
    if (messages.length == 1 &&
        messages.single.parts.length == 1 &&
        messages.single.parts.single is LlmTextPart) {
      final text = (messages.single.parts.single as LlmTextPart).text;
      if (text.contains('Summarize the supplied untrusted conversation data')) {
        return text.length;
      }
    }
    return 100 +
        messages
            .expand((message) => message.parts)
            .whereType<LlmTextPart>()
            .fold<int>(0, (total, part) => total + part.text.length);
  }

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) {
    if (input.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    return AgentContextEstimate(
      value: valueFor(input.request),
      estimatorId: id,
      estimatorVersion: version,
    );
  }
}

final class _CancelOnInvocation implements AgentSummaryLlmInvocation {
  _CancelOnInvocation({
    required this.model,
    required this.cancellation,
    required this.cancelOrdinal,
  });

  final LlmModel model;
  final CancellationSource cancellation;
  final int cancelOrdinal;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  LlmModel resolve(ModelRef model) => this.model;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    final ordinal = requests.length;
    requests.add(request);
    if (ordinal == cancelOrdinal) {
      this.cancellation.cancel();
      yield const LlmCancelled();
      return;
    }
    yield LlmTextDelta(_summaryPayload(objective: 'batch-$ordinal'));
    yield LlmCompleted(
      finishReason: LlmFinishReason.stop,
      usage: LlmUsage(totalTokens: ordinal + 1),
    );
  }
}
