import '../llm/cancellation.dart';
import '../projects/ids.dart';
import 'candidate.dart';
import 'enums.dart';
import 'entry.dart';
import 'errors.dart';
import 'ids.dart';

/// Persistence contract for one memory entry namespace (working or long-term).
///
/// Implementations own atomic publication, replay validation, and tombstones.
/// Missing streams mean empty state; corrupt streams must surface a sanitized
/// persistence error instead of silently returning nothing.
abstract interface class MemoryEntryRepository {
  /// The layer this namespace stores. [MemoryEntry.layer] must match it.
  MemoryLayer get layer;

  Future<MemoryEntry?> load(
    MemoryEntryId id, {
    required CancellationToken cancellation,
  });

  Future<void> save(
    MemoryEntry entry, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    MemoryEntryId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<List<MemoryEntry>> list({
    ProjectId? projectId,
    bool includeForgotten = false,
    required CancellationToken cancellation,
  });
}

/// Persistence contract for the candidate namespace.
abstract interface class MemoryCandidateRepository {
  Future<MemoryCandidate?> load(
    MemoryCandidateId id, {
    required CancellationToken cancellation,
  });

  Future<void> save(
    MemoryCandidate candidate, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    MemoryCandidateId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<List<MemoryCandidate>> list({
    MemoryCandidateStatus? status,
    ProjectId? projectId,
    required CancellationToken cancellation,
  });
}

/// Bundles the independent working, long-term, and candidate namespaces.
final class MemoryRepositories {
  MemoryRepositories({
    required this.workingRepository,
    required this.longTermRepository,
    required this.candidateRepository,
  }) {
    if (workingRepository.layer != MemoryLayer.working) {
      throwMemory(
        MemoryErrorKind.configuration,
        'The working repository must declare the working layer.',
      );
    }
    if (longTermRepository.layer != MemoryLayer.longTerm) {
      throwMemory(
        MemoryErrorKind.configuration,
        'The long-term repository must declare the long-term layer.',
      );
    }
  }

  final MemoryEntryRepository workingRepository;
  final MemoryEntryRepository longTermRepository;
  final MemoryCandidateRepository candidateRepository;

  MemoryEntryRepository entryRepository(MemoryLayer layer) => switch (layer) {
    MemoryLayer.working => workingRepository,
    MemoryLayer.longTerm => longTermRepository,
  };
}

/// In-memory reference implementation used by domain tests and composition.
final class InMemoryMemoryEntryRepository implements MemoryEntryRepository {
  InMemoryMemoryEntryRepository({
    required this.layer,
    this.codec = const MemoryEntryCodec(),
  });

  @override
  final MemoryLayer layer;
  final MemoryEntryCodec codec;
  final Map<String, MemoryEntry> _entries = <String, MemoryEntry>{};
  final Map<String, int> _tombstones = <String, int>{};

  bool get hasTombstoneForTest => _tombstones.isNotEmpty;

  @override
  Future<MemoryEntry?> load(
    MemoryEntryId id, {
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    return _entries[id.value];
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
    if (_tombstones.containsKey(entry.id.value)) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory entry ${entry.id.value} has been forgotten.',
      );
    }
    final existing = _entries[entry.id.value];
    if (existing == null) {
      if (expectedRevision != 0 || entry.revision != 0) {
        throwMemory(
          MemoryErrorKind.conflict,
          'Memory entry ${entry.id.value} does not match the expected revision.',
        );
      }
      _entries[entry.id.value] = entry;
      return;
    }
    if (existing.revision != expectedRevision ||
        entry.revision != expectedRevision + 1) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory entry ${entry.id.value} was updated concurrently.',
      );
    }
    validateMemoryEntryTransition(existing, entry);
    _entries[entry.id.value] = entry;
  }

  @override
  Future<void> delete(
    MemoryEntryId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = _entries[id.value];
    if (existing == null || _tombstones.containsKey(id.value)) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory entry ${id.value} does not match the expected revision.',
      );
    }
    if (existing.revision != expectedRevision) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory entry ${id.value} was updated concurrently.',
      );
    }
    _entries.remove(id.value);
    _tombstones[id.value] = existing.revision;
  }

  @override
  Future<List<MemoryEntry>> list({
    ProjectId? projectId,
    bool includeForgotten = false,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final result =
        _entries.values
            .where((entry) => includeForgotten || entry.isActive)
            .where((entry) => projectId == null || entry.projectId == projectId)
            .toList()
          ..sort((left, right) => left.id.value.compareTo(right.id.value));
    return List<MemoryEntry>.unmodifiable(result);
  }
}

/// In-memory reference implementation used by domain tests and composition.
final class InMemoryMemoryCandidateRepository
    implements MemoryCandidateRepository {
  InMemoryMemoryCandidateRepository({
    this.codec = const MemoryCandidateCodec(),
  });

  final MemoryCandidateCodec codec;
  final Map<String, MemoryCandidate> _candidates = <String, MemoryCandidate>{};
  final Map<String, int> _tombstones = <String, int>{};

  @override
  Future<MemoryCandidate?> load(
    MemoryCandidateId id, {
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    return _candidates[id.value];
  }

  @override
  Future<void> save(
    MemoryCandidate candidate, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    if (_tombstones.containsKey(candidate.id.value)) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory candidate ${candidate.id.value} has been discarded.',
      );
    }
    final existing = _candidates[candidate.id.value];
    if (existing == null) {
      if (expectedRevision != 0 || candidate.revision != 0) {
        throwMemory(
          MemoryErrorKind.conflict,
          'Memory candidate ${candidate.id.value} does not match the expected '
          'revision.',
        );
      }
      _candidates[candidate.id.value] = candidate;
      return;
    }
    if (existing.revision != expectedRevision ||
        candidate.revision != expectedRevision + 1) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory candidate ${candidate.id.value} was updated concurrently.',
      );
    }
    validateMemoryCandidateTransition(existing, candidate);
    _candidates[candidate.id.value] = candidate;
  }

  @override
  Future<void> delete(
    MemoryCandidateId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = _candidates[id.value];
    if (existing == null || _tombstones.containsKey(id.value)) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory candidate ${id.value} does not match the expected revision.',
      );
    }
    if (existing.revision != expectedRevision) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Memory candidate ${id.value} was updated concurrently.',
      );
    }
    _candidates.remove(id.value);
    _tombstones[id.value] = existing.revision;
  }

  @override
  Future<List<MemoryCandidate>> list({
    MemoryCandidateStatus? status,
    ProjectId? projectId,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final result =
        _candidates.values
            .where((candidate) => status == null || candidate.status == status)
            .where(
              (candidate) =>
                  projectId == null || candidate.projectId == projectId,
            )
            .toList()
          ..sort((left, right) => left.id.value.compareTo(right.id.value));
    return List<MemoryCandidate>.unmodifiable(result);
  }
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwMemory(MemoryErrorKind.cancelled, 'cancelled');
  }
}
