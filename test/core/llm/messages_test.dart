import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('messages and generation', () {
    test('mixed history round-trips with defensive copies', () {
      final originalParts = <LlmContentPart>[
        LlmTextPart('answer'),
        LlmReasoningPart('think'),
        LlmToolCallPart(
          callId: ToolCallId('call_1'),
          name: 'lookup',
          arguments: '{"q":1}',
        ),
      ];
      final message = LlmMessage(
        role: LlmMessageRole.assistant,
        parts: originalParts,
      );
      originalParts.add(LlmTextPart('late'));
      expect(message.parts, hasLength(3));
      expect(
        () => message.parts.add(LlmTextPart('nope')),
        throwsUnsupportedError,
      );

      final restored = LlmMessage.fromJson(message.toJson());
      expect(restored, message);

      final user = LlmMessage(
        role: LlmMessageRole.user,
        parts: <LlmContentPart>[LlmTextPart('hello')],
      );
      final tool = LlmMessage(
        role: LlmMessageRole.tool,
        parts: <LlmContentPart>[
          LlmToolResultPart(callId: ToolCallId('call_1'), content: 'ok'),
        ],
      );
      expect(LlmMessage.fromJson(user.toJson()), user);
      expect(LlmMessage.fromJson(tool.toJson()), tool);
    });

    test('rejects invalid role and part combinations', () {
      expect(
        () => LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[LlmReasoningPart('nope')],
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmMessage(
          role: LlmMessageRole.tool,
          parts: <LlmContentPart>[LlmTextPart('nope')],
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmToolResultPart.fromJson(<String, Object?>{
          'type': LlmToolResultPart.jsonType,
          'version': 1,
          'content': 'missing call',
        }),
        throwsA(isA<LlmException>()),
      );
    });

    test('generation config validates temperature and output cap', () {
      final config = LlmGenerationConfig(
        reasoningMode: ReasoningMode.enabled,
        temperature: 0.2,
        maxOutputTokens: 128,
      );
      expect(LlmGenerationConfig.fromJson(config.toJson()), config);
      expect(config.reasoningEffort, ReasoningEffort.modelDefault);
      final decoded = LlmGenerationConfig.fromJson(<String, Object?>{
        'type': LlmGenerationConfig.jsonType,
        'version': 1,
        'reasoningMode': 'enabled',
      });
      expect(decoded.reasoningEffort, ReasoningEffort.modelDefault);
      expect(
        () => LlmGenerationConfig(temperature: 2.1),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmGenerationConfig(temperature: double.nan),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmGenerationConfig(maxOutputTokens: 0),
        throwsA(isA<LlmException>()),
      );
    });

    test('model metadata equality and capabilities round-trip', () {
      final model = BuiltInLlmCatalog.deepSeekV4FlashModel;
      expect(LlmModel.fromJson(model.toJson()), model);
      expect(
        () => LlmModel(
          providerId: model.providerId,
          id: model.id,
          name: 'x',
          wireFamily: model.wireFamily,
          capabilities: model.capabilities,
          contextBound: 0,
          outputBound: 10,
        ),
        throwsA(isA<LlmException>()),
      );
    });
  });
}
