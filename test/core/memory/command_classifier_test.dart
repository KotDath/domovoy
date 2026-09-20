import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ScriptedInvocation implements MemoryExtractionLlmInvocation {
  _ScriptedInvocation(this.reply);

  final String reply;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  LlmModel resolve(ModelRef model) => BuiltInLlmCatalog.deepSeekV4FlashModel;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    yield LlmTextDelta(reply);
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

LlmMemoryCommandClassifier _classifier(_ScriptedInvocation invocation) =>
    LlmMemoryCommandClassifier(
      llm: invocation,
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );

void main() {
  group('LlmMemoryCommandClassifier', () {
    test('classifies a typoed global remember request', () async {
      final invocation = _ScriptedInvocation(
        '{"intent":"remember","layer":"longTerm",'
        '"content":"Меня зовут Даниил."}',
      );

      final proposal = await _classifier(invocation).classify(
        'Запомни гглобально, что меня зовут Даниил',
        cancellation: CancellationSource().token,
      );

      expect(proposal, isNotNull);
      expect(proposal!.layer, MemoryLayer.longTerm);
      expect(proposal.scope, MemoryScope.global);
      expect(proposal.kind, MemoryKind.fact);
      expect(proposal.content, 'Меня зовут Даниил.');

      final request = invocation.requests.single;
      expect(
        request.context.systemPrompt,
        LlmMemoryCommandClassifier.instruction,
      );
      expect(request.context.tools, isEmpty);
      expect(request.context.continuationEntries, isEmpty);
      expect(request.context.messages, hasLength(1));
      final payload =
          (request.context.messages.single.parts.single as LlmTextPart).text;
      expect(payload, contains('Запомни гглобально'));
    });

    test('returns no proposal for an ordinary message', () async {
      final invocation = _ScriptedInvocation('{"intent":"none"}');

      final proposal = await _classifier(invocation).classify(
        'Как сегодня погода?',
        cancellation: CancellationSource().token,
      );

      expect(proposal, isNull);
    });

    test('rejects malformed or over-specified output', () async {
      for (final reply in <String>[
        'not json',
        '{"intent":"none","content":"x"}',
        '{"intent":"remember","layer":"other","content":"x"}',
        '{"intent":"remember","layer":"working"}',
      ]) {
        final invocation = _ScriptedInvocation(reply);
        await expectLater(
          _classifier(
            invocation,
          ).classify('remember this', cancellation: CancellationSource().token),
          throwsA(
            isA<MemoryException>().having(
              (error) => error.error.kind,
              'kind',
              MemoryErrorKind.protocol,
            ),
          ),
        );
      }
    });
  });
}
