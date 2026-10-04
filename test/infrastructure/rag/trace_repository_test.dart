import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

void main() {
  test(
    'immutable requests/receipts survive reopen with project and session isolation',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final repo = JsonlRagTraceRepository(storage);
      final trace = <String, Object?>{'id': 'one', 'context': 'old revision'};
      final saving = repo.saveRequest('a|b', 'c', 'one', trace);
      trace['context'] = 'changed after admission';
      await saving;
      await repo.saveCompletion('a|b', 'c', 'one', {
        'accepted_message_id': 'message-1',
      });
      await expectLater(
        repo.saveRequest('a|b', 'c', 'one', trace),
        throwsStateError,
      );
      final restarted = JsonlRagTraceRepository(storage);
      expect(
        (await restarted.list('a|b', 'c')).single['context'],
        'old revision',
      );
      expect(
        (await restarted.list(
          'a|b',
          'c',
        )).single['completion']['accepted_message_id'],
        'message-1',
      );
      expect(await restarted.list('a', 'b|c'), isEmpty);
      expect(await restarted.list('a|b', 'another-chat'), isEmpty);
      await Future.wait([
        for (var i = 0; i < 3; i++)
          repo.saveRequest('a|b', 'c', 'next-$i', {'id': 'next-$i'}),
      ]);
      expect(await restarted.list('a|b', 'c'), hasLength(4));
    },
  );
}
