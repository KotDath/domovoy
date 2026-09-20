import '../../../core/llm/cancellation.dart';
import '../../../core/memory/candidate.dart';
import '../../../core/memory/enums.dart';
import '../../../core/memory/errors.dart';
import '../../../core/memory/ids.dart';
import '../../../core/memory/repository.dart';
import '../../../core/projects/ids.dart';
import 'memory_jsonl_envelope.dart';
import 'memory_jsonl_store.dart';

/// Append/replay backed candidate repository.
final class JsonlMemoryCandidateRepository
    implements MemoryCandidateRepository {
  JsonlMemoryCandidateRepository({
    required MemoryJsonlStore store,
    this.codec = const MemoryCandidateCodec(),
  }) : _store = store;

  final MemoryCandidateCodec codec;
  final MemoryJsonlStore _store;

  static const MemoryJsonlStream _stream = MemoryJsonlStream.candidate;

  @override
  Future<MemoryCandidate?> load(
    MemoryCandidateId id, {
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final result = await _store.read(stream: _stream, recordId: id.value);
    if (result == null || result.isTombstone || result.record == null) {
      return null;
    }
    final candidate = _decode(result.record!);
    if (candidate.id != id || candidate.revision != result.recordRevision) {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    return candidate;
  }

  @override
  Future<void> save(
    MemoryCandidate candidate, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = await load(candidate.id, cancellation: cancellation);
    if (existing != null && candidate.revision == existing.revision + 1) {
      validateMemoryCandidateTransition(existing, candidate);
    }
    await _store.save(
      stream: _stream,
      recordId: candidate.id.value,
      expectedRevision: expectedRevision,
      recordRevision: candidate.revision,
      record: codec.encode(candidate),
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    MemoryCandidateId id, {
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
  Future<List<MemoryCandidate>> list({
    MemoryCandidateStatus? status,
    ProjectId? projectId,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final ids = await _store.listRecordIds(_stream);
    final candidates = <MemoryCandidate>[];
    for (final idValue in ids) {
      final candidate = await load(
        MemoryCandidateId(idValue),
        cancellation: cancellation,
      );
      if (candidate == null) {
        continue;
      }
      if (status != null && candidate.status != status) {
        continue;
      }
      if (projectId != null && candidate.projectId != projectId) {
        continue;
      }
      candidates.add(candidate);
    }
    candidates.sort((left, right) => left.id.value.compareTo(right.id.value));
    return List<MemoryCandidate>.unmodifiable(candidates);
  }

  MemoryCandidate _decode(Object? json) {
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
