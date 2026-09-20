import '../../../core/llm/cancellation.dart';
import '../../../core/memory/entry.dart';
import '../../../core/memory/enums.dart';
import '../../../core/memory/errors.dart';
import '../../../core/memory/ids.dart';
import '../../../core/memory/repository.dart';
import '../../../core/projects/ids.dart';
import 'memory_jsonl_envelope.dart';
import 'memory_jsonl_store.dart';

/// Append/replay backed working or long-term entry repository.
final class JsonlMemoryEntryRepository implements MemoryEntryRepository {
  JsonlMemoryEntryRepository({
    required this.layer,
    required MemoryJsonlStore store,
    this.codec = const MemoryEntryCodec(),
  }) : _store = store;

  @override
  final MemoryLayer layer;
  final MemoryEntryCodec codec;
  final MemoryJsonlStore _store;

  MemoryJsonlStream get _stream => switch (layer) {
    MemoryLayer.working => MemoryJsonlStream.working,
    MemoryLayer.longTerm => MemoryJsonlStream.longTerm,
  };

  @override
  Future<MemoryEntry?> load(
    MemoryEntryId id, {
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final result = await _store.read(stream: _stream, recordId: id.value);
    if (result == null || result.isTombstone || result.record == null) {
      return null;
    }
    final entry = _decode(result.record!);
    if (entry.id != id ||
        entry.layer != layer ||
        entry.revision != result.recordRevision) {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    return entry;
  }

  @override
  Future<void> save(
    MemoryEntry entry, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    if (entry.layer != layer) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Entry layer does not match the repository namespace.',
      );
    }
    final existing = await load(entry.id, cancellation: cancellation);
    if (existing != null && entry.revision == existing.revision + 1) {
      validateMemoryEntryTransition(existing, entry);
    }
    await _store.save(
      stream: _stream,
      recordId: entry.id.value,
      expectedRevision: expectedRevision,
      recordRevision: entry.revision,
      record: codec.encode(entry),
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    MemoryEntryId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    _throwIfCancelled(cancellation);
    return _store.delete(
      stream: _stream,
      recordId: id.value,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<List<MemoryEntry>> list({
    ProjectId? projectId,
    bool includeForgotten = false,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final ids = await _store.listRecordIds(_stream);
    final entries = <MemoryEntry>[];
    for (final idValue in ids) {
      final entry = await load(
        MemoryEntryId(idValue),
        cancellation: cancellation,
      );
      if (entry == null) {
        continue;
      }
      if (!includeForgotten && !entry.isActive) {
        continue;
      }
      if (projectId != null && entry.projectId != projectId) {
        continue;
      }
      entries.add(entry);
    }
    entries.sort((left, right) => left.id.value.compareTo(right.id.value));
    return List<MemoryEntry>.unmodifiable(entries);
  }

  MemoryEntry _decode(Object? json) {
    try {
      return codec.decode(json);
    } on Object {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
  }
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwMemory(MemoryErrorKind.cancelled, 'cancelled');
  }
}
