import '../agents/ids.dart';
import '../llm/cancellation.dart';
import '../llm/json.dart';
import 'errors.dart';
import 'ids.dart';
import 'validation.dart';

/// Durable scheduling state for one session's memory extraction.
///
/// The checkpoint is append/replay persisted independently of entries and
/// candidates. It records which source messages have been processed, which are
/// pending, and the last observed activity so an interrupted or backgrounded
/// extractor can resume without reprocessing source identities.
final class MemoryExtractionCheckpoint {
  MemoryExtractionCheckpoint({
    required this.sessionId,
    required this.revision,
    required List<MemorySourceId> processedSourceIds,
    required List<MemorySourceId> pendingSourceIds,
    required this.lastActivityMicros,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    this.lastFlushMicros,
  }) : processedSourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(processedSourceIds),
       ),
       pendingSourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(pendingSourceIds),
       ) {
    if (revision < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Checkpoint revision must be non-negative.',
      );
    }
    if (lastActivityMicros < 0 ||
        createdAtMicros < 0 ||
        updatedAtMicros < 0 ||
        (lastFlushMicros != null && lastFlushMicros! < 0)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Checkpoint timestamps must be non-negative.',
      );
    }
    if (updatedAtMicros < createdAtMicros ||
        lastActivityMicros > updatedAtMicros ||
        (lastFlushMicros != null && lastFlushMicros! > updatedAtMicros)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Checkpoint timestamps must be monotonic.',
      );
    }
    validateMemorySourceIds(this.processedSourceIds);
    validateMemorySourceIds(this.pendingSourceIds);
    final processed = this.processedSourceIds
        .map((source) => source.value)
        .toSet();
    for (final pending in this.pendingSourceIds) {
      if (processed.contains(pending.value)) {
        throwMemory(
          MemoryErrorKind.configuration,
          'A source identity cannot be both processed and pending.',
        );
      }
    }
  }

  factory MemoryExtractionCheckpoint.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(
        json,
        type: jsonType,
        version: currentJsonVersion,
      );
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'sessionId',
        'revision',
        'processedSourceIds',
        'pendingSourceIds',
        'lastActivityMicros',
        'createdAtMicros',
        'updatedAtMicros',
      };
      if (map['lastFlushMicros'] != null) {
        expected.add('lastFlushMicros');
      }
      _expectKeys(map, expected);
      return MemoryExtractionCheckpoint(
        sessionId: AgentSessionId.fromJson(map['sessionId']),
        revision: requireInt(map, 'revision'),
        processedSourceIds: requireList(
          map,
          'processedSourceIds',
        ).map(MemorySourceId.fromJson).toList(growable: false),
        pendingSourceIds: requireList(
          map,
          'pendingSourceIds',
        ).map(MemorySourceId.fromJson).toList(growable: false),
        lastActivityMicros: requireInt(map, 'lastActivityMicros'),
        createdAtMicros: requireInt(map, 'createdAtMicros'),
        updatedAtMicros: requireInt(map, 'updatedAtMicros'),
        lastFlushMicros: map['lastFlushMicros'] == null
            ? null
            : requireInt(map, 'lastFlushMicros'),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.extraction_checkpoint';
  static const currentJsonVersion = 1;

  final AgentSessionId sessionId;
  final int revision;
  final List<MemorySourceId> processedSourceIds;
  final List<MemorySourceId> pendingSourceIds;
  final int lastActivityMicros;
  final int createdAtMicros;
  final int updatedAtMicros;
  final int? lastFlushMicros;

  bool get hasPending => pendingSourceIds.isNotEmpty;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: currentJsonVersion,
    fields: <String, Object?>{
      'sessionId': sessionId.toJson(),
      'revision': revision,
      'processedSourceIds': processedSourceIds
          .map((source) => source.toJson())
          .toList(),
      'pendingSourceIds': pendingSourceIds
          .map((source) => source.toJson())
          .toList(),
      'lastActivityMicros': lastActivityMicros,
      'createdAtMicros': createdAtMicros,
      'updatedAtMicros': updatedAtMicros,
      if (lastFlushMicros != null) 'lastFlushMicros': lastFlushMicros,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryExtractionCheckpoint &&
          other.sessionId == sessionId &&
          other.revision == revision &&
          listEquals(other.processedSourceIds, processedSourceIds) &&
          listEquals(other.pendingSourceIds, pendingSourceIds) &&
          other.lastActivityMicros == lastActivityMicros &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.lastFlushMicros == lastFlushMicros;

  @override
  int get hashCode => Object.hash(
    sessionId,
    revision,
    Object.hashAll(processedSourceIds),
    Object.hashAll(pendingSourceIds),
    lastActivityMicros,
    createdAtMicros,
    updatedAtMicros,
    lastFlushMicros,
  );

  @override
  String toString() =>
      'MemoryExtractionCheckpoint(${sessionId.value}, rev=$revision, '
      'processed=${processedSourceIds.length}, pending=${pendingSourceIds.length})';
}

/// Validates a durable checkpoint successor without allowing retry state to be
/// lost. Pending sources may disappear only after becoming processed.
void validateMemoryExtractionCheckpointTransition(
  MemoryExtractionCheckpoint previous,
  MemoryExtractionCheckpoint next,
) {
  if (previous.sessionId != next.sessionId ||
      previous.createdAtMicros != next.createdAtMicros) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A checkpoint transition must preserve session identity and creation time.',
    );
  }
  if (next.revision != previous.revision + 1) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A checkpoint transition must advance the revision by exactly one.',
    );
  }
  if (next.updatedAtMicros < previous.updatedAtMicros ||
      next.lastActivityMicros < previous.lastActivityMicros ||
      (previous.lastFlushMicros != null &&
          (next.lastFlushMicros == null ||
              next.lastFlushMicros! < previous.lastFlushMicros!))) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Checkpoint timestamps must not move backwards.',
    );
  }
  final nextProcessed = next.processedSourceIds
      .map((source) => source.value)
      .toSet();
  if (!previous.processedSourceIds.every(
    (source) => nextProcessed.contains(source.value),
  )) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A checkpoint transition must preserve processed source identities.',
    );
  }
  final nextPending = next.pendingSourceIds
      .map((source) => source.value)
      .toSet();
  for (final source in previous.pendingSourceIds) {
    if (!nextPending.contains(source.value) &&
        !nextProcessed.contains(source.value)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A pending source may be removed only after it is processed.',
      );
    }
  }
}

/// Persistence contract for the independent extraction-state namespace.
abstract interface class MemoryExtractionCheckpointRepository {
  Future<MemoryExtractionCheckpoint?> load(
    AgentSessionId sessionId, {
    required CancellationToken cancellation,
  });

  Future<void> save(
    MemoryExtractionCheckpoint checkpoint, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    AgentSessionId sessionId, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<List<MemoryExtractionCheckpoint>> list({
    required CancellationToken cancellation,
  });
}

void _expectKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Unexpected memory extraction checkpoint fields.',
    );
  }
}

final class MemoryExtractionCheckpointCodec {
  const MemoryExtractionCheckpointCodec();

  Map<String, Object?> encode(MemoryExtractionCheckpoint checkpoint) =>
      freezeJsonMap(checkpoint.toJson());

  MemoryExtractionCheckpoint decode(Object? json) =>
      MemoryExtractionCheckpoint.fromJson(json);
}
