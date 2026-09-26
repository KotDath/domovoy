import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_mcp_envelope.dart';
import 'jsonl_mcp_replay.dart';

/// Append/replay JSONL storage for MCP connection configuration.
///
/// Secrets are stored as references only; values never reach the stream.
final class JsonlMcpConnectionStore implements McpConnectionRepository {
  JsonlMcpConnectionStore({
    required this.storage,
    this.recordCodec = const McpConnectionCodec(),
    this.envelopeCodec = const JsonlMcpConnectionEnvelopeCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits(),
       _coordinator = _JsonlMcpStoreCoordinator() {
    replay = JsonlMcpConnectionReplay(
      envelopeCodec: envelopeCodec,
      recordCodec: recordCodec,
      limits: this.limits,
    );
  }

  static const streamKey = 'mcp-connections-v1';

  final JsonlStreamStorage storage;
  final McpConnectionCodec recordCodec;
  final JsonlMcpConnectionEnvelopeCodec envelopeCodec;
  final JsonlStorageLimits limits;
  final _JsonlMcpStoreCoordinator _coordinator;
  late final JsonlMcpConnectionReplay replay;

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) {
    return _coordinator.run(() async {
      final state = await _read();
      return state.records[id.value];
    });
  }

  @override
  Future<List<McpConnectionConfig>> loadAll() {
    return _coordinator.run(() async {
      final state = await _read();
      final records = state.records.values.toList()
        ..sort((a, b) => a.connectionId.value.compareTo(b.connectionId.value));
      return List<McpConnectionConfig>.unmodifiable(records);
    });
  }

  @override
  Future<Map<String, int>> loadTombstones() {
    return _coordinator.run(() async {
      final state = await _read();
      return Map<String, int>.unmodifiable(state.tombstoneRevisions);
    });
  }

  @override
  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final state = await _read();
      final key = config.connectionId.value;
      final existing = state.records[key];
      final isTombstone = state.tombstones.contains(key);
      if (existing == null) {
        if (isTombstone) {
          final base = state.tombstoneRevisions[key] ?? 0;
          if (expectedRevision != base || config.revision != base + 1) {
            _throwConflict(config.connectionId);
          }
        } else if (expectedRevision != 0 || config.revision != 0) {
          _throwConflict(config.connectionId);
        }
      } else if (existing.revision != expectedRevision ||
          config.revision != expectedRevision + 1) {
        _throwConflict(config.connectionId);
      }
      final envelope = JsonlMcpConnectionEnvelope(
        connectionId: key,
        sequence: (state.sequences[key] ?? -1) + 1,
        operation: JsonlMcpConnectionOperation.upsert,
        expectedRevision: expectedRevision,
        recordRevision: config.revision,
        record: recordCodec.encode(config),
      );
      _throwIfCancelled(cancellation);
      await _publish(_append(state.validPrefix, envelope));
    });
  }

  @override
  Future<void> delete(
    McpConnectionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final state = await _read();
      final existing = state.records[id.value];
      if (existing == null || existing.revision != expectedRevision) {
        _throwConflict(id);
      }
      final envelope = JsonlMcpConnectionEnvelope(
        connectionId: id.value,
        sequence: (state.sequences[id.value] ?? -1) + 1,
        operation: JsonlMcpConnectionOperation.delete,
        expectedRevision: expectedRevision,
        recordRevision: expectedRevision,
      );
      _throwIfCancelled(cancellation);
      await _publish(_append(state.validPrefix, envelope));
    });
  }

  Future<JsonlMcpReplayResult> _read() async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(streamKey);
    } on Object {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
    if (chunks == null) {
      return JsonlMcpReplayResult(
        records: const <String, McpConnectionConfig>{},
        tombstones: const <String>{},
        tombstoneRevisions: const <String, int>{},
        sequences: const <String, int>{},
        validPrefix: const <int>[],
        needsRepair: false,
      );
    }
    try {
      return await replay.replay(chunks);
    } on Object {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
  }

  Uint8List _append(List<int> prefix, JsonlMcpConnectionEnvelope envelope) {
    final line = _encode(envelope);
    final builder = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(line);
    final value = builder.takeBytes();
    if (value.length > limits.maxStreamBytes) {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
    return value;
  }

  Uint8List _encode(JsonlMcpConnectionEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    if (bytes.length - 1 > limits.maxEntryBytes ||
        bytes.length > limits.maxStreamBytes) {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
    return bytes;
  }

  Future<void> _publish(List<int> contents) async {
    try {
      await storage.publish(streamKey, contents);
    } on Object {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
    try {
      await storage.cleanup(streamKey);
    } on Object {
      // Cleanup is best effort after the active generation is selected.
    }
  }
}

final class _JsonlMcpStoreCoordinator {
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

McpException _cancelledException() =>
    McpException(McpError(kind: McpErrorKind.cancelled, message: 'cancelled'));

Never _throwConflict(McpConnectionId id) {
  throwMcp(
    McpErrorKind.persistence,
    'Connection ${id.value} was updated concurrently.',
  );
}
