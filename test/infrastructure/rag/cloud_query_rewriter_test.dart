import 'dart:async';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/rag/cloud_query_rewriter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

final class _SilentProvider implements LlmProvider {
  @override
  ProviderId get id => BuiltInLlmCatalog.deepSeek;
  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;
  final streamController = StreamController<LlmEvent>();
  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) => streamController.stream;
}

void main() {
  test(
    'silent provider times out with explicit original-query fallback',
    () async {
      final provider = _SilentProvider();
      final runtime = testRuntime(provider: provider);
      final rewriter = CloudRagQueryRewriter(
        registry: runtime.registry,
        model: testDefinition().model,
        timeout: const Duration(milliseconds: 10),
      );
      final result = await rewriter.rewrite(
        'original question',
        CancellationSource().token,
      );
      expect(result.query, 'original question');
      expect(result.fallbackReason, 'rewrite_timeout');
      await provider.streamController.close();
      await runtime.close();
    },
  );
  test('lexical guard rejects number, entity and negation drift/additions', () {
    const q = 'Domovoy Android не запускает в 09:00?';
    expect(
      ragRewritePreservesQuery(
        q,
        'Не запускает ли Domovoy на Android в 09:00?',
      ),
      true,
    );
    for (final rewrite in [
      'Domovoy Android запускает в 09:00?',
      'Domovoy Android не запускает в 08:30?',
      'Domovoy Linux не запускает в 09:00?',
      'Domovoy Android Linux не запускает в 09:00?',
      'Домовой Android не запускает в 09:00?',
    ]) {
      expect(ragRewritePreservesQuery(q, rewrite), false, reason: rewrite);
    }
    expect(
      ragRewritePreservesQuery('Домовой не работает?', 'Алиса не работает?'),
      false,
    );
    expect(
      ragRewritePreservesQuery('не удалять и не менять', 'не удалять и менять'),
      false,
    );
  });
  test(
    'isolated request audited before transport, invalid/ambiguous fallbacks',
    () async {
      const original = 'What are USER.md limits?';
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [
          textTurn('{"query":"USER.md limits?","ambiguous":false}'),
          textTurn('{"query":"USER.md limits?","ambiguous":true}'),
          textTurn('{"query":"USER.md 5000 limits?","ambiguous":false}'),
          textTurn('not JSON'),
        ],
      );
      final runtime = testRuntime(provider: provider);
      var observed = 0;
      final rewriter = CloudRagQueryRewriter(
        registry: runtime.registry,
        model: testDefinition().model,
        beforeRequest: (request) async {
          expect(provider.requests.length, observed);
          expect((request['context'] as Map)['tools'], isEmpty);
          observed++;
        },
      );
      final first = await rewriter.rewrite(
        original,
        CancellationSource().token,
      );
      expect(first.query, 'USER.md limits?');
      expect(first.fallbackReason, isNull);
      for (var i = 0; i < 3; i++) {
        final fallback = await rewriter.rewrite(
          original,
          CancellationSource().token,
        );
        expect(fallback.query, original);
        expect(fallback.fallbackReason, isNotNull);
      }
      expect(
        provider.requests.every(
          (r) =>
              r.context.messages.length == 1 &&
              r.context.tools.isEmpty &&
              r.context.continuationEntries.isEmpty,
        ),
        true,
      );
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        rewriter.rewrite(original, cancelled.token),
        throwsA(isA<RagCancelled>()),
      );
      expect(provider.requests, hasLength(4));
      await runtime.close();
    },
  );
}
