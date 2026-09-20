import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

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
  group('MemoryExtractionCheckpoint', () {
    test('exposes pending state', () {
      expect(_checkpoint().hasPending, isTrue);
      expect(_checkpoint(pending: const <String>[]).hasPending, isFalse);
    });

    test('rejects overlapping and non-monotonic state', () {
      expect(
        () => _checkpoint(
          processed: const <String>['s1'],
          pending: const <String>['s1'],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(
          lastActivityMicros: 5,
          createdAtMicros: 1,
          updatedAtMicros: 2,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(createdAtMicros: 3, updatedAtMicros: 2),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(
          lastFlushMicros: 9,
          createdAtMicros: 1,
          updatedAtMicros: 2,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(processed: const <String>['s1', 's1']),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(revision: -1),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _checkpoint(lastFlushMicros: -1),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('round-trips through JSON', () {
      final checkpoint = _checkpoint(
        revision: 2,
        processed: const <String>['s1', 's2'],
        pending: const <String>['s3'],
        lastActivityMicros: 5,
        createdAtMicros: 1,
        updatedAtMicros: 6,
        lastFlushMicros: 4,
      );
      const codec = MemoryExtractionCheckpointCodec();
      expect(
        checkpoint.toJson()['version'],
        MemoryExtractionCheckpoint.currentJsonVersion,
      );
      expect(codec.decode(codec.encode(checkpoint)), checkpoint);
    });

    test('rejects unknown JSON fields', () {
      const codec = MemoryExtractionCheckpointCodec();
      final json = Map<String, Object?>.from(codec.encode(_checkpoint()))
        ..['extra'] = 1;
      expect(
        () => codec.decode(json),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('is immutable and value-equal', () {
      final checkpoint = _checkpoint();
      expect(
        () => checkpoint.processedSourceIds.add(MemorySourceId('s2')),
        throwsUnsupportedError,
      );
      expect(_checkpoint(), _checkpoint());
      expect(_checkpoint().hashCode, _checkpoint().hashCode);
      expect(_checkpoint(), isNot(_checkpoint(sessionId: 'session-2')));
    });

    test('transition preserves retry state and monotonic progress', () {
      final previous = _checkpoint(
        processed: const <String>['s1'],
        pending: const <String>['s2'],
        lastActivityMicros: 2,
        updatedAtMicros: 2,
      );
      final processed = _checkpoint(
        revision: 1,
        processed: const <String>['s1', 's2'],
        pending: const <String>['s3'],
        lastActivityMicros: 3,
        updatedAtMicros: 3,
        lastFlushMicros: 3,
      );
      expect(
        () => validateMemoryExtractionCheckpointTransition(previous, processed),
        returnsNormally,
      );
      expect(
        () => validateMemoryExtractionCheckpointTransition(
          previous,
          _checkpoint(
            revision: 1,
            processed: const <String>['s1'],
            pending: const <String>[],
            lastActivityMicros: 3,
            updatedAtMicros: 3,
          ),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });
}
