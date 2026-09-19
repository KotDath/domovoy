import '../llm/cancellation.dart';
import 'catalog.dart';
import 'errors.dart';
import 'ids.dart';
import 'names.dart';
import 'record.dart';

abstract interface class ProjectRepository {
  Future<ProjectRecord?> load(ProjectId id);

  Future<void> save(
    ProjectRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    ProjectId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

final class InMemoryProjectRepository
    implements ProjectRepository, ProjectCatalog {
  InMemoryProjectRepository({this.codec = const ProjectCodec()});

  final ProjectCodec codec;
  final Map<String, Object?> _payloads = <String, Object?>{};
  final Map<String, int> _tombstones = <String, int>{};

  void replacePayload(ProjectId id, Object json) {
    _payloads[id.value] = json;
  }

  bool get hasTombstoneForTest => _tombstones.isNotEmpty;

  @override
  Future<ProjectRecord?> load(ProjectId id) async {
    final raw = _payloads[id.value];
    if (raw == null) {
      return null;
    }
    return codec.decode(raw);
  }

  @override
  Future<void> save(
    ProjectRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    if (_tombstones.containsKey(record.id.value)) {
      throwProject(
        ProjectErrorKind.conflict,
        'Project ${record.id.value} has been deleted.',
      );
    }
    _assertUniqueName(record);
    final existingRaw = _payloads[record.id.value];
    final existing = existingRaw == null ? null : codec.decode(existingRaw);
    if (existing == null) {
      if (expectedRevision != 0 || record.revision != 0) {
        throwProject(
          ProjectErrorKind.conflict,
          'Project ${record.id.value} does not match the expected revision.',
        );
      }
      _payloads[record.id.value] = codec.encode(record);
      return;
    }
    if (existing.revision != expectedRevision ||
        record.revision != expectedRevision + 1) {
      throwProject(
        ProjectErrorKind.conflict,
        'Project ${record.id.value} was updated concurrently.',
      );
    }
    _payloads[record.id.value] = codec.encode(record);
  }

  @override
  Future<void> delete(
    ProjectId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    final raw = _payloads[id.value];
    if (raw == null || _tombstones.containsKey(id.value)) {
      throwProject(
        ProjectErrorKind.conflict,
        'Project ${id.value} does not match the expected revision.',
      );
    }
    final existing = codec.decode(raw);
    if (existing.revision != expectedRevision) {
      throwProject(
        ProjectErrorKind.conflict,
        'Project ${id.value} was updated concurrently.',
      );
    }
    _payloads.remove(id.value);
    _tombstones[id.value] = existing.revision;
  }

  @override
  Future<ProjectCatalogSnapshot> list() async {
    final available = <ProjectSummary>[];
    final issues = <ProjectCatalogIssue>[];
    for (final entry in _payloads.entries) {
      try {
        final record = codec.decode(entry.value);
        if (record.id.value != entry.key) {
          throw const FormatException('identity mismatch');
        }
        available.add(summarizeProject(record));
      } on Object {
        ProjectId? id;
        try {
          id = ProjectId(entry.key);
        } on Object {
          id = null;
        }
        issues.add(
          ProjectCatalogIssue(
            id: id,
            reason: sanitizedProjectPersistenceError(),
          ),
        );
      }
    }
    available.sort(compareProjectSummaries);
    return ProjectCatalogSnapshot(available: available, issues: issues);
  }

  void _assertUniqueName(ProjectRecord record) {
    final key = projectNameCollisionKey(record.name);
    for (final entry in _payloads.entries) {
      if (entry.key == record.id.value) {
        continue;
      }
      try {
        final other = codec.decode(entry.value);
        if (other.collisionKey == key) {
          throw ProjectException(sanitizedProjectCollisionError());
        }
      } on ProjectException {
        rethrow;
      } on Object {
        // Corrupt neighbors are catalog issues, not name-collision winners.
      }
    }
  }
}
