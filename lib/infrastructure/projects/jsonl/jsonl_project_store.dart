import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/llm/cancellation.dart';
import '../../../core/projects/catalog.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/names.dart';
import '../../../core/projects/record.dart';
import '../../../core/projects/repository.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_project_envelope.dart';
import 'jsonl_project_replay.dart';

final class JsonlProjectStore implements ProjectRepository, ProjectCatalog {
  JsonlProjectStore({
    required this.storage,
    this.recordCodec = const ProjectCodec(),
    this.envelopeCodec = const JsonlProjectEnvelopeCodec(),
    this.keyCodec = const JsonlProjectKeyCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits(),
       _coordinator = _JsonlStoreCoordinator() {
    replay = JsonlProjectReplay(
      envelopeCodec: envelopeCodec,
      recordCodec: recordCodec,
      limits: this.limits,
    );
  }

  final JsonlStreamStorage storage;
  final ProjectCodec recordCodec;
  final JsonlProjectEnvelopeCodec envelopeCodec;
  final JsonlProjectKeyCodec keyCodec;
  final JsonlStorageLimits limits;
  final _JsonlStoreCoordinator _coordinator;
  late final JsonlProjectReplay replay;

  @override
  Future<ProjectRecord?> load(ProjectId id) {
    return _coordinator.run(() async {
      final state = await _read(id, keyCodec.encode(id));
      return state?.record;
    });
  }

  @override
  Future<void> save(
    ProjectRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      await _assertUniqueName(record);
      final key = keyCodec.encode(record.id);
      final current = await _read(record.id, key);
      _throwIfCancelled(cancellation);
      if (current == null || current.sequence == null) {
        if (expectedRevision != 0 || record.revision != 0) {
          _throwConflict(record.id);
        }
      } else {
        if (current.isTombstone ||
            current.record == null ||
            current.recordRevision != expectedRevision ||
            record.revision != expectedRevision + 1) {
          _throwConflict(record.id);
        }
      }

      final sequence = current?.sequence == null ? 0 : current!.sequence! + 1;
      final envelope = JsonlProjectEnvelope(
        projectId: record.id,
        sequence: sequence,
        operation: JsonlProjectOperation.upsert,
        expectedRevision: expectedRevision,
        recordRevision: record.revision,
        record: recordCodec.encode(record),
      );
      final successor = _append(current?.validPrefix ?? Uint8List(0), envelope);
      _throwIfCancelled(cancellation);
      await _publish(key, successor);
      await _cleanup(key);
    });
  }

  @override
  Future<void> delete(
    ProjectId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final key = keyCodec.encode(id);
      final current = await _read(id, key);
      _throwIfCancelled(cancellation);
      if (current == null ||
          current.sequence == null ||
          current.isTombstone ||
          current.record == null ||
          current.recordRevision != expectedRevision) {
        _throwConflict(id);
      }
      final envelope = JsonlProjectEnvelope(
        projectId: id,
        sequence: current.sequence! + 1,
        operation: JsonlProjectOperation.delete,
        expectedRevision: expectedRevision,
        recordRevision: expectedRevision,
      );
      final tombstone = _encode(envelope);
      _throwIfCancelled(cancellation);
      await _publish(key, tombstone);
      await _cleanup(key);
    });
  }

  @override
  Future<ProjectCatalogSnapshot> list() {
    return _coordinator.run(() async {
      final List<String> listed;
      try {
        listed = await storage.listKeys();
      } on Object {
        throw ProjectException(sanitizedProjectPersistenceError());
      }
      final keys = listed.toSet().toList()..sort();
      final available = <ProjectSummary>[];
      final issues = <ProjectCatalogIssue>[];
      for (final key in keys) {
        ProjectId? id;
        try {
          id = keyCodec.decode(key);
          final state = await _read(id, key);
          if (state?.record != null && !state!.isTombstone) {
            available.add(summarizeProject(state.record!));
          }
        } on Object {
          issues.add(
            ProjectCatalogIssue(
              id: id,
              reason: sanitizedProjectPersistenceError(),
            ),
          );
        }
        await _cleanup(key);
      }
      available.sort(compareProjectSummaries);
      return ProjectCatalogSnapshot(available: available, issues: issues);
    });
  }

  Future<void> _assertUniqueName(ProjectRecord record) async {
    final snapshot = await _listUnlocked();
    final key = projectNameCollisionKey(record.name);
    for (final summary in snapshot.available) {
      if (summary.id == record.id) {
        continue;
      }
      if (projectNameCollisionKey(summary.name) == key) {
        throw ProjectException(sanitizedProjectCollisionError());
      }
    }
  }

  Future<ProjectCatalogSnapshot> _listUnlocked() async {
    final List<String> listed;
    try {
      listed = await storage.listKeys();
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    final keys = listed.toSet().toList()..sort();
    final available = <ProjectSummary>[];
    for (final key in keys) {
      try {
        final id = keyCodec.decode(key);
        final state = await _read(id, key);
        if (state?.record != null && !state!.isTombstone) {
          available.add(summarizeProject(state.record!));
        }
      } on Object {
        // Name uniqueness ignores unreadable neighbors.
      }
    }
    return ProjectCatalogSnapshot(available: available);
  }

  Future<JsonlProjectReplayResult?> _read(ProjectId id, String key) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(key);
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    if (chunks == null) {
      return null;
    }
    try {
      return await replay.replay(id, chunks);
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
  }

  Uint8List _append(List<int> prefix, JsonlProjectEnvelope envelope) {
    final line = _encode(envelope);
    final builder = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(line);
    final value = builder.takeBytes();
    if (value.length > limits.maxStreamBytes) {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    return value;
  }

  Uint8List _encode(JsonlProjectEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    if (bytes.length - 1 > limits.maxEntryBytes ||
        bytes.length > limits.maxStreamBytes) {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    return bytes;
  }

  Future<void> _publish(String key, List<int> contents) async {
    try {
      await storage.publish(key, List<int>.unmodifiable(contents));
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
  }

  Future<void> _cleanup(String key) async {
    try {
      await storage.cleanup(key);
    } on Object {
      // Cleanup is best effort after the active generation is selected.
    }
  }
}

final class _JsonlStoreCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        released.complete();
      }
    }();
  }
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throw _cancelledException();
  }
}

ProjectException _cancelledException() => ProjectException(
  ProjectError(kind: ProjectErrorKind.cancelled, message: 'cancelled'),
);

Never _throwConflict(ProjectId id) {
  throwProject(
    ProjectErrorKind.conflict,
    'Project ${id.value} does not match the expected revision.',
  );
}
