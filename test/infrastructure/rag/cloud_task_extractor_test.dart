import 'dart:convert';
import 'dart:async';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/rag/cloud_task_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/rag_task_state_fixture.dart';

final class _SilentProvider implements LlmProvider {
  @override
  ProviderId get id => BuiltInLlmCatalog.deepSeek;
  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;
  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) => Stream<LlmEvent>.multi((_) {});
}

void main() {
  for (final valid in [true, false]) {
    test(
      'isolated extractor ${valid ? 'copies new user quotes' : 'rejects an old-state quote'} and accounts usage',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [
            textTurn(
              jsonEncode({
                'updates': [
                  {
                    'id': 'constraint.time',
                    'kind': 'constraint',
                    'quote': valid ? '08:30' : '09:00',
                  },
                ],
              }),
              usage: LlmUsage(inputTokens: 10, outputTokens: 4),
            ),
          ],
        );
        final runtime = testRuntime(provider: provider);
        final before = changedTaskState(
          RagTaskState(project: 'p', session: 's'),
          '09:00',
        );
        final requests = <Map<String, Object?>>[],
            receipts = <Map<String, Object?>>[];
        final extractor = CloudRagTaskExtractor(
          registry: runtime.registry,
          model: testDefinition().model,
          beforeRequest: (r) async => requests.add(r),
          afterResult: (r) async => receipts.add(r),
        );
        final operation = extractor.extract(
          before,
          'Change the chosen time to 08:30.',
          CancellationSource().token,
        );
        if (valid) {
          expect((await operation).patch.updates.single.quote, '08:30');
        } else {
          await expectLater(operation, throwsFormatException);
        }
        expect(provider.requests, hasLength(1));
        final request = provider.requests.single;
        expect(request.context.messages, hasLength(1));
        expect(request.context.messages.single.role, LlmMessageRole.user);
        expect(request.context.tools, isEmpty);
        expect(request.context.continuationEntries, isEmpty);
        expect(request.generation.temperature, 0);
        final payload =
            jsonDecode(
                  (request.context.messages.single.parts.single as LlmTextPart)
                      .text,
                )
                as Map;
        expect(payload.keys.toSet(), {'prior_user_state', 'new_user_message'});
        expect(payload['new_user_message'], 'Change the chosen time to 08:30.');
        expect(payload['prior_user_state'], [
          {'id': 'constraint.time', 'kind': 'constraint', 'quote': '09:00'},
        ]);
        expect(requests, hasLength(1));
        expect(receipts, hasLength(1));
        expect(
          receipts.single['terminal'],
          valid ? 'TaskExtractionValidated' : 'TaskExtractionFailed',
        );
        expect(receipts.single['usage'], isNotNull);
        expect(receipts.single['private_reasoning'], 'omitted');
        await runtime.close();
      },
    );
  }

  for (final parentCancels in [false, true]) {
    test(
      'extractor ${parentCancels ? 'user cancellation' : 'timeout'} is distinct and releases parent registration',
      () async {
        final runtime = testRuntime(provider: _SilentProvider());
        final source = CancellationSource();
        final receipts = <Map<String, Object?>>[];
        final extractor = CloudRagTaskExtractor(
          registry: runtime.registry,
          model: testDefinition().model,
          timeout: const Duration(milliseconds: 40),
          afterResult: (r) async => receipts.add(r),
        );
        final future = extractor.extract(
          RagTaskState(project: 'p', session: 's'),
          'Chosen time 9:00',
          source.token,
        );
        final assertion = expectLater(
          future,
          throwsA(
            parentCancels ? isA<RagCancelled>() : isA<TimeoutException>(),
          ),
        );
        if (parentCancels) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          source.cancel();
        }
        await assertion;
        expect(source.registrationCount, 0);
        expect(
          receipts.single['terminal'],
          parentCancels ? 'TaskExtractionCancelled' : 'TaskExtractionTimedOut',
        );
        await runtime.close();
      },
    );
  }

  test('audit failure prevents a physical extractor request', () async {
    final provider = QueueScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: [],
    );
    final runtime = testRuntime(provider: provider);
    final extractor = CloudRagTaskExtractor(
      registry: runtime.registry,
      model: testDefinition().model,
      beforeRequest: (_) async => throw StateError('storage'),
    );
    await expectLater(
      extractor.extract(
        RagTaskState(project: 'p', session: 's'),
        '09:00',
        CancellationSource().token,
      ),
      throwsStateError,
    );
    expect(provider.requests, isEmpty);
    await runtime.close();
  });
}
