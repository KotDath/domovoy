import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('request snapshots, usage, and events', () {
    test('request snapshot serializes mixed context without secrets', () {
      final snapshot = LlmRequest(
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        context: LlmContext(
          systemPrompt: 'You are helpful.',
          messages: <LlmMessage>[
            LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('hello')],
            ),
            LlmMessage(
              role: LlmMessageRole.assistant,
              parts: <LlmContentPart>[
                LlmTextPart('hi'),
                LlmToolCallPart(
                  callId: ToolCallId('call_1'),
                  name: 'lookup',
                  arguments: '{"q":"x"}',
                ),
              ],
            ),
            LlmMessage(
              role: LlmMessageRole.tool,
              parts: <LlmContentPart>[
                LlmToolResultPart(callId: ToolCallId('call_1'), content: 'ok'),
              ],
            ),
          ],
          tools: <LlmToolDescriptor>[
            LlmToolDescriptor(
              name: 'lookup',
              description: 'Look something up',
              parameters: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'q': <String, Object?>{'type': 'string'},
                },
              },
            ),
          ],
        ),
        generation: LlmGenerationConfig(temperature: 0.4, maxOutputTokens: 16),
      ).snapshot();

      final json = snapshot.toJson();
      expect(json.toString(), isNot(contains('sk-')));
      expect(json.containsKey('Authorization'), isFalse);
      expect(LlmRequestSnapshot.fromJson(json), snapshot);
      expect(snapshot.context.messages, hasLength(3));
    });

    test('partial usage and unknown finish reasons round-trip', () {
      final usage = LlmUsage(inputTokens: 3, cacheHitTokens: 1);
      expect(usage.outputTokens, isNull);
      expect(LlmUsage.fromJson(usage.toJson()), usage);
      expect(
        LlmFinishReason.fromWireName('server_busy'),
        LlmFinishReason.unknown,
      );
      expect(
        LlmFinishReason.fromJson(LlmFinishReason.length.toJson()),
        LlmFinishReason.length,
      );
    });

    test('invalid numeric fields are rejected', () {
      expect(() => LlmUsage(totalTokens: -1), throwsA(isA<LlmException>()));
      expect(
        () => LlmUsage.fromJson(<String, Object?>{
          'type': LlmUsage.jsonType,
          'version': 1,
          'inputTokens': -2,
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        LlmError.fromJson(<String, Object?>{
          'type': LlmError.jsonType,
          'version': 1,
          'kind': 'configuration',
          'message': 'ok',
          'secret': 'sk-live',
        }).toJson().containsKey('secret'),
        isFalse,
      );
      final error = LlmError(
        kind: LlmErrorKind.authentication,
        message: 'Провайдер deepseek отклонил API-ключ.',
      );
      expect(error.toJson().toString(), isNot(contains('sk-')));
      expect(LlmError.fromJson(error.toJson()), error);
    });

    test('tool descriptor equality ignores map insertion order', () {
      final first = LlmToolDescriptor(
        name: 'lookup',
        parameters: <String, Object?>{'type': 'object', 'z': 1, 'a': 2},
      );
      final second = LlmToolDescriptor(
        name: 'lookup',
        parameters: <String, Object?>{'a': 2, 'type': 'object', 'z': 1},
      );
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(<LlmToolDescriptor>{first, second}, hasLength(1));
      expect(<LlmToolDescriptor, String>{first: 'x'}[second], 'x');
    });

    test('provider events round-trip through versioned JSON', () {
      final events = <LlmEvent>[
        const LlmReasoningDelta('think'),
        const LlmTextDelta('hi'),
        LlmToolCallDelta(
          callId: ToolCallId('call_1'),
          index: 0,
          name: 'lookup',
          argumentsFragment: '{"q":',
        ),
        LlmUsageUpdate(LlmUsage(inputTokens: 1, outputTokens: 2)),
        LlmCompleted(
          finishReason: LlmFinishReason.toolCalls,
          usage: LlmUsage(totalTokens: 3),
        ),
        LlmFailed(LlmError(kind: LlmErrorKind.protocol, message: 'bad stream')),
        const LlmCancelled(),
      ];
      for (final event in events) {
        expect(LlmEvent.fromJson(event.toJson()), event);
      }
    });

    test('rejects event JSON whose version is 1.0 rather than int 1', () {
      expect(
        () => LlmEvent.fromJson(<String, Object?>{
          'type': LlmTextDelta.jsonType,
          'version': 1.0,
          'text': 'hi',
        }),
        throwsA(isA<LlmException>()),
      );
    });

    test('rejects unknown and malformed provider events', () {
      expect(
        () => LlmEvent.fromJson(<String, Object?>{
          'type': 'llm.unknown_event',
          'version': 1,
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmEvent.fromJson(<String, Object?>{
          'type': LlmToolCallDelta.jsonType,
          'version': 1,
          'callId': ToolCallId('call_1').toJson(),
          'index': -1,
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmEvent.fromJson('not-an-object'),
        throwsA(isA<LlmException>()),
      );
    });

    test('tool descriptors freeze parameter maps', () {
      final parameters = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };
      final tool = LlmToolDescriptor(name: 'lookup', parameters: parameters);
      parameters['type'] = 'array';
      expect(tool.parameters['type'], 'object');
      expect(() => tool.parameters['x'] = 1, throwsUnsupportedError);
    });
  });
}
