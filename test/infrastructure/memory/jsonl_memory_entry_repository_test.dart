import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';
import '../../support/memory_jsonl_storage.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

String _keyFor(MemoryJsonlStream stream, String recordId) =>
    const MemoryJsonlKeyCodec().encode(stream, recordId);

Future<String> _readText(FakeMemoryJsonlStorage storage, String key) async {
  final stream = await storage.read(key);
  if (stream == null) return '';
  final chunks = await stream.toList();
  return utf8.decode(<int>[for (final chunk in chunks) ...chunk]);
}

void main() {
  final open = CancellationSource().token;

  group('JsonlMemoryEntryRepository', () {
    test('round-trips and restores across stack reconstruction', () async {
      final storage = FakeMemoryJsonlStorage();
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      final first = MemoryJsonlStack(storage: storage).workingRepository;
      await first.save(entry, expectedRevision: 0, cancellation: open);
      expect(await first.load(entry.id, cancellation: open), entry);
      expect(await first.list(cancellation: open), <MemoryEntry>[entry]);

      final restarted = MemoryJsonlStack(storage: storage).workingRepository;
      expect(await restarted.load(entry.id, cancellation: open), entry);
      expect(await restarted.list(cancellation: open), <MemoryEntry>[entry]);
    });

    test('enforces optimistic revisions and legal transitions', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).workingRepository;
      final entry = workingEntry(
        createdAtMicros: 1,
        updatedAtMicros: 1,
        sourceValues: const <String>['s1', 's2'],
      );
      await repository.save(entry, expectedRevision: 0, cancellation: open);
      final revised = entry.revise(
        content: 'Retrieval must be deterministic and auditable.',
        updatedAtMicros: 2,
      );
      await repository.save(revised, expectedRevision: 0, cancellation: open);
      await expectLater(
        repository.save(revised, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
      final dropped = workingEntry(
        revision: 2,
        createdAtMicros: 1,
        updatedAtMicros: 3,
        sourceValues: const <String>['s1'],
      );
      await expectLater(
        repository.save(dropped, expectedRevision: 1, cancellation: open),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test(
      'tombstones, lists forgotten records, and blocks resurrection',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final repository = MemoryJsonlStack(storage: storage).workingRepository;
        final entry = workingEntry();
        await repository.save(entry, expectedRevision: 0, cancellation: open);
        final forgotten = entry.forget(updatedAtMicros: 2);
        await repository.save(
          forgotten,
          expectedRevision: 0,
          cancellation: open,
        );
        expect(await repository.load(entry.id, cancellation: open), forgotten);
        expect(await repository.list(cancellation: open), isEmpty);
        expect(
          await repository.list(includeForgotten: true, cancellation: open),
          <MemoryEntry>[forgotten],
        );

        await repository.delete(
          forgotten.id,
          expectedRevision: 1,
          cancellation: open,
        );
        expect(await repository.load(entry.id, cancellation: open), isNull);
        await expectLater(
          repository.save(entry, expectedRevision: 0, cancellation: open),
          _memoryError(MemoryErrorKind.conflict),
        );
      },
    );

    test('rejects an entry from another layer', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).workingRepository;
      await expectLater(
        repository.save(
          longTermEntry(),
          expectedRevision: 0,
          cancellation: open,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('filters listing by project and honours cancellation', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).workingRepository;
      final one = workingEntry(id: 'a', project: 'p1');
      final two = workingEntry(id: 'b', project: 'p2');
      await repository.save(one, expectedRevision: 0, cancellation: open);
      await repository.save(two, expectedRevision: 0, cancellation: open);
      expect(
        await repository.list(projectId: one.projectId, cancellation: open),
        <MemoryEntry>[one],
      );
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        repository.load(one.id, cancellation: cancelled.token),
        _memoryError(MemoryErrorKind.cancelled),
      );
      await expectLater(
        repository.list(cancellation: cancelled.token),
        _memoryError(MemoryErrorKind.cancelled),
      );
    });

    test('isolates working and long-term namespaces', () async {
      final storage = FakeMemoryJsonlStorage();
      final stack = MemoryJsonlStack(storage: storage);
      final working = workingEntry(id: 'shared');
      final longTerm = longTermEntry(id: 'shared');
      await stack.workingRepository.save(
        working,
        expectedRevision: 0,
        cancellation: open,
      );
      await stack.longTermRepository.save(
        longTerm,
        expectedRevision: 0,
        cancellation: open,
      );
      expect(
        await stack.workingRepository.load(working.id, cancellation: open),
        working,
      );
      expect(
        await stack.longTermRepository.load(longTerm.id, cancellation: open),
        longTerm,
      );
      expect(
        await stack.workingRepository.list(cancellation: open),
        <MemoryEntry>[working],
      );
      expect(
        await stack.longTermRepository.list(cancellation: open),
        <MemoryEntry>[longTerm],
      );
    });

    test(
      'sanitizes corrupt payloads but keeps healthy namespaces readable',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final stack = MemoryJsonlStack(storage: storage);
        final working = workingEntry();
        final longTerm = longTermEntry();
        await stack.workingRepository.save(
          working,
          expectedRevision: 0,
          cancellation: open,
        );
        await stack.longTermRepository.save(
          longTerm,
          expectedRevision: 0,
          cancellation: open,
        );

        final workingKey = _keyFor(MemoryJsonlStream.working, working.id.value);
        const codec = MemoryJsonlEnvelopeCodec();
        storage.replaceText(
          workingKey,
          codec.encodeLine(
            MemoryJsonlEnvelope(
              stream: MemoryJsonlStream.working,
              recordId: working.id.value,
              sequence: 0,
              operation: MemoryJsonlOperation.upsert,
              expectedRevision: 0,
              recordRevision: 0,
              record: const <String, Object?>{'nope': true},
            ),
          ),
        );
        await expectLater(
          stack.workingRepository.load(working.id, cancellation: open),
          _memoryError(MemoryErrorKind.persistence),
        );
        // The independent long-term namespace is unaffected.
        expect(
          await stack.longTermRepository.load(longTerm.id, cancellation: open),
          longTerm,
        );
      },
    );

    test('repairs a truncated tail before the next append', () async {
      final storage = FakeMemoryJsonlStorage();
      final stack = MemoryJsonlStack(storage: storage);
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      await stack.workingRepository.save(
        entry,
        expectedRevision: 0,
        cancellation: open,
      );
      final key = _keyFor(MemoryJsonlStream.working, entry.id.value);
      storage.appendText(key, '{"partial"');
      expect(
        await stack.workingRepository.load(entry.id, cancellation: open),
        entry,
      );

      final revised = entry.revise(
        content: 'Retrieval must be deterministic and auditable.',
        updatedAtMicros: 2,
      );
      await stack.workingRepository.save(
        revised,
        expectedRevision: 0,
        cancellation: open,
      );
      expect(
        await stack.workingRepository.load(entry.id, cancellation: open),
        revised,
      );
      final text = await _readText(storage, key);
      expect(text, isNot(contains('partial')));
      expect(text.endsWith('\n'), isTrue);
    });

    test('sanitizes storage and listing failures', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).workingRepository;
      storage.failList = true;
      await expectLater(
        repository.list(cancellation: open),
        _memoryError(MemoryErrorKind.persistence),
      );
    });
  });
}
