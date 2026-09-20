import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

List<MemorySourceId> _ids(int count, {String prefix = 's'}) =>
    List<MemorySourceId>.generate(
      count,
      (index) => MemorySourceId('$prefix$index'),
    );

MemoryExtractionCheckpoint _checkpoint({
  List<String> processed = const <String>[],
  List<String> pending = const <String>[],
  int revision = 0,
  int lastActivityMicros = 1,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
  int? lastFlushMicros,
}) {
  return MemoryExtractionCheckpoint(
    sessionId: AgentSessionId('session-1'),
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
  group('memory extraction window policy', () {
    test('waits for a full window unless forced', () {
      expect(
        planMemoryExtraction(pendingSourceIds: _ids(39), force: false),
        isNull,
      );
      final plan = planMemoryExtraction(
        pendingSourceIds: _ids(40),
        force: false,
      );
      expect(plan, isNotNull);
      expect(plan!.batchSourceIds, hasLength(40));
      expect(plan.advanceCount, memoryExtractionAdvance);
      expect(plan.advanceCount, 38);
      expect(memoryExtractionOverlap, 2);
      expect(plan.fullWindow, isTrue);
    });

    test('forced flush consumes every pending source', () {
      final plan = planMemoryExtraction(pendingSourceIds: _ids(3), force: true);
      expect(plan!.batchSourceIds, hasLength(3));
      expect(plan.advanceCount, 3);
      expect(plan.fullWindow, isFalse);
      expect(
        planMemoryExtraction(pendingSourceIds: const [], force: true),
        isNull,
      );
    });
  });

  group('checkpoint activity recording', () {
    test('creates then appends only unseen sources', () {
      final first = recordMemoryExtractionActivity(
        sessionId: AgentSessionId('session-1'),
        previous: null,
        completedSourceIds: _ids(2),
        nowMicros: 5,
      );
      expect(first.revision, 0);
      expect(first.pendingSourceIds, hasLength(2));
      expect(first.processedSourceIds, isEmpty);
      expect(first.lastActivityMicros, 5);

      final appended = recordMemoryExtractionActivity(
        sessionId: AgentSessionId('session-1'),
        previous: first,
        completedSourceIds: <MemorySourceId>[..._ids(2), MemorySourceId('s2')],
        nowMicros: 9,
      );
      expect(appended.revision, 1);
      expect(appended.pendingSourceIds.map((id) => id.value), <String>[
        's0',
        's1',
        's2',
      ]);
      expect(appended.createdAtMicros, 5);

      final idempotent = recordMemoryExtractionActivity(
        sessionId: AgentSessionId('session-1'),
        previous: appended,
        completedSourceIds: <MemorySourceId>[..._ids(2), MemorySourceId('s2')],
        nowMicros: 9,
      );
      expect(identical(idempotent, appended), isTrue);
    });
  });

  group('checkpoint advance', () {
    test('keeps a two-message overlap after a full window', () {
      final previous = _checkpoint(
        pending: _ids(40).map((id) => id.value).toList(),
      );
      final plan = planMemoryExtraction(
        pendingSourceIds: _ids(40),
        force: false,
      )!;
      final next = advanceMemoryExtractionCheckpoint(
        previous: previous,
        plan: plan,
        nowMicros: 10,
      );
      expect(next.processedSourceIds, hasLength(38));
      expect(next.pendingSourceIds.map((id) => id.value), <String>[
        's38',
        's39',
      ]);
      expect(next.lastFlushMicros, 10);
      expect(next.revision, previous.revision + 1);
    });

    test('forced advance consumes all pending sources', () {
      final previous = _checkpoint(pending: <String>['a', 'b']);
      final plan = planMemoryExtraction(
        pendingSourceIds: <MemorySourceId>[
          MemorySourceId('a'),
          MemorySourceId('b'),
        ],
        force: true,
      )!;
      final next = advanceMemoryExtractionCheckpoint(
        previous: previous,
        plan: plan,
        nowMicros: 2,
      );
      expect(next.processedSourceIds.map((id) => id.value), <String>['a', 'b']);
      expect(next.pendingSourceIds, isEmpty);
    });

    test('preserves processed identities and monotonic timestamps', () {
      final previous = _checkpoint(
        processed: <String>['old'],
        pending: <String>['s0', 's1'],
        revision: 3,
        lastActivityMicros: 50,
        createdAtMicros: 1,
        updatedAtMicros: 60,
        lastFlushMicros: 40,
      );
      final plan = planMemoryExtraction(
        pendingSourceIds: <MemorySourceId>[
          MemorySourceId('s0'),
          MemorySourceId('s1'),
        ],
        force: true,
      )!;
      final next = advanceMemoryExtractionCheckpoint(
        previous: previous,
        plan: plan,
        nowMicros: 55,
      );
      expect(next.processedSourceIds.map((id) => id.value), <String>[
        'old',
        's0',
        's1',
      ]);
      expect(next.updatedAtMicros, 60);
      expect(next.lastActivityMicros, 55);
      expect(next.lastFlushMicros, 55);
    });

    test('rejects dropping pending retry state', () {
      final previous = _checkpoint(pending: <String>['s0']);
      final next = _checkpoint(processed: <String>['s1'], pending: const []);
      expect(
        () => validateMemoryExtractionCheckpointTransition(previous, next),
        throwsA(isA<MemoryException>()),
      );
    });
  });
}
