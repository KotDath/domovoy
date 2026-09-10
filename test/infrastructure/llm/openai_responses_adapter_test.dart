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

    test('collects output_item.done by index order and rejects extras', () async {
      final events =
          await _openAi(
                RecordingClient(
                  (_) => sseResponse(
                    'event: response.output_item.done\n'
                    'data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"ans","annotations":[{"type":"url_citation","url":"https://example.com","title":"Example","start_index":0,"end_index":3}]}]}}\n\n'
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
      expect(completed.toString(), isNot(contains('enc')));
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

    test('malformed numeric usage and deltas are protocol failures', () async {
      final negative = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.completed","response":{"usage":{"output_tokens":-3}}}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((negative.single as LlmFailed).error.kind, LlmErrorKind.protocol);

      final badDelta = await _openAi(
        RecordingClient(
          (_) => sseResponse(
            'data: {"type":"response.output_text.delta","delta":12}\n\n',
          ),
        ),
      ).stream(_prompt(), cancellation: CancellationSource().token).toList();
      expect((badDelta.single as LlmFailed).error.kind, LlmErrorKind.protocol);
    });

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
