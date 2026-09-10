import 'dart:async';

import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_llm_provider.dart';

void main() {
  group('registry and cancellation', () {
    test('resolves exact provider/model pairs and wire family', () async {
      final registry = _registryWith(
        ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: <LlmEvent>[
            const LlmReasoningDelta('think'),
            const LlmTextDelta('answer'),
            LlmUsageUpdate(LlmUsage(totalTokens: 4)),
            const LlmCompleted(finishReason: LlmFinishReason.stop),
          ],
        ),
      );

      final events = await registry
          .stream(
            LlmRequest(
              model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
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

      expect(events, hasLength(4));
      expect(events[0], isA<LlmReasoningDelta>());
      expect(events[1], isA<LlmTextDelta>());
      expect(events[2], isA<LlmUsageUpdate>());
      expect(events[3], isA<LlmCompleted>());
      expect(events.where((event) => event.isTerminal), hasLength(1));
    });

    test('rejects a model owned by another provider', () {
      final registry = _registryWith(
        ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
        ),
      );
      expect(
        () => registry.resolve(
          ModelRef(
            providerId: BuiltInLlmCatalog.deepSeek,
            modelId: BuiltInLlmCatalog.gpt4oMini,
          ),
        ),
        throwsA(
          isA<LlmException>().having(
            (error) => error.error.kind,
            'kind',
            LlmErrorKind.configuration,
          ),
        ),
      );
    });

    test('rejects wire-family mismatches', () {
      final registry = LlmProviderRegistry();
      registry.registerProvider(
        ScriptedLlmProvider(
          id: BuiltInLlmCatalog.openAi,
          wireFamily: LlmWireFamily.openaiChatCompletions,
        ),
      );
      registry.registerModel(BuiltInLlmCatalog.gpt4oMiniModel);
      expect(
        () => registry.resolve(BuiltInLlmCatalog.gpt4oMiniModel.ref),
        throwsA(isA<LlmException>()),
      );
    });

    test('suppresses events after one terminal', () async {
      final registry = _registryWith(
        ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[
            LlmTextDelta('a'),
            LlmCompleted(finishReason: LlmFinishReason.stop),
            LlmTextDelta('late'),
          ],
        ),
      );
      final events = await registry
          .stream(_userRequest(), cancellation: CancellationSource().token)
          .toList();
      expect(events, hasLength(2));
      expect(events.last, isA<LlmCompleted>());
    });

    test(
      'converts unexpected stream closure into interrupted failure',
      () async {
        final registry = _registryWith(
          ScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            events: const <LlmEvent>[LlmTextDelta('partial')],
            closeWithoutTerminal: true,
          ),
        );
        final events = await registry
            .stream(_userRequest(), cancellation: CancellationSource().token)
            .toList();
        expect((events.first as LlmTextDelta).text, 'partial');
        expect((events.last as LlmFailed).error.kind, LlmErrorKind.interrupted);
      },
    );

    test(
      'cancellation is idempotent and yields a cancelled terminal',
      () async {
        final gate = Completer<void>();
        final registry = _registryWith(
          ScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            events: const <LlmEvent>[LlmTextDelta('partial')],
            gate: gate,
          ),
        );
        final source = CancellationSource();
        final future = registry
            .stream(_userRequest(), cancellation: source.token)
            .toList();
        await Future<void>.delayed(Duration.zero);
        source.cancel();
        source.cancel();
        final events = await future;
        expect(events.first, isA<LlmTextDelta>());
        expect(events.last, isA<LlmCancelled>());
        expect(events.where((event) => event.isTerminal), hasLength(1));
      },
    );

    test('register fires immediately on an already-cancelled token', () {
      final source = CancellationSource();
      source.cancel();
      var calls = 0;
      final registration = source.token.register(() => calls += 1);
      expect(calls, 1);
      source.cancel();
      registration.dispose();
      registration.dispose();
      expect(calls, 1);
      expect(source.registrationCount, 0);
    });

    test('dispose detaches a registration before cancellation', () {
      final source = CancellationSource();
      var calls = 0;
      final registration = source.token.register(() => calls += 1);
      expect(source.registrationCount, 1);
      registration.dispose();
      registration.dispose();
      expect(source.registrationCount, 0);
      source.cancel();
      expect(calls, 0);
    });

    test('completed operations do not accumulate cancellation listeners', () {
      final source = CancellationSource();
      for (var i = 0; i < 20; i++) {
        final registration = source.token.register(() {});
        registration.dispose();
      }
      expect(source.registrationCount, 0);
      source.cancel();
    });
  });
}

LlmProviderRegistry _registryWith(LlmProvider provider) {
  final registry = LlmProviderRegistry();
  registry.registerProvider(provider);
  BuiltInLlmCatalog.registerInto(registry);
  return registry;
}

LlmRequest _userRequest() {
  return LlmRequest(
    model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    context: LlmContext(
      messages: <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[LlmTextPart('hi')],
        ),
      ],
    ),
  );
}
