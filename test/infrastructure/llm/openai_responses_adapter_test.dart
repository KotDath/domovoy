import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/llm/openai_responses/openai_responses.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../support/recording_http_client.dart';

void main() {
  group('OpenAI Responses adapter', () {
    test('streams text and reasoning for each curated OpenAI model', () async {
      for (final model in <LlmModel>[
        BuiltInLlmCatalog.gpt4oMiniModel,
        BuiltInLlmCatalog.gpt5MiniModel,
        BuiltInLlmCatalog.gpt54Model,
      ]) {
        late RecordedRequest recorded;
        final unsupported =
            model.capabilities.reasoning ==
            ModelReasoningCapability.unsupported;
        final client = RecordingClient((request) {
          recorded = request;
          return fragmentedSseResponse(
            unsupported
                ? 'event: response.output_text.delta\n'
                      'data: {"type":"response.output_text.delta","delta":"ans"}\n\n'
                      'event: response.completed\n'
                      'data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5,"input_tokens_details":{"cached_tokens":1}}}}\n\n'
                : 'event: response.reasoning_summary_text.delta\n'
                      'data: {"type":"response.reasoning_summary_text.delta","delta":"think"}\n\n'
                      'event: response.output_text.delta\n'
                      'data: {"type":"response.output_text.delta","delta":"ans"}\n\n'
                      'event: response.completed\n'
                      'data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5,"input_tokens_details":{"cached_tokens":1}}}}\n\n',
          );
        });
        final events = await _openAi(client)
            .stream(_prompt(model), cancellation: CancellationSource().token)
            .toList();
        expect(recorded.url, Uri.parse('https://api.openai.com/v1/responses'));
        expect(recorded.jsonBody['model'], model.id.value);
        expect(recorded.jsonBody['stream'], isTrue);
        expect(recorded.jsonBody['store'], isFalse);
        expect(recorded.jsonBody.containsKey('previous_response_id'), isFalse);
        if (model.capabilities.reasoning ==
            ModelReasoningCapability.unsupported) {
          expect(recorded.jsonBody.containsKey('reasoning'), isFalse);
        } else {
          expect(recorded.jsonBody['reasoning'], {'effort': 'high'});
          expect(recorded.jsonBody['include'], ['reasoning.encrypted_content']);
        }
        expect(events.whereType<LlmTextDelta>().single.text, 'ans');
        expect(events.whereType<LlmUsageUpdate>(), isNotEmpty);
        final completed = events.last as LlmCompleted;
        expect(completed.finishReason, LlmFinishReason.stop);
        expect(completed.usage?.inputTokens, 2);
        expect(completed.usage?.cacheHitTokens, 1);
        expect(events.where((event) => event.isTerminal), hasLength(1));
      }
    });

    test('normalizes cached input and reasoning output exactly once', () async {
      final events =
          await _openAi(
                RecordingClient(
                  (_) => sseResponse(
                    'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"prompt_tokens":10,"output_tokens":8,"completion_tokens":8,"total_tokens":18,"input_tokens_details":{"cached_tokens":4},"output_tokens_details":{"reasoning_tokens":2}}}}\n\n',
                  ),
                ),
              )
              .stream(
                _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                cancellation: CancellationSource().token,
              )
              .toList();
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

    test('Responses cache write requires configured detail semantics', () async {
      final profile = OpenAiResponsesProfile(
        snapshot: BuiltInLlmCatalog.openAiProfile,
        models: <LlmModel>[BuiltInLlmCatalog.gpt4oMiniModel],
        usage: OpenAiResponsesUsageDialect(
          cacheWritePaths: <LlmUsageFieldPath>[
            LlmUsageFieldPath.nested(
              'input_tokens_details',
              'cache_creation_tokens',
            ),
          ],
          inputIncludesCacheWrite: true,
          outputIncludesReasoning: false,
        ),
      );
      final provider = OpenAiResponsesLlmProvider(
        profile: profile,
        client: RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12,"input_tokens_details":{"cached_tokens":3,"cache_creation_tokens":2}}}}\n\n',
          ),
        ),
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.openAi: 'secret',
          }),
          readEnvironment: (_) => null,
        ),
      );
      final events = await provider
          .stream(
            _prompt(BuiltInLlmCatalog.gpt4oMiniModel),
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

    test('translates instructions, history, tools, and output bounds', () {
      final provider = _openAi(RecordingClient((_) => sseResponse('')));
      final body = provider.requestBody(
        LlmRequest(
          model: BuiltInLlmCatalog.gpt5MiniModel.ref,
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
            tools: <LlmToolDescriptor>[
              LlmToolDescriptor(
                name: 'lookup',
                description: 'Look up',
                parameters: <String, Object?>{'type': 'object'},
              ),
            ],
          ),
          generation: LlmGenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 64,
          ),
        ),
      );
      expect(body['instructions'], 'sys');
      expect(body['max_output_tokens'], 64);
      expect(body['temperature'], 0.3);
      expect(body['tools'], isNotEmpty);
      expect(body['store'], isFalse);
      expect(body.containsKey('previous_response_id'), isFalse);
      final input = body['input'] as List<dynamic>;
      expect(input[0]['role'], 'user');
      expect(input.map((item) => item['type']), isNot(contains('reasoning')));
      expect(input[1]['role'], 'assistant');
      expect(input[2]['type'], 'function_call');
      expect(input[3]['type'], 'function_call_output');
    });

    test('copies Responses models, rejects duplicates and undeclared ids', () {
      final models = <LlmModel>[
        BuiltInLlmCatalog.gpt4oMiniModel,
        BuiltInLlmCatalog.gpt5MiniModel,
      ];
      final profile = OpenAiResponsesProfile(
        snapshot: BuiltInLlmCatalog.openAiProfile,
        models: models,
      );
      models.add(BuiltInLlmCatalog.gpt54Model);
      expect(profile.models, hasLength(2));
      expect(
        () => profile.models.add(BuiltInLlmCatalog.gpt54Model),
        throwsUnsupportedError,
      );
      expect(
        () => profile.requireModel(BuiltInLlmCatalog.gpt54),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => OpenAiResponsesProfile(
          snapshot: BuiltInLlmCatalog.openAiProfile,
          models: <LlmModel>[
            BuiltInLlmCatalog.gpt4oMiniModel,
            BuiltInLlmCatalog.gpt4oMiniModel,
          ],
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('emits stable incremental function-call fragments', () async {
      final client = RecordingClient(
        (_) => sseResponse(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":""}}\n\n'
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{"}\n\n'
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"1}"}\n\n'
          'data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}\n\n',
        ),
      );
      final events = await _openAi(client)
          .stream(
            _prompt(BuiltInLlmCatalog.gpt4oMiniModel),
            cancellation: CancellationSource().token,
          )
          .toList();
      final calls = events.whereType<LlmToolCallDelta>().toList();
      expect(calls, hasLength(3));
      expect(calls.every((delta) => delta.callId.value == 'call_1'), isTrue);
      expect(calls.first.name, 'lookup');
      expect(calls[1].argumentsFragment, '{');
      expect(calls[2].argumentsFragment, '1}');
    });

    test('correlates interleaved function calls and rejects orphans', () async {
      final interleaved = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_a","type":"function_call","call_id":"call_a","name":"one","arguments":""}}\n\n'
            'data: {"type":"response.output_item.added","output_index":1,"item":{"id":"fc_b","type":"function_call","call_id":"call_b","name":"two","arguments":""}}\n\n'
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_b","output_index":1,"delta":"b"}\n\n'
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_a","output_index":0,"delta":"a"}\n\n'
            'data: {"type":"response.completed"}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      final calls = interleaved.whereType<LlmToolCallDelta>().toList();
      expect(calls.map((delta) => delta.callId.value), <String>[
        'call_a',
        'call_b',
        'call_b',
        'call_a',
      ]);

      final orphan = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.function_call_arguments.delta","item_id":"missing","delta":"{"}\n\n'
            'data: {"type":"response.completed"}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((orphan.last as LlmFailed).error.kind, LlmErrorKind.protocol);

      final conflict = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":""}}\n\n'
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":2,"delta":"{"}\n\n'
            'data: {"type":"response.completed"}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((conflict.last as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

    test(
      'partial usage, refusal, malformed events, and missing terminal stay sanitized',
      () async {
        final partial = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'
              'data: {"type":"response.completed","response":{"usage":{"output_tokens":4}}}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((partial.first as LlmTextDelta).text, 'partial');
        expect((partial.last as LlmCompleted).usage?.outputTokens, 4);
        expect((partial.last as LlmCompleted).usage?.inputTokens, isNull);

        const secret = 'sk-secret-openai';
        final refusal = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.output_text.delta","delta":"hi"}\n\n'
              'data: {"type":"response.refusal.delta","delta":"$secret"}\n\n'
              'data: {"type":"response.completed"}\n\n',
            ),
          ),
          key: secret,
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((refusal.first as LlmTextDelta).text, 'hi');
        expect((refusal[1] as LlmFailed).error.kind, LlmErrorKind.provider);
        expect(
          (refusal[1] as LlmFailed).error.message,
          isNot(contains(secret)),
        );
        expect(refusal.where((event) => event.isTerminal), hasLength(1));

        final malformed = await _openAi(
          RecordingClient((_) => sseResponse('data: {"no":"type"}\n\n')),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(
          (malformed.single as LlmFailed).error.kind,
          LlmErrorKind.protocol,
        );

        final missing = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.output_text.delta","delta":"x"}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((missing.first as LlmTextDelta).text, 'x');
        expect(
          (missing.last as LlmFailed).error.kind,
          LlmErrorKind.interrupted,
        );
      },
    );

    test('maps only confirmed Responses context overflow codes', () async {
      final failed = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.failed","response":{"error":{"code":"context_length_exceeded","message":"Maximum context length exceeded. openai-secret"}}}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (failed.single as LlmFailed).error.kind,
        LlmErrorKind.contextOverflow,
      );
      expect(
        (failed.single as LlmFailed).error.message,
        isNot(contains('openai-secret')),
      );

      final httpOverflow = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            '{"error":{"code":"context_length_exceeded","message":"raw"}}',
            status: 400,
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (httpOverflow.single as LlmFailed).error.kind,
        LlmErrorKind.contextOverflow,
      );

      final generic400 = await _openAi(
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

      final protocol = await _openAi(
        RecordingClient((_) => sseResponse('data: {"no":"type"}\n\n')),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((protocol.single as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

    test('collects output_item.done by index order and rejects extras', () async {
      final events =
          await _openAi(
                RecordingClient(
                  (_) => sseResponse(
                    'event: response.output_item.done\n'
                    'data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"a","annotations":[{"type":"url_citation","url":"https://example.com","title":"Example","start_index":0,"end_index":1}],"logprobs":[{"token":"a","logprob":-0.25,"bytes":[97],"top_logprobs":[{"token":"A","logprob":-1,"bytes":null}]}]},{"type":"output_text","text":"ns","annotations":[],"logprobs":[]}]}}\n\n'
                    'event: response.output_item.done\n'
                    'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","status":"completed","content":[{"type":"reasoning_text","text":"think"}],"encrypted_content":"enc"}}\n\n'
                    'event: response.output_text.delta\n'
                    'data: {"type":"response.output_text.delta","delta":"ans"}\n\n'
                    'event: response.completed\n'
                    'data: {"type":"response.completed"}\n\n',
                  ),
                ),
              )
              .stream(
                _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                cancellation: CancellationSource().token,
              )
              .toList();
      final completed = events.last as LlmCompleted;
      final payload = completed.turnState!.payload as List<dynamic>;
      expect(payload[0]['type'], 'reasoning');
      expect(payload[1]['type'], 'message');
      final content = payload[1]['content'] as List<dynamic>;
      expect(content.first['logprobs'], hasLength(1));
      expect(content.first['logprobs'].single['bytes'], <int>[97]);
      expect(content.last['logprobs'], isEmpty);
      expect(events.whereType<LlmTextDelta>().single.text, 'ans');
      expect(completed.toString(), isNot(contains('enc')));
      expect(completed.toString(), isNot(contains('logprobs')));
      expect(
        completed.turnState!.diagnosticSummary().toString(),
        isNot(contains('logprobs')),
      );
      expect(
        LlmProviderTurnState.fromJson(completed.turnState!.toJson()),
        completed.turnState,
      );

      final replay = _openAi(RecordingClient((_) => sseResponse('')))
          .requestBody(
            LlmRequest(
              model: BuiltInLlmCatalog.gpt5MiniModel.ref,
              generation: LlmGenerationConfig(
                reasoningMode: ReasoningMode.enabled,
              ),
              context: LlmContext(
                messages: <LlmMessage>[
                  LlmMessage(
                    role: LlmMessageRole.assistant,
                    parts: <LlmContentPart>[LlmTextPart('ans')],
                  ),
                ],
                continuationEntries: <LlmContinuationEntry>[
                  LlmContinuationEntry(
                    assistantMessageIndex: 0,
                    state: completed.turnState!,
                  ),
                ],
              ),
            ),
          );
      final replayedMessage = (replay['input'] as List<dynamic>)[1];
      expect(replayedMessage['content'][0]['logprobs'], hasLength(1));
      expect(replayedMessage['content'][1]['logprobs'], isEmpty);
    });

    test('malformed output_item.done logprobs fail as protocol', () async {
      final events =
          await _openAi(
                RecordingClient(
                  (_) => sseResponse(
                    'event: response.output_item.done\n'
                    'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_bad","role":"assistant","content":[{"type":"output_text","text":"ans","logprobs":[{"token":"ans","logprob":-0.1,"bytes":[999],"top_logprobs":[]}]}]}}\n\n'
                    'event: response.completed\n'
                    'data: {"type":"response.completed"}\n\n',
                  ),
                ),
              )
              .stream(
                _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                cancellation: CancellationSource().token,
              )
              .toList();

      expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
      expect(events.whereType<LlmCompleted>(), isEmpty);
    });

    test('cancel waits for delayed HTTP stream teardown', () async {
      final released = Completer<void>();
      final client = RecordingClient((_) {
        final controller = StreamController<List<int>>(
          onCancel: () async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            if (!released.isCompleted) {
              released.complete();
            }
          },
        );
        return http.StreamedResponse(
          controller.stream,
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
        );
      });
      final cancel = CancellationSource();
      final future = _openAi(
        client,
      ).stream(_prompt(), cancellation: cancel.token).toList();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      final events = await future;
      expect(released.isCompleted, isTrue);
      expect(events.last, isA<LlmCancelled>());
    });

    test(
      'unsupported models reject reasoning output_item.done without deltas',
      () async {
        final events = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'event: response.output_item.done\n'
              'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc"}}\n\n'
              'event: response.completed\n'
              'data: {"type":"response.completed"}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
        expect(events.whereType<LlmReasoningDelta>(), isEmpty);
      },
    );

    test('mismatched function_call output_item.done fails as protocol', () async {
      final events =
          await _openAi(
                RecordingClient(
                  (_) => sseResponse(
                    'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":"{}"}}\n\n'
                    'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"other","arguments":"{}"}}\n\n'
                    'data: {"type":"response.completed"}\n\n',
                  ),
                ),
              )
              .stream(
                _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                cancellation: CancellationSource().token,
              )
              .toList();
      expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

    test('unsupported models reject reasoning stream events', () async {
      final events = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'event: response.reasoning_summary_text.delta\n'
            'data: {"type":"response.reasoning_summary_text.delta","delta":"think"}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
      expect(events.whereType<LlmReasoningDelta>(), isEmpty);
    });

    test(
      'enabled function-call turns without encrypted state fail locally',
      () async {
        final events =
            await _openAi(
                  RecordingClient(
                    (_) => sseResponse(
                      'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":"{}"}}\n\n'
                      'data: {"type":"response.completed","response":{"output":[{"type":"function_call","call_id":"call_1"}]}}\n\n',
                    ),
                  ),
                )
                .stream(
                  _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                  cancellation: CancellationSource().token,
                )
                .toList();
        expect((events.last as LlmFailed).error.kind, LlmErrorKind.protocol);
      },
    );

    test('completed function calls use toolCalls finish reason', () async {
      final events = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":""}}\n\n'
            'data: {"type":"response.completed","response":{"output":[{"type":"function_call","call_id":"call_1"}]}}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(
        (events.last as LlmCompleted).finishReason,
        LlmFinishReason.toolCalls,
      );
    });

    test('incomplete reasons map to length, contentFilter, or unknown', () async {
      Future<LlmFinishReason?> reasonFor(String reason) async {
        final events = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"$reason"}}}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        return (events.last as LlmCompleted).finishReason;
      }

      expect(await reasonFor('max_output_tokens'), LlmFinishReason.length);
      expect(await reasonFor('content_filter'), LlmFinishReason.contentFilter);
      expect(await reasonFor('server_busy'), LlmFinishReason.unknown);
    });

    test(
      'malformed optional usage preserves completion but bad deltas fail',
      () async {
        final negative = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.completed","response":{"usage":{"output_tokens":-3}}}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(negative.last, isA<LlmCompleted>());
        final negativeUsage = negative.whereType<LlmUsageUpdate>().single.usage;
        expect(negativeUsage.output, isNull);
        expect(
          negativeUsage.hasAnomaly(
            LlmUsageAnomalyKind.invalidValue,
            metric: LlmUsageMetricKind.reportedOutputTotal,
          ),
          isTrue,
        );

        final badDelta = await _openAi(
          RecordingClient(
            (_) => sseResponse(
              'data: {"type":"response.output_text.delta","delta":12}\n\n',
            ),
          ),
        ).stream(_prompt(), cancellation: CancellationSource().token).toList();
        expect(
          (badDelta.single as LlmFailed).error.kind,
          LlmErrorKind.protocol,
        );
      },
    );

    test(
      'Responses malformed usage isolates affected semantic facts',
      () async {
        Future<LlmUsage> streamed(Map<String, Object?> rawUsage) async {
          final payload = jsonEncode(<String, Object?>{
            'type': 'response.completed',
            'response': <String, Object?>{'usage': rawUsage},
          });
          final events =
              await _openAi(
                    RecordingClient((_) => sseResponse('data: $payload\n\n')),
                  )
                  .stream(
                    _prompt(BuiltInLlmCatalog.gpt5MiniModel),
                    cancellation: CancellationSource().token,
                  )
                  .toList();
          expect(events.last, isA<LlmCompleted>());
          return events.whereType<LlmUsageUpdate>().single.usage;
        }

        final conflict = await streamed(<String, Object?>{
          'input_tokens': 8,
          'prompt_tokens': 9,
          'output_tokens': 3,
        });
        expect(conflict.reportedInputTotal, isNull);
        expect(conflict.reportedOutputTotalTokens, 3);
        expect(
          conflict.hasAnomaly(
            LlmUsageAnomalyKind.aliasConflict,
            metric: LlmUsageMetricKind.reportedInputTotal,
          ),
          isTrue,
        );

        final malformedDetails = await streamed(<String, Object?>{
          'input_tokens': 8,
          'output_tokens': 3,
          'total_tokens': 11,
          'input_tokens_details': 'bad',
        });
        expect(malformedDetails.cacheRead, isNull);
        expect(malformedDetails.totalTokens, 11);
        expect(
          malformedDetails.hasAnomaly(
            LlmUsageAnomalyKind.invalidValue,
            metric: LlmUsageMetricKind.cacheRead,
          ),
          isTrue,
        );

        final impossible = await streamed(<String, Object?>{
          'input_tokens': 8,
          'output_tokens': 3,
          'output_tokens_details': <String, Object?>{'reasoning_tokens': 4},
        });
        expect(impossible.reasoning?.value, 4);
        expect(impossible.output, isNull);
        expect(impossible.responseGenerated, isNull);

        final inconsistent = await streamed(<String, Object?>{
          'input_tokens': 8,
          'output_tokens': 3,
          'total_tokens': 10,
        });
        expect(inconsistent.reportedOverallTokens, 10);
        expect(inconsistent.totalTokens, 11);
      },
    );

    test(
      'hanging credential resolution is cancelled without dispatch',
      () async {
        final hanging = _HangingCredentialResolver();
        final client = RecordingClient((_) => sseResponse(''));
        final source = CancellationSource();
        final future = OpenAiResponsesLlmProvider(
          profile: OpenAiResponsesProfile.builtIn(),
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

    test('cancellation wins over TimeoutException', () async {
      final source = CancellationSource();
      final events = await _openAi(
        RecordingClient((_) {
          source.cancel();
          throw TimeoutException('late timeout');
        }),
      ).stream(_prompt(), cancellation: source.token).toList();
      expect(events.single, isA<LlmCancelled>());
    });

    test('cancellation before dispatch sends no HTTP request', () async {
      final client = RecordingClient((_) => sseResponse(''));
      final source = CancellationSource();
      source.cancel();
      final events = await _openAi(
        client,
      ).stream(_prompt(), cancellation: source.token).toList();
      expect(client.requests, isEmpty);
      expect(events.single, isA<LlmCancelled>());
    });

    test('missing credentials skip dispatch', () async {
      final client = RecordingClient((_) => sseResponse(''));
      final events = await _openAi(
        client,
        key: null,
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect(client.requests, isEmpty);
      expect(
        (events.single as LlmFailed).error.kind,
        LlmErrorKind.configuration,
      );
      expect((events.single as LlmFailed).error.message, contains('openai'));
    });

    test('cancels Responses streaming without live requests', () async {
      final chunks = StreamController<List<int>>();
      final client = RecordingClient(
        (_) => http.StreamedResponse(chunks.stream, 200),
      );
      final source = CancellationSource();
      final future = _openAi(
        client,
      ).stream(_prompt(), cancellation: source.token).toList();
      chunks.add(
        utf8.encode(
          'data: {"type":"response.output_text.delta","delta":"partial"}\n\n',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.cancel();
      await chunks.close();
      final events = await future;
      expect(events.whereType<LlmTextDelta>(), isNotEmpty);
      expect(events.last, isA<LlmCancelled>());
    });

    test('maps GPT reasoning efforts and replays encrypted output items', () {
      final provider = _openAi(RecordingClient((_) => sseResponse('')));
      expect(
        provider.requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt54Model.ref,
            generation: LlmGenerationConfig(
              reasoningEffort: ReasoningEffort.max,
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
        )['reasoning'],
        <String, String>{'effort': 'xhigh'},
      );
      expect(
        provider.requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt54Model.ref,
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
        )['reasoning'],
        <String, String>{'effort': 'none'},
      );
      expect(
        provider.requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt5MiniModel.ref,
            generation: LlmGenerationConfig(
              reasoningEffort: ReasoningEffort.low,
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
        )['reasoning'],
        <String, String>{'effort': 'low'},
      );
      expect(
        () => provider.requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt5MiniModel.ref,
            generation: LlmGenerationConfig(
              reasoningEffort: ReasoningEffort.max,
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
      expect(
        () => provider.requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
            generation: LlmGenerationConfig(
              reasoningMode: ReasoningMode.enabled,
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
      final replayed = provider.requestBody(
        LlmRequest(
          model: BuiltInLlmCatalog.gpt5MiniModel.ref,
          context: LlmContext(
            messages: <LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.user,
                parts: <LlmContentPart>[LlmTextPart('q')],
              ),
              LlmMessage(
                role: LlmMessageRole.assistant,
                parts: <LlmContentPart>[
                  LlmToolCallPart(
                    callId: ToolCallId('call_1'),
                    name: 'lookup',
                    arguments: '{}',
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
            continuationEntries: <LlmContinuationEntry>[
              LlmContinuationEntry(
                assistantMessageIndex: 1,
                state: LlmProviderTurnState(
                  origin: BuiltInLlmCatalog.gpt5MiniModel.ref,
                  wireFamily: LlmWireFamily.openaiResponses,
                  format: openaiResponsesOutputItemsV1,
                  payload: <Map<String, Object?>>[
                    <String, Object?>{
                      'type': 'reasoning',
                      'id': 'rs_1',
                      'encrypted_content': 'enc',
                    },
                    <String, Object?>{
                      'type': 'function_call',
                      'id': 'fc_1',
                      'call_id': 'call_1',
                      'name': 'lookup',
                      'arguments': '{}',
                    },
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      final input = replayed['input'] as List<dynamic>;
      expect(input[1]['type'], 'reasoning');
      expect(input[1]['encrypted_content'], 'enc');
      expect(input.where((item) => item['type'] == 'reasoning'), hasLength(1));
      expect(input.last['type'], 'function_call_output');
    });

    test('rejects unsupported output bounds locally', () {
      expect(
        () => _openAi(RecordingClient((_) => sseResponse(''))).requestBody(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
            generation: LlmGenerationConfig(
              reasoningMode: ReasoningMode.disabled,
              maxOutputTokens: 999999,
            ),
          ),
        ),
        throwsA(isA<LlmException>()),
      );
    });
  });
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

OpenAiResponsesLlmProvider _openAi(
  RecordingClient client, {
  String? key = 'openai-secret',
}) {
  return OpenAiResponsesLlmProvider(
    profile: OpenAiResponsesProfile.builtIn(),
    client: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(
        key == null
            ? const <ProviderId, String>{}
            : <ProviderId, String>{BuiltInLlmCatalog.openAi: key},
      ),
      readEnvironment: (_) => null,
    ),
  );
}

LlmRequest _prompt([LlmModel? model]) {
  final selected = model ?? BuiltInLlmCatalog.gpt4oMiniModel;
  return LlmRequest(
    model: selected.ref,
    generation: LlmGenerationConfig(
      reasoningMode:
          selected.capabilities.reasoning ==
              ModelReasoningCapability.unsupported
          ? ReasoningMode.disabled
          : ReasoningMode.enabled,
    ),
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
