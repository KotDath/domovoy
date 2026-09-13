import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/llm/openai_compatible/openai_compatible.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../support/recording_http_client.dart';

void main() {
  group('OpenAI-compatible Chat Completions adapter', () {
    test('reassembles arbitrarily fragmented DeepSeek SSE chunks', () async {
      final client = RecordingClient(
        (_) => fragmentedSseResponse(
          'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final events = await _deepSeek(
        client,
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((events.first as LlmTextDelta).text, 'ok');
      expect(events.last, isA<LlmCompleted>());
    });

    test('preserves DeepSeek one-shot thinking request for v4-flash', () async {
      late RecordedRequest recorded;
      final client = RecordingClient((request) {
        recorded = request;
        return sseResponse(
          'data: {"choices":[{"delta":{"reasoning_content":"think "}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        );
      });
      final events = await _deepSeek(client)
          .stream(
            _prompt(BuiltInLlmCatalog.deepSeekV4FlashModel),
            cancellation: CancellationSource().token,
          )
          .toList();

      expect(
        recorded.url,
        Uri.parse('https://api.deepseek.com/chat/completions'),
      );
      expect(recorded.header('authorization'), 'Bearer super-secret');
      expect(recorded.header('accept'), 'text/event-stream');
      final body = recorded.jsonBody;
      expect(body['model'], 'deepseek-v4-flash');
      expect((body['messages'] as List).single['content'], 'hello');
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
      expect(body['thinking'], {'type': 'enabled'});
      expect(body['reasoning_effort'], 'high');
      expect(body.containsKey('temperature'), isFalse);
      expect((events[0] as LlmReasoningDelta).text, 'think ');
      expect((events[1] as LlmTextDelta).text, 'answer');
      expect((events.last as LlmCompleted).finishReason, LlmFinishReason.stop);
    });

    test('translates both curated DeepSeek models', () async {
      for (final model in <LlmModel>[
        BuiltInLlmCatalog.deepSeekV4FlashModel,
        BuiltInLlmCatalog.deepSeekV4ProModel,
      ]) {
        final client = RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
          ),
        );
        await _deepSeek(client)
            .stream(_prompt(model), cancellation: CancellationSource().token)
            .drain<void>();
        expect(client.requests.single.jsonBody['model'], model.id.value);
      }
    });

    test('normalizes inclusive DeepSeek usage without double counting', () async {
      final events = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"input_tokens":10,"completion_tokens":8,"output_tokens":8,"total_tokens":18,"prompt_cache_hit_tokens":4,"prompt_cache_miss_tokens":6,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":2}}}\n\n'
            'data: [DONE]\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      final usage = events.whereType<LlmUsageUpdate>().single.usage;

      expect(usage.input?.value, 6);
      expect(usage.cacheRead?.value, 4);
      expect(usage.cacheWrite, isNull);
      expect(usage.output?.value, 6);
      expect(usage.reasoning?.value, 2);
      expect(usage.reportedInputTotalTokens, 10);
      expect(usage.reportedOutputTotalTokens, 8);
      expect(usage.reportedOverallTokens, 18);
      expect(
        usage.input?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
      expect(
        usage.cacheRead?.provenance,
        LlmUsageMetricProvenance.providerReported,
      );
      expect(
        usage.output?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
      expect(
        usage.reasoning?.provenance,
        LlmUsageMetricProvenance.providerReported,
      );
      expect(
        usage.parentSemantics.inputCacheRead,
        LlmUsageChildInclusion.included,
      );
      expect(
        usage.parentSemantics.outputReasoning,
        LlmUsageChildInclusion.included,
      );
      expect(usage.totalTokens, 18);
      expect((events.last as LlmCompleted).usage, usage);
    });

    test('emits repeated wire usage as cumulative snapshots', () async {
      final events = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[],"usage":{"prompt_tokens":5,"prompt_cache_hit_tokens":2,"prompt_cache_miss_tokens":3}}\n\n'
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13,"prompt_cache_hit_tokens":4,"prompt_cache_miss_tokens":6}}\n\n'
            'data: [DONE]\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      final updates = events.whereType<LlmUsageUpdate>().toList();
      final accumulator = LlmUsageSnapshotAccumulator();
      for (final update in updates) {
        accumulator.reconcile(update.usage);
      }
      final finalized = accumulator.finalize(
        (events.last as LlmCompleted).usage,
      );

      expect(updates, hasLength(2));
      expect(updates.first.usage.inputTokens, 5);
      expect(updates.last.usage.inputTokens, 10);
      expect(finalized.inputTokens, 10);
      expect(finalized.outputTokens, 3);
      expect(finalized.totalTokens, 13);
    });

    test('uses only explicitly configured cache-write paths', () async {
      final providerId = ProviderId('cache-writer');
      final model = LlmModel(
        providerId: providerId,
        id: ModelId('cache-model'),
        name: 'Cache model',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: 100,
        outputBound: 20,
      );
      final dialect = ChatCompletionsDialect(
        reasoningDeltaField: 'reasoning_content',
        reasoningProtocol: ChatCompletionsReasoningProtocol.none,
        usage: ChatCompletionsUsageDialect(
          cacheWritePaths: <LlmUsageFieldPath>[
            LlmUsageFieldPath.topLevel('cache_creation_tokens'),
          ],
          inputIncludesCacheWrite: true,
          outputIncludesReasoning: false,
        ),
      );
      final provider = OpenAiChatCompletionsLlmProvider(
        profile: OpenAiCompatibleProfile.custom(
          id: providerId,
          endpoint: Uri.parse('https://cache.example.test/chat/completions'),
          environmentVariable: 'CACHE_KEY',
          models: <LlmModel>[model],
          dialect: dialect,
        ),
        client: RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":3},"cache_creation_tokens":2}}\n\n'
            'data: [DONE]\n\n',
          ),
        ),
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            providerId: 'secret',
          }),
          readEnvironment: (_) => null,
        ),
      );
      final events = await provider
          .stream(
            LlmRequest(
              model: model.ref,
              generation: LlmGenerationConfig(
                reasoningMode: ReasoningMode.disabled,
              ),
              context: LlmContext(
                messages: <LlmMessage>[
                  LlmMessage(
                    role: LlmMessageRole.user,
                    parts: <LlmContentPart>[LlmTextPart('hello')],
                  ),
                ],
              ),
            ),
            cancellation: CancellationSource().token,
          )
          .toList();
      final usage = events.whereType<LlmUsageUpdate>().single.usage;

      expect(usage.input?.value, 5);
      expect(usage.cacheRead?.value, 3);
      expect(usage.cacheWrite?.value, 2);
      expect(
        usage.parentSemantics.inputCacheWrite,
        LlmUsageChildInclusion.included,
      );
      expect(usage.output?.value, 2);
      expect(usage.totalTokens, 12);
    });

    test('uses Moonshot endpoint and per-model reasoning fields', () async {
      Future<Map<String, dynamic>> bodyFor(LlmModel model) async {
        final client = RecordingClient((_) => sseResponse('data: [DONE]\n\n'));
        await _moonshot(client)
            .stream(_prompt(model), cancellation: CancellationSource().token)
            .drain<void>();
        expect(
          client.requests.single.url,
          Uri.parse('https://api.moonshot.ai/v1/chat/completions'),
        );
        return client.requests.single.jsonBody;
      }

      final k26 = await bodyFor(BuiltInLlmCatalog.kimiK26Model);
      expect(k26['model'], 'kimi-k2.6');
      expect(k26['thinking'], {'type': 'enabled'});
      expect(k26.containsKey('reasoning_effort'), isFalse);

      final k27 = await bodyFor(BuiltInLlmCatalog.kimiK27CodeModel);
      expect(k27['model'], 'kimi-k2.7-code');
      expect(k27['thinking'], {'type': 'enabled', 'keep': 'all'});

      final k3 = await bodyFor(BuiltInLlmCatalog.kimiK3Model);
      expect(k3['model'], 'kimi-k3');
      expect(k3['reasoning_effort'], 'high');
      expect(k3.containsKey('thinking'), isFalse);
    });

    test(
      'registers a custom compatible HTTPS endpoint with explicit models',
      () async {
        final customModel = LlmModel(
          providerId: ProviderId('local-compat'),
          id: ModelId('custom-mini'),
          name: 'Custom Mini',
          wireFamily: LlmWireFamily.openaiChatCompletions,
          capabilities: ModelCapabilities(
            supportsTextInput: true,
            reasoning: ModelReasoningCapability.optional,
            supportsTools: true,
          ),
          contextBound: 8000,
          outputBound: 1024,
        );
        final profile = OpenAiCompatibleProfile.custom(
          id: ProviderId('local-compat'),
          endpoint: Uri.parse('https://llm.example.test/v1/chat/completions'),
          environmentVariable: 'CUSTOM_API_KEY',
          models: <LlmModel>[customModel],
        );
        final client = RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"content":"hi","tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{\\"a\\""}}]}}]}\n\n'
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}],'
            '"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}\n\n'
            'data: [DONE]\n\n',
          ),
        );
        final provider = OpenAiChatCompletionsLlmProvider(
          profile: profile,
          client: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              ProviderId('local-compat'): 'custom-secret',
            }),
            readEnvironment: (_) => null,
          ),
        );
        final events = await provider
            .stream(
              LlmRequest(
                model: customModel.ref,
                generation: LlmGenerationConfig(
                  reasoningMode: ReasoningMode.disabled,
                ),
                context: LlmContext(
                  messages: <LlmMessage>[
                    LlmMessage(
                      role: LlmMessageRole.user,
                      parts: <LlmContentPart>[LlmTextPart('hi')],
                    ),
                  ],
                ),
              ),
              cancellation: CancellationSource().token,
            )
            .toList();
        expect(
          client.requests.single.url,
          Uri.parse('https://llm.example.test/v1/chat/completions'),
        );
        expect(events.whereType<LlmTextDelta>(), hasLength(1));
        expect(events.whereType<LlmToolCallDelta>(), hasLength(2));
        expect(events.whereType<LlmUsageUpdate>(), isNotEmpty);
        expect(
          (events.last as LlmCompleted).finishReason,
          LlmFinishReason.toolCalls,
        );
      },
    );

    test(
      'keeps a stable tool-call id across fragments and interleaved calls',
      () async {
        final client = RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"one","arguments":"{"}}]}}]}\n\n'
            'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"two","arguments":"{"}}]}}]}\n\n'
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}}]}\n\n'
            'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}\n\n'
            'data: [DONE]\n\n',
          ),
        );
        final events = await _deepSeek(
          client,
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        final calls = events.whereType<LlmToolCallDelta>().toList();
        expect(calls, hasLength(4));
        expect(calls[0].callId.value, 'call_a');
        expect(calls[1].callId.value, 'call_b');
        expect(calls[2].callId.value, 'call_a');
        expect(calls[3].callId.value, 'call_b');
        expect(
          (events.last as LlmCompleted).finishReason,
          LlmFinishReason.toolCalls,
        );
      },
    );

    test('rejects a conflicting tool-call id change for the same index', () async {
      final events = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"one"}}]}}]}\n\n'
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_b","function":{"arguments":"{}"}}]}}]}\n\n'
            'data: [DONE]\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

    test('copies profile models and rejects undeclared ids', () {
      final providerId = ProviderId('local-compat');
      final declared = LlmModel(
        providerId: providerId,
        id: ModelId('custom-mini'),
        name: 'Custom Mini',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: 16,
        outputBound: 8,
      );
      final extra = LlmModel(
        providerId: providerId,
        id: ModelId('extra'),
        name: 'Extra',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: declared.capabilities,
        contextBound: 16,
        outputBound: 8,
      );
      final models = <LlmModel>[declared];
      final profile = OpenAiCompatibleProfile.custom(
        id: providerId,
        endpoint: Uri.parse('https://llm.example.test/v1/chat/completions'),
        environmentVariable: 'CUSTOM_API_KEY',
        models: models,
      );
      models.add(extra);
      expect(profile.models, hasLength(1));
      expect(() => profile.models.add(extra), throwsUnsupportedError);
      expect(
        () => profile.requireModel(extra.id),
        throwsA(isA<LlmException>()),
      );
    });

    test('rejects insecure custom endpoints and implicit models', () {
      expect(
        () => OpenAiCompatibleProfile.custom(
          id: ProviderId('bad'),
          endpoint: Uri.parse('http://evil.example/v1/chat/completions'),
          environmentVariable: 'CUSTOM_API_KEY',
          models: <LlmModel>[
            LlmModel(
              providerId: ProviderId('bad'),
              id: ModelId('x'),
              name: 'x',
              wireFamily: LlmWireFamily.openaiChatCompletions,
              capabilities: ModelCapabilities(
                supportsTextInput: true,
                reasoning: ModelReasoningCapability.unsupported,
                supportsTools: false,
              ),
              contextBound: 8,
              outputBound: 8,
            ),
          ],
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => OpenAiCompatibleProfile.custom(
          id: ProviderId('empty'),
          endpoint: Uri.parse('https://llm.example.test/v1/chat/completions'),
          environmentVariable: 'CUSTOM_API_KEY',
          models: const <LlmModel>[],
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('allows loopback HTTP only with an explicit test policy', () {
      final model = LlmModel(
        providerId: ProviderId('local'),
        id: ModelId('toy'),
        name: 'toy',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: 16,
        outputBound: 8,
      );
      expect(
        () => OpenAiCompatibleProfile.custom(
          id: ProviderId('local'),
          endpoint: Uri.parse('http://127.0.0.1:9/v1/chat/completions'),
          environmentVariable: 'CUSTOM_API_KEY',
          models: <LlmModel>[model],
          securityPolicy: LlmEndpointSecurityPolicy.allowLoopbackHttp,
        ),
        returnsNormally,
      );
      expect(
        () => OpenAiCompatibleProfile.custom(
          id: ProviderId('creds'),
          endpoint: Uri.parse(
            'https://user:secret@llm.example.test/v1/chat/completions',
          ),
          environmentVariable: 'CUSTOM_API_KEY',
          models: <LlmModel>[model],
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => OpenAiCompatibleProfile.custom(
          id: ProviderId('loop-creds'),
          endpoint: Uri.parse(
            'http://user:secret@127.0.0.1:9/v1/chat/completions',
          ),
          environmentVariable: 'CUSTOM_API_KEY',
          models: <LlmModel>[
            LlmModel(
              providerId: ProviderId('loop-creds'),
              id: ModelId('toy'),
              name: 'toy',
              wireFamily: LlmWireFamily.openaiChatCompletions,
              capabilities: ModelCapabilities(
                supportsTextInput: true,
                reasoning: ModelReasoningCapability.unsupported,
                supportsTools: false,
              ),
              contextBound: 16,
              outputBound: 8,
            ),
          ],
          securityPolicy: LlmEndpointSecurityPolicy.allowLoopbackHttp,
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('translates tools, history, temperature, and output cap', () {
      final provider = _deepSeek(RecordingClient((_) => sseResponse('')));
      final body = provider.requestBody(
        LlmRequest(
          model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
          context: LlmContext(
            systemPrompt: 'sys',
            messages: <LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.user,
                parts: <LlmContentPart>[LlmTextPart('q')],
              ),
              LlmMessage(
                role: LlmMessageRole.assistant,
                parts: <LlmContentPart>[
                  LlmReasoningPart('r'),
                  LlmTextPart('a'),
                  LlmToolCallPart(
                    callId: ToolCallId('call_1'),
                    name: 'lookup',
                    arguments: '{"q":1}',
                  ),
                ],
              ),
              LlmMessage(
                role: LlmMessageRole.tool,
                parts: <LlmContentPart>[
                  LlmToolResultPart(
                    callId: ToolCallId('call_1'),
                    content: 'ok',
                  ),
                ],
              ),
            ],
            tools: <LlmToolDescriptor>[LlmToolDescriptor(name: 'lookup')],
          ),
          generation: LlmGenerationConfig(
            temperature: 0.5,
            maxOutputTokens: 32,
          ),
        ),
      );
      expect(body['temperature'], 0.5);
      expect(body['max_tokens'], 32);
      expect(body['tools'], isNotEmpty);
      final messages = body['messages'] as List<dynamic>;
      expect(messages.first['role'], 'system');
      expect(messages[2]['tool_calls'], isNotEmpty);
      expect(messages[2]['reasoning_content'], 'r');
      expect(messages.last['role'], 'tool');
    });

    test('maps DeepSeek and Kimi reasoning efforts locally', () {
      final deepSeek = _deepSeek(RecordingClient((_) => sseResponse('')));
      String effort(ReasoningEffort value) {
        return deepSeek.requestBody(
              LlmRequest(
                model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
                generation: LlmGenerationConfig(reasoningEffort: value),
                context: LlmContext(
                  messages: <LlmMessage>[
                    LlmMessage(
                      role: LlmMessageRole.user,
                      parts: <LlmContentPart>[LlmTextPart('hi')],
                    ),
                  ],
                ),
              ),
            )['reasoning_effort']
            as String;
      }

      expect(effort(ReasoningEffort.low), 'low');
      expect(effort(ReasoningEffort.medium), 'high');
      expect(effort(ReasoningEffort.high), 'high');
      expect(effort(ReasoningEffort.max), 'max');
      expect(effort(ReasoningEffort.modelDefault), 'high');
      final moonshot = _moonshot(RecordingClient((_) => sseResponse('')));
      Map<String, Object?> kimi(
        LlmModel model, [
        LlmGenerationConfig? generation,
      ]) {
        return moonshot.requestBody(
          LlmRequest(
            model: model.ref,
            generation: generation ?? LlmGenerationConfig(),
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
          ),
        );
      }

      expect(kimi(BuiltInLlmCatalog.kimiK3Model)['reasoning_effort'], 'high');
      expect(
        kimi(
          BuiltInLlmCatalog.kimiK3Model,
          LlmGenerationConfig(reasoningEffort: ReasoningEffort.low),
        )['reasoning_effort'],
        'low',
      );
      expect(
        kimi(
          BuiltInLlmCatalog.kimiK3Model,
          LlmGenerationConfig(reasoningEffort: ReasoningEffort.max),
        )['reasoning_effort'],
        'max',
      );
      expect(
        () => kimi(
          BuiltInLlmCatalog.kimiK3Model,
          LlmGenerationConfig(reasoningEffort: ReasoningEffort.medium),
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => kimi(
          BuiltInLlmCatalog.kimiK27CodeModel,
          LlmGenerationConfig(reasoningEffort: ReasoningEffort.high),
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => _moonshot(RecordingClient((_) => sseResponse(''))).requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.kimiK26Model.ref,
            generation: LlmGenerationConfig(
              reasoningEffort: ReasoningEffort.high,
            ),
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
          ),
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('rejects unsupported Moonshot temperature before dispatch', () {
      final client = RecordingClient((_) => sseResponse('data: [DONE]\n\n'));
      expect(
        () => _moonshot(client).stream(
          LlmRequest(
            model: BuiltInLlmCatalog.kimiK26Model.ref,
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
            generation: LlmGenerationConfig(temperature: 0.2),
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<LlmException>()),
      );
      expect(client.requests, isEmpty);
    });

    test(
      'normalizes malformed, missing-terminal, HTTP, network, and missing-key failures',
      () async {
        final malformed = await _deepSeek(
          RecordingClient((_) => sseResponse('data: not-json\n\n')),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(
          (malformed.single as LlmFailed).error.kind,
          LlmErrorKind.protocol,
        );

        final interrupted = await _deepSeek(
          RecordingClient(
            (_) => sseResponse(
              'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((interrupted.first as LlmTextDelta).text, 'partial');
        expect(
          (interrupted.last as LlmFailed).error.kind,
          LlmErrorKind.interrupted,
        );

        const secret = 'top-secret-key';
        final httpError = await _deepSeek(
          RecordingClient((_) => sseResponse(secret, status: 401)),
          key: secret,
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(
          (httpError.single as LlmFailed).error.kind,
          LlmErrorKind.authentication,
        );
        expect(
          (httpError.single as LlmFailed).error.message,
          isNot(contains(secret)),
        );

        final network = await _deepSeek(
          RecordingClient((_) => throw http.ClientException('secret details')),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((network.single as LlmFailed).error.kind, LlmErrorKind.network);
        expect(
          (network.single as LlmFailed).error.message,
          isNot(contains('secret details')),
        );

        final missing = await _deepSeek(
          RecordingClient((_) => sseResponse('data: [DONE]\n\n')),
          key: null,
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(missing.single, isA<LlmFailed>());
        expect(
          (missing.single as LlmFailed).error.kind,
          LlmErrorKind.configuration,
        );
        expect(
          (missing.single as LlmFailed).error.message,
          contains('deepseek'),
        );
      },
    );

    test('maps only confirmed context overflow codes', () async {
      final httpOverflow = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            '{"error":{"type":"invalid_request_error","code":"invalid_request_error","message":"This model\'s maximum context length is 1048576 tokens. However, you requested 1100005 tokens. super-secret"}}',
            status: 400,
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (httpOverflow.single as LlmFailed).error.kind,
        LlmErrorKind.contextOverflow,
      );
      expect(
        (httpOverflow.single as LlmFailed).error.message,
        contains('maximum context length is 1048576 tokens'),
      );
      expect(
        (httpOverflow.single as LlmFailed).error.message,
        isNot(contains('super-secret')),
      );

      final streamOverflow = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            'data: {"error":{"code":"context_length_exceeded","message":"raw"}}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (streamOverflow.single as LlmFailed).error.kind,
        LlmErrorKind.contextOverflow,
      );

      final generic400 = await _deepSeek(
        RecordingClient(
          (_) => sseResponse(
            '{"error":{"type":"invalid_request_error","message":"too long maybe"}}',
            status: 400,
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (generic400.single as LlmFailed).error.kind,
        LlmErrorKind.provider,
      );

      final protocol = await _deepSeek(
        RecordingClient((_) => sseResponse('data: not-json\n\n')),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((protocol.single as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

    test(
      'negative optional usage preserves valid completion and facts',
      () async {
        final events = await _deepSeek(
          RecordingClient(
            (_) => sseResponse(
              'data: {"choices":[{"delta":{"content":"x"}}],"usage":{"prompt_tokens":-1}}\n\n'
              'data: [DONE]\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        final usage = events.whereType<LlmUsageUpdate>().single.usage;
        expect(events.last, isA<LlmCompleted>());
        expect(usage.reportedInputTotal, isNull);
        expect(
          usage.hasAnomaly(
            LlmUsageAnomalyKind.invalidValue,
            metric: LlmUsageMetricKind.reportedInputTotal,
          ),
          isTrue,
        );
      },
    );

    test('malformed usage isolates aliases, details, and arithmetic', () async {
      Future<LlmUsage> streamed(Map<String, Object?> rawUsage) async {
        final payload = jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
          'usage': rawUsage,
        });
        final events = await _deepSeek(
          RecordingClient(
            (_) => sseResponse('data: $payload\n\ndata: [DONE]\n\n'),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(events.last, isA<LlmCompleted>());
        return events.whereType<LlmUsageUpdate>().single.usage;
      }

      final aliasConflict = await streamed(<String, Object?>{
        'prompt_tokens': 10,
        'input_tokens': 11,
        'completion_tokens': 5,
      });
      expect(aliasConflict.reportedInputTotal, isNull);
      expect(aliasConflict.reportedOutputTotalTokens, 5);
      expect(
        aliasConflict.hasAnomaly(
          LlmUsageAnomalyKind.aliasConflict,
          metric: LlmUsageMetricKind.reportedInputTotal,
        ),
        isTrue,
      );

      final invalidDetail = await streamed(<String, Object?>{
        'prompt_tokens': 10,
        'completion_tokens': 5,
        'total_tokens': 15,
        'prompt_tokens_details': <String, Object?>{'cached_tokens': 2.5},
      });
      expect(invalidDetail.cacheRead, isNull);
      expect(invalidDetail.totalTokens, 15);
      expect(
        invalidDetail.hasAnomaly(
          LlmUsageAnomalyKind.invalidValue,
          metric: LlmUsageMetricKind.cacheRead,
        ),
        isTrue,
      );

      final impossible = await streamed(<String, Object?>{
        'prompt_tokens': 7,
        'completion_tokens': 3,
        'completion_tokens_details': <String, Object?>{'reasoning_tokens': 4},
      });
      expect(impossible.reasoning?.value, 4);
      expect(impossible.output, isNull);
      expect(impossible.responseGenerated, isNull);

      final inconsistent = await streamed(<String, Object?>{
        'prompt_tokens': 7,
        'completion_tokens': 5,
        'total_tokens': 10,
      });
      expect(inconsistent.reportedOverallTokens, 10);
      expect(inconsistent.totalTokens, 12);
      expect(
        inconsistent.hasAnomaly(
          LlmUsageAnomalyKind.inconsistentTotal,
          metric: LlmUsageMetricKind.reportedOverall,
        ),
        isTrue,
      );
    });

    test(
      'hanging credential resolution is cancelled without dispatch',
      () async {
        final hanging = _HangingCredentialResolver();
        final client = RecordingClient((_) => sseResponse('data: [DONE]\n\n'));
        final source = CancellationSource();
        final future = OpenAiChatCompletionsLlmProvider(
          profile: OpenAiCompatibleProfile.deepSeek(),
          client: client,
          credentials: hanging,
        ).stream(_prompt(), cancellation: source.token).toList();
        await Future<void>.delayed(Duration.zero);
        source.cancel();
        hanging.complete();
        final events = await future;
        expect(client.requests, isEmpty);
        expect(events.single, isA<LlmCancelled>());
      },
    );

    test(
      'cancellation wins over TimeoutException and FormatException',
      () async {
        final timeoutSource = CancellationSource();
        final timeoutEvents = await _deepSeek(
          RecordingClient((_) {
            timeoutSource.cancel();
            throw TimeoutException('late timeout');
          }),
        ).stream(_prompt(), cancellation: timeoutSource.token).toList();
        expect(timeoutEvents.single, isA<LlmCancelled>());

        final formatSource = CancellationSource();
        final formatEvents = await _deepSeek(
          RecordingClient((_) {
            formatSource.cancel();
            throw const FormatException('late format');
          }),
        ).stream(_prompt(), cancellation: formatSource.token).toList();
        expect(formatEvents.single, isA<LlmCancelled>());
      },
    );

    test('cancellation before dispatch sends no HTTP request', () async {
      final client = RecordingClient((_) => sseResponse('data: [DONE]\n\n'));
      final source = CancellationSource();
      source.cancel();
      final events = await _deepSeek(
        client,
      ).stream(_prompt(), cancellation: source.token).toList();
      expect(client.requests, isEmpty);
      expect(events.single, isA<LlmCancelled>());
    });

    test('cancels an in-flight stream without a live network', () async {
      final chunks = StreamController<List<int>>();
      final client = RecordingClient((request) {
        return http.StreamedResponse(chunks.stream, 200);
      });
      final source = CancellationSource();
      final future = _deepSeek(
        client,
      ).stream(_prompt(), cancellation: source.token).toList();
      chunks.add(
        utf8.encode('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.cancel();
      await chunks.close();
      final events = await future;
      expect(events.whereType<LlmTextDelta>(), isNotEmpty);
      expect(events.last, isA<LlmCancelled>());
    });
  });
}

OpenAiChatCompletionsLlmProvider _deepSeek(
  RecordingClient client, {
  String? key = 'super-secret',
}) {
  return OpenAiChatCompletionsLlmProvider(
    profile: OpenAiCompatibleProfile.deepSeek(),
    client: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(
        key == null
            ? const <ProviderId, String>{}
            : <ProviderId, String>{BuiltInLlmCatalog.deepSeek: key},
      ),
      readEnvironment: (_) => null,
    ),
  );
}

OpenAiChatCompletionsLlmProvider _moonshot(RecordingClient client) {
  return OpenAiChatCompletionsLlmProvider(
    profile: OpenAiCompatibleProfile.moonshotAi(),
    client: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(<ProviderId, String>{
        BuiltInLlmCatalog.moonshotAi: 'moon-secret',
      }),
      readEnvironment: (_) => null,
    ),
  );
}

final class _HangingCredentialResolver implements ProviderCredentialResolver {
  final Completer<LlmResolvedCredential> _completer =
      Completer<LlmResolvedCredential>();

  @override
  Future<LlmResolvedCredential> resolve({
    required ProviderId providerId,
    required String environmentVariable,
  }) {
    return _completer.future;
  }

  void complete() {
    if (!_completer.isCompleted) {
      _completer.complete(
        LlmResolvedCredential(
          value: 'late-secret',
          source: LlmCredentialSource.storedOverride,
        ),
      );
    }
  }
}

LlmRequest _prompt([LlmModel? model]) {
  return LlmRequest(
    model: (model ?? BuiltInLlmCatalog.deepSeekV4FlashModel).ref,
    context: LlmContext(
      messages: <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[LlmTextPart('hello')],
        ),
      ],
    ),
  );
}
