import '../../../core/agents/ids.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/memory/errors.dart';
import '../../../core/memory/extraction.dart';
import 'memory_jsonl_envelope.dart';
import 'memory_jsonl_store.dart';

/// Append/replay backed extraction-checkpoint repository.
final class JsonlMemoryExtractionCheckpointRepository
    implements MemoryExtractionCheckpointRepository {
  JsonlMemoryExtractionCheckpointRepository({
    required MemoryJsonlStore store,
    this.codec = const MemoryExtractionCheckpointCodec(),
  }) : _store = store;

  final MemoryExtractionCheckpointCodec codec;
  final MemoryJsonlStore _store;

  static const MemoryJsonlStream _stream = MemoryJsonlStream.extractionState;

  @override
  Future<MemoryExtractionCheckpoint?> load(
    AgentSessionId sessionId, {
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final result = await _store.read(
      stream: _stream,
      recordId: sessionId.value,
    );
    if (result == null || result.isTombstone || result.record == null) {
      return null;
    }
    final checkpoint = _decode(result.record!);
    if (checkpoint.sessionId != sessionId ||
        checkpoint.revision != result.recordRevision) {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    return checkpoint;
  }

  @override
  Future<void> save(
    MemoryExtractionCheckpoint checkpoint, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = await load(
      checkpoint.sessionId,
      cancellation: cancellation,
    );
    if (existing != null && checkpoint.revision == existing.revision + 1) {
      validateMemoryExtractionCheckpointTransition(existing, checkpoint);
    }
    await _store.save(
      stream: _stream,
      recordId: checkpoint.sessionId.value,
      expectedRevision: expectedRevision,
      recordRevision: checkpoint.revision,
      record: codec.encode(checkpoint),
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    AgentSessionId sessionId, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    _throwIfCancelled(cancellation);
    return _store.delete(
      stream: _stream,
      recordId: sessionId.value,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<List<MemoryExtractionCheckpoint>> list({
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final ids = await _store.listRecordIds(_stream);
    final checkpoints = <MemoryExtractionCheckpoint>[];
    for (final idValue in ids) {
      final checkpoint = await load(
        AgentSessionId(idValue),
        cancellation: cancellation,
      );
      if (checkpoint != null) {
        checkpoints.add(checkpoint);
      }
    }
    checkpoints.sort(
      (left, right) => left.sessionId.value.compareTo(right.sessionId.value),
    );
    return List<MemoryExtractionCheckpoint>.unmodifiable(checkpoints);
  }

  MemoryExtractionCheckpoint _decode(Object? json) {
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
