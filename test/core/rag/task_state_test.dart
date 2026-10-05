import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/infrastructure/rag/jsonl_task_state_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';
import '../../support/rag_task_state_fixture.dart';

void main() {
  test(
    'user provenance survives replay; replacement and scopes remain distinct',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final repo = JsonlRagTaskStateRepository(storage);
      final initial = await repo.load('A', 'one');
      final nine = changedTaskState(initial, '09:00');
      await repo.save(
        nine,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final eight = changedTaskState(nine, '08:30');
      await repo.save(
        eight,
        expectedRevision: 1,
        cancellation: CancellationSource().token,
      );
      final restored = await JsonlRagTaskStateRepository(
        storage,
      ).load('A', 'one');
      expect(restored.revision, 2);
      expect(restored.facts.single.quote, '08:30');
      expect(restored.superseded.single.quote, '09:00');
      expect(restored.facts.single.sourceKind, 'automatic_user_quote');
      expect(restored.context, contains('08:30'));
      expect(restored.context, isNot(contains('09:00')));
      expect((await repo.load('A', 'two')).facts, isEmpty);
      expect((await repo.load('B', 'one')).facts, isEmpty);
      expect(
        restored.evidenceId(restored.facts.single),
        isNot(nine.evidenceId(nine.facts.single)),
      );
    },
  );

  test(
    'late extractor cannot overwrite a newer explicit manual edit',
    () async {
      final repo = JsonlRagTaskStateRepository(FakeMemoryJsonlStorage());
      final before = changedTaskState(await repo.load('A', 'one'), '09:00');
      await repo.save(
        before,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final manual = changedTaskState(
        before,
        '07:45',
        source: 'manual_user_edit',
      );
      await repo.save(
        manual,
        expectedRevision: 1,
        cancellation: CancellationSource().token,
      );
      await expectLater(
        repo.save(
          changedTaskState(before, '08:30'),
          expectedRevision: 1,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<RagTaskStateConflict>()),
      );
      expect((await repo.load('A', 'one')).facts.single.quote, '07:45');
    },
  );

  test('cancelled publication does not change active state', () async {
    final repo = JsonlRagTaskStateRepository(FakeMemoryJsonlStorage());
    final before = await repo.load('A', 'one');
    final source = CancellationSource()..cancel();
    await expectLater(
      repo.save(
        changedTaskState(before, '09:00'),
        expectedRevision: 0,
        cancellation: source.token,
      ),
      throwsA(anything),
    );
    expect((await repo.load('A', 'one')).revision, 0);
  });

  test(
    'old state, documents and fabricated metadata cannot supply new user facts',
    () {
      final before = changedTaskState(
        RagTaskState(project: 'A', session: 'one'),
        '09:00',
      );
      for (final input in [
        'What time did I choose?',
        'The document discusses scheduling.',
      ]) {
        expect(
          () => RagTaskPatch.parse(
            jsonEncode({
              'updates': [
                {
                  'id': 'constraint.time',
                  'kind': 'constraint',
                  'quote': '09:00',
                },
              ],
            }),
            input,
            before,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => RagTaskPatch.parse(
          jsonEncode({
            'updates': [
              {
                'id': 'constraint.time',
                'kind': 'constraint',
                'quote': '08:30',
                'project': 'B',
              },
            ],
          }),
          '08:30',
          before,
        ),
        throwsFormatException,
      );
      final json = before.toJson();
      final encoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      (encoded['facts'] as List).first['user_text_sha256'] = 'forged';
      expect(() => RagTaskState.fromJson(encoded), throwsFormatException);
      expect(
        RagTaskPatch.parse(
          '{"updates":[]}',
          'A factual detour?',
          before,
        ).apply(before, userText: 'A factual detour?', submissionId: 'detour'),
        same(before),
      );
    },
  );
}
