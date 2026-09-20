import '../agents/ids.dart';
import '../projects/ids.dart';
import 'entry.dart';
import 'ids.dart';
import 'extraction.dart';

/// A full automatic extraction window of completed user/assistant messages.
const memoryExtractionWindowSize = 40;

/// Overlap retained between consecutive automatic windows.
const memoryExtractionOverlap = 2;

/// Checkpoint advance after a full automatic window.
const memoryExtractionAdvance =
    memoryExtractionWindowSize - memoryExtractionOverlap;

/// Foreground idle debounce after the last completed response.
const memoryExtractionIdleFlush = Duration(minutes: 30);

enum MemoryTranscriptRole { user, assistant }

/// One completed transcript message offered to the extractor.
final class MemoryExtractionSource {
  MemoryExtractionSource({
    required this.id,
    required this.role,
    required this.text,
  });

  final MemorySourceId id;
  final MemoryTranscriptRole role;
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryExtractionSource &&
          other.id == id &&
          other.role == role &&
          other.text == text;

  @override
  int get hashCode => Object.hash(id, role, text);
}

/// Deterministic extractor input: the current window plus a bounded set of
/// active records. It never carries the raw transcript or continuation state.
final class MemoryExtractionInput {
  MemoryExtractionInput({
    required this.projectId,
    required List<MemoryExtractionSource> sources,
    List<MemoryEntry> activeEntries = const <MemoryEntry>[],
  }) : sources = List<MemoryExtractionSource>.unmodifiable(
         List<MemoryExtractionSource>.from(sources),
       ),
       activeEntries = List<MemoryEntry>.unmodifiable(
         List<MemoryEntry>.from(activeEntries),
       );

  final ProjectId projectId;
  final List<MemoryExtractionSource> sources;
  final List<MemoryEntry> activeEntries;
}

/// The next batch to extract and how far the checkpoint may advance.
final class MemoryExtractionPlan {
  MemoryExtractionPlan({
    required List<MemorySourceId> batchSourceIds,
    required this.advanceCount,
    required this.fullWindow,
  }) : batchSourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(batchSourceIds),
       ) {
    if (advanceCount < 0 || advanceCount > batchSourceIds.length) {
      throw ArgumentError.value(
        advanceCount,
        'advanceCount',
        'Advance must fit the batch.',
      );
    }
  }

  final List<MemorySourceId> batchSourceIds;
  final int advanceCount;
  final bool fullWindow;
}

/// Decides the next extraction batch.
///
/// A forced (manual or idle) flush consumes every pending source. An automatic
/// flush consumes a full window but advances by [advance] so the trailing
/// [memoryExtractionOverlap] messages remain for the next window.
MemoryExtractionPlan? planMemoryExtraction({
  required List<MemorySourceId> pendingSourceIds,
  required bool force,
  int windowSize = memoryExtractionWindowSize,
  int advance = memoryExtractionAdvance,
}) {
  if (pendingSourceIds.isEmpty) {
    return null;
  }
  if (force) {
    return MemoryExtractionPlan(
      batchSourceIds: pendingSourceIds,
      advanceCount: pendingSourceIds.length,
      fullWindow: false,
    );
  }
  if (pendingSourceIds.length < windowSize) {
    return null;
  }
  return MemoryExtractionPlan(
    batchSourceIds: pendingSourceIds.take(windowSize).toList(growable: false),
    advanceCount: advance,
    fullWindow: true,
  );
}

/// Appends newly completed source identities to a checkpoint's pending set.
MemoryExtractionCheckpoint recordMemoryExtractionActivity({
  required AgentSessionId sessionId,
  required MemoryExtractionCheckpoint? previous,
  required List<MemorySourceId> completedSourceIds,
  required int nowMicros,
}) {
  if (previous == null) {
    return MemoryExtractionCheckpoint(
      sessionId: sessionId,
      revision: 0,
      processedSourceIds: const <MemorySourceId>[],
      pendingSourceIds: _uniqueOrdered(completedSourceIds),
      lastActivityMicros: nowMicros,
      createdAtMicros: nowMicros,
      updatedAtMicros: nowMicros,
    );
  }
  final known = <String>{
    for (final source in previous.processedSourceIds) source.value,
    for (final source in previous.pendingSourceIds) source.value,
  };
  final pending = <MemorySourceId>[...previous.pendingSourceIds];
  var changed = false;
  for (final source in completedSourceIds) {
    if (known.add(source.value)) {
      pending.add(source);
      changed = true;
    }
  }
  final updatedAtMicros = _atLeast(nowMicros, previous.updatedAtMicros);
  final lastActivityMicros = _atLeast(nowMicros, previous.lastActivityMicros);
  if (!changed && updatedAtMicros == previous.updatedAtMicros) {
    return previous;
  }
  return MemoryExtractionCheckpoint(
    sessionId: previous.sessionId,
    revision: previous.revision + 1,
    processedSourceIds: previous.processedSourceIds,
    pendingSourceIds: pending,
    lastActivityMicros: lastActivityMicros,
    createdAtMicros: previous.createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    lastFlushMicros: previous.lastFlushMicros,
  );
}

/// Advances a checkpoint after a successful extraction.
MemoryExtractionCheckpoint advanceMemoryExtractionCheckpoint({
  required MemoryExtractionCheckpoint previous,
  required MemoryExtractionPlan plan,
  required int nowMicros,
}) {
  final advanced = <String>{
    for (final source in plan.batchSourceIds.take(plan.advanceCount))
      source.value,
  };
  final processed = _uniqueOrdered(<MemorySourceId>[
    ...previous.processedSourceIds,
    ...plan.batchSourceIds.take(plan.advanceCount),
  ]);
  final pending = previous.pendingSourceIds
      .where((source) => !advanced.contains(source.value))
      .toList(growable: false);
  final updatedAtMicros = _atLeast(nowMicros, previous.updatedAtMicros);
  final lastActivityMicros = _atLeast(nowMicros, previous.lastActivityMicros);
  final lastFlushMicros = _atLeast(nowMicros, previous.lastFlushMicros ?? 0);
  final next = MemoryExtractionCheckpoint(
    sessionId: previous.sessionId,
    revision: previous.revision + 1,
    processedSourceIds: processed,
    pendingSourceIds: pending,
    lastActivityMicros: lastActivityMicros,
    createdAtMicros: previous.createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    lastFlushMicros: lastFlushMicros,
  );
  validateMemoryExtractionCheckpointTransition(previous, next);
  return next;
}

List<MemorySourceId> _uniqueOrdered(List<MemorySourceId> values) {
  final seen = <String>{};
  final result = <MemorySourceId>[];
  for (final value in values) {
    if (seen.add(value.value)) {
      result.add(value);
    }
  }
  return result;
}

int _atLeast(int value, int floor) => value < floor ? floor : value;
