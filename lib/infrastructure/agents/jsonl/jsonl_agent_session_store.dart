import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/agents/catalog.dart';
import '../../../core/agents/errors.dart';
import '../../../core/agents/ids.dart';
import '../../../core/agents/record.dart';
import '../../../core/agents/repository.dart';
import '../../../core/llm/cancellation.dart';
import 'jsonl_envelope.dart';
import 'jsonl_replay.dart';
import 'jsonl_stream_storage.dart';

final class JsonlAgentSessionStore
    implements AgentSessionRepository, AgentSessionCatalog {
  JsonlAgentSessionStore({
    required this.storage,
    this.recordCodec = const AgentSessionCodec(),
    this.envelopeCodec = const JsonlSessionEnvelopeCodec(),
    this.keyCodec = const JsonlSessionKeyCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits(),
       _coordinator = _JsonlStoreCoordinator() {
    replay = JsonlSessionReplay(
      envelopeCodec: envelopeCodec,
      recordCodec: recordCodec,
      limits: this.limits,
    );
  }

  final JsonlStreamStorage storage;
  final AgentSessionCodec recordCodec;
  final JsonlSessionEnvelopeCodec envelopeCodec;
  final JsonlSessionKeyCodec keyCodec;
  final JsonlStorageLimits limits;
  final _JsonlStoreCoordinator _coordinator;
  late final JsonlSessionReplay replay;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) {
    return _coordinator.run(() async {
      final state = await _read(id, keyCodec.encode(id));
      return state?.record;
    });
  }

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
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
      final envelope = JsonlSessionEnvelope(
        sessionId: record.id,
        sequence: sequence,
        operation: JsonlSessionOperation.upsert,
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
    AgentSessionId id, {
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
      final envelope = JsonlSessionEnvelope(
        sessionId: id,
        sequence: current.sequence! + 1,
        operation: JsonlSessionOperation.delete,
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
  Future<AgentSessionCatalogSnapshot> list() {
    return _coordinator.run(() async {
      final List<String> listed;
      try {
        listed = await storage.listKeys();
      } on Object {
        throw AgentException(sanitizedPersistenceError());
      }
      final keys = listed.toSet().toList()..sort();
      final available = <AgentSessionSummary>[];
      final issues = <AgentSessionCatalogIssue>[];
      for (final key in keys) {
        AgentSessionId? id;
        try {
          id = keyCodec.decode(key);
          final state = await _read(id, key);
          if (state?.record != null && !state!.isTombstone) {
            available.add(summarizeAgentSession(state.record!));
          }
        } on Object {
          issues.add(
            AgentSessionCatalogIssue(
              id: id,
              reason: sanitizedPersistenceError(),
            ),
          );
        }
        await _cleanup(key);
      }
      available.sort(compareAgentSessionSummaries);
      return AgentSessionCatalogSnapshot(available: available, issues: issues);
    });
  }

  Future<JsonlReplayResult?> _read(AgentSessionId id, String key) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(key);
    } on Object {
      throw AgentException(sanitizedPersistenceError());
    }
    if (chunks == null) {
      return null;
    }
    try {
      return await replay.replay(id, chunks);
    } on Object {
      throw AgentException(sanitizedPersistenceError());
    }
  }

  Uint8List _append(List<int> prefix, JsonlSessionEnvelope envelope) {
    final line = _encode(envelope);
    final builder = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(line);
    final value = builder.takeBytes();
    if (value.length > limits.maxStreamBytes) {
      throw AgentException(sanitizedPersistenceError());
    }
    return value;
  }

  Uint8List _encode(JsonlSessionEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    if (bytes.length - 1 > limits.maxEntryBytes ||
        bytes.length > limits.maxStreamBytes) {
      throw AgentException(sanitizedPersistenceError());
    }
    return bytes;
  }

  Future<void> _publish(String key, List<int> contents) async {
    try {
      await storage.publish(key, List<int>.unmodifiable(contents));
    } on Object {
      throw AgentException(sanitizedPersistenceError());
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

AgentException _cancelledException() => AgentException(
  AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
);

Never _throwConflict(AgentSessionId id) {
  throwAgent(
    AgentErrorKind.conflict,
    'Session ${id.value} does not match the expected revision.',
  );
}
