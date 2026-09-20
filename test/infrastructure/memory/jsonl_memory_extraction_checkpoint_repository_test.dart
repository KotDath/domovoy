import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';
import '../../support/memory_jsonl_storage.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

MemoryExtractionCheckpoint _checkpoint({
  String sessionId = 'session-1',
  int revision = 0,
  List<String> processed = const <String>[],
  List<String> pending = const <String>['s1'],
  int lastActivityMicros = 1,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
  int? lastFlushMicros,
}) {
  return MemoryExtractionCheckpoint(
    sessionId: AgentSessionId(sessionId),
    revision: revision,
    processedSourceIds: processed.map(MemorySourceId.new).toList(),
    pendingSourceIds: pending.map(MemorySourceId.new).toList(),
    lastActivityMicros: lastActivityMicros,
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    lastFlushMicros: lastFlushMicros,
  );
}

void main() {
  final open = CancellationSource().token;

  group('JsonlMemoryExtractionCheckpointRepository', () {
    test('round-trips and restores across stack reconstruction', () async {
      final storage = FakeMemoryJsonlStorage();
      final checkpoint = _checkpoint(
        processed: const <String>['s1'],
        pending: const <String>['s2'],
        lastActivityMicros: 2,
        updatedAtMicros: 2,
      );
      final repository = MemoryJsonlStack(
        storage: storage,
      ).extractionCheckpointRepository;
      await repository.save(
        checkpoint,
        expectedRevision: 0,
        cancellation: open,
      );
      expect(
        await repository.load(checkpoint.sessionId, cancellation: open),
        checkpoint,
      );
      final restarted = MemoryJsonlStack(
        storage: storage,
      ).extractionCheckpointRepository;
      expect(
        await restarted.list(cancellation: open),
        <MemoryExtractionCheckpoint>[checkpoint],
      );
    });

    test('enforces conflict, tombstone, and cancellation', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(
        storage: storage,
      ).extractionCheckpointRepository;
      final checkpoint = _checkpoint();
      await repository.save(
        checkpoint,
        expectedRevision: 0,
        cancellation: open,
      );
      final successor = _checkpoint(
        revision: 1,
        processed: const <String>['s1'],
        pending: const <String>[],
        updatedAtMicros: 2,
      );
      await repository.save(successor, expectedRevision: 0, cancellation: open);
      await expectLater(
        repository.save(successor, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );

      await repository.delete(
        checkpoint.sessionId,
        expectedRevision: 1,
        cancellation: open,
      );
      expect(
        await repository.load(checkpoint.sessionId, cancellation: open),
        isNull,
      );
      await expectLater(
        repository.save(checkpoint, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );

      final cancelled = CancellationSource()..cancel();
      await expectLater(
        repository.load(checkpoint.sessionId, cancellation: cancelled.token),
        _memoryError(MemoryErrorKind.cancelled),
      );
    });

    test('rejects successors that discard pending retry state', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(
        storage: storage,
      ).extractionCheckpointRepository;
      final checkpoint = _checkpoint(
        processed: const <String>['s1'],
        pending: const <String>['s2'],
        lastActivityMicros: 2,
        updatedAtMicros: 2,
      );
      await repository.save(
        checkpoint,
        expectedRevision: 0,
        cancellation: open,
      );
      final lossy = _checkpoint(
        revision: 1,
        processed: const <String>['s1'],
        pending: const <String>[],
        lastActivityMicros: 3,
        updatedAtMicros: 3,
      );
      await expectLater(
        repository.save(lossy, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('sanitizes corrupt checkpoint payloads', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(
        storage: storage,
      ).extractionCheckpointRepository;
      final checkpoint = _checkpoint();
      await repository.save(
        checkpoint,
        expectedRevision: 0,
        cancellation: open,
      );
      const codec = MemoryJsonlEnvelopeCodec();
      storage.replaceText(
        const MemoryJsonlKeyCodec().encode(
          MemoryJsonlStream.extractionState,
          'session-1',
        ),
        codec.encodeLine(
          MemoryJsonlEnvelope(
            stream: MemoryJsonlStream.extractionState,
            recordId: 'session-1',
            sequence: 0,
            operation: MemoryJsonlOperation.upsert,
            expectedRevision: 0,
            recordRevision: 0,
            record: const <String, Object?>{'not': 'a checkpoint'},
          ),
        ),
      );
      await expectLater(
        repository.load(checkpoint.sessionId, cancellation: open),
        _memoryError(MemoryErrorKind.persistence),
      );
    });

    test('keeps extraction state independent from entry streams', () async {
      final storage = FakeMemoryJsonlStorage();
      final stack = MemoryJsonlStack(storage: storage);
      final entry = workingEntry(id: 'session-1');
      final checkpoint = _checkpoint(sessionId: 'session-1');
      await stack.workingRepository.save(
        entry,
        expectedRevision: 0,
        cancellation: open,
      );
      await stack.extractionCheckpointRepository.save(
        checkpoint,
        expectedRevision: 0,
        cancellation: open,
      );
      expect(
        await stack.workingRepository.load(entry.id, cancellation: open),
        entry,
      );
      expect(
        await stack.extractionCheckpointRepository.load(
          checkpoint.sessionId,
          cancellation: open,
        ),
        checkpoint,
      );
      expect(
        storage.keys.toSet(),
        hasLength(2),
        reason: 'entry and checkpoint must use distinct keys',
      );
    });
  });
}
