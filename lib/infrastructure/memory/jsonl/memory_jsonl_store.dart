import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/llm/cancellation.dart';
import '../../../core/memory/errors.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'memory_jsonl_envelope.dart';
import 'memory_jsonl_replay.dart';

/// Opaque, namespaced stream keys: `memory-v1_<stream-tag><base64url(id)>`.
final class MemoryJsonlKeyCodec {
  const MemoryJsonlKeyCodec();

  static const prefix = 'memory-v1_';
  static final RegExp _encodedPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  String encode(MemoryJsonlStream stream, String recordId) {
    final encoded = base64Url.encode(utf8.encode(recordId)).replaceAll('=', '');
    return '$prefix${stream.tag}$encoded';
  }

  /// Returns the record id when [key] belongs to [stream], else `null`.
  String? tryDecodeRecordId(MemoryJsonlStream stream, String key) {
    if (!key.startsWith(prefix)) {
      return null;
    }
    final body = key.substring(prefix.length);
    if (body.length < 2 || body[0] != stream.tag) {
      return null;
    }
    final encoded = body.substring(1);
    if (!_encodedPattern.hasMatch(encoded)) {
      return null;
    }
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final recordId = utf8.decode(base64Url.decode(padded));
      if (recordId.isEmpty || encode(stream, recordId) != key) {
        return null;
      }
      return recordId;
    } on Object {
      return null;
    }
  }

  /// Whether [key] is a well-formed memory stream key for any namespace.
  bool isMemoryKey(String key) {
    if (!key.startsWith(prefix) || key.length <= prefix.length + 1) {
      return false;
    }
    final stream = memoryJsonlStreamForTag(key[prefix.length]);
    return stream != null && tryDecodeRecordId(stream, key) != null;
  }
}

/// Shared append/replay engine for the four independent memory namespaces.
final class MemoryJsonlStore {
  MemoryJsonlStore({
    required this.storage,
    this.envelopeCodec = const MemoryJsonlEnvelopeCodec(),
    this.keyCodec = const MemoryJsonlKeyCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits() {
    replay = MemoryJsonlReplay(
      envelopeCodec: envelopeCodec,
      limits: this.limits,
    );
  }

  final JsonlStreamStorage storage;
  final MemoryJsonlEnvelopeCodec envelopeCodec;
  final MemoryJsonlKeyCodec keyCodec;
  final JsonlStorageLimits limits;
  late final MemoryJsonlReplay replay;
  final _MemoryJsonlStoreCoordinator _coordinator =
      _MemoryJsonlStoreCoordinator();

  Future<MemoryJsonlReplayResult?> read({
    required MemoryJsonlStream stream,
    required String recordId,
  }) {
    return _coordinator.run(() async {
      final key = keyCodec.encode(stream, recordId);
      return _read(stream, recordId, key);
    });
  }

  Future<void> save({
    required MemoryJsonlStream stream,
    required String recordId,
    required int expectedRevision,
    required int recordRevision,
    required Map<String, Object?> record,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final key = keyCodec.encode(stream, recordId);
      final current = await _read(stream, recordId, key);
      _throwIfCancelled(cancellation);
      if (current == null || current.sequence == null) {
        if (expectedRevision != 0 || recordRevision != 0) {
          _throwConflict(recordId);
        }
      } else {
        if (current.isTombstone ||
            current.record == null ||
            current.recordRevision != expectedRevision ||
            recordRevision != expectedRevision + 1) {
          _throwConflict(recordId);
        }
      }

      final sequence = current?.sequence == null ? 0 : current!.sequence! + 1;
      final envelope = MemoryJsonlEnvelope(
        stream: stream,
        recordId: recordId,
        sequence: sequence,
        operation: MemoryJsonlOperation.upsert,
        expectedRevision: expectedRevision,
        recordRevision: recordRevision,
        record: record,
      );
      final successor = _append(current?.validPrefix ?? Uint8List(0), envelope);
      _throwIfCancelled(cancellation);
      await _publish(key, successor);
      await _cleanup(key);
    });
  }

  Future<void> delete({
    required MemoryJsonlStream stream,
    required String recordId,
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final key = keyCodec.encode(stream, recordId);
      final current = await _read(stream, recordId, key);
      _throwIfCancelled(cancellation);
      if (current == null ||
          current.sequence == null ||
          current.isTombstone ||
          current.record == null ||
          current.recordRevision != expectedRevision) {
        _throwConflict(recordId);
      }
      final envelope = MemoryJsonlEnvelope(
        stream: stream,
        recordId: recordId,
        sequence: current.sequence! + 1,
        operation: MemoryJsonlOperation.delete,
        expectedRevision: expectedRevision,
        recordRevision: expectedRevision,
      );
      final tombstone = _encode(envelope);
      _throwIfCancelled(cancellation);
      await _publish(key, tombstone);
      await _cleanup(key);
    });
  }

  Future<List<String>> listRecordIds(MemoryJsonlStream stream) {
    return _coordinator.run(() async {
      final List<String> listed;
      try {
        listed = await storage.listKeys();
      } on Object {
        throw MemoryException(sanitizedMemoryPersistenceError());
      }
      final ids = <String>[];
      for (final key in listed.toSet()) {
        final id = keyCodec.tryDecodeRecordId(stream, key);
        if (id != null) {
          ids.add(id);
        }
      }
      ids.sort();
      return List<String>.unmodifiable(ids);
    });
  }

  Future<MemoryJsonlReplayResult?> _read(
    MemoryJsonlStream stream,
    String recordId,
    String key,
  ) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(key);
    } on Object {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    if (chunks == null) {
      return null;
    }
    try {
      return await replay.replay(
        stream: stream,
        recordId: recordId,
        chunks: chunks,
      );
    } on Object {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
  }

  Uint8List _append(List<int> prefix, MemoryJsonlEnvelope envelope) {
    final line = _encode(envelope);
    final builder = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(line);
    final value = builder.takeBytes();
    if (value.length > limits.maxStreamBytes) {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    return value;
  }

  Uint8List _encode(MemoryJsonlEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    if (bytes.length - 1 > limits.maxEntryBytes ||
        bytes.length > limits.maxStreamBytes) {
      throw MemoryException(sanitizedMemoryPersistenceError());
    }
    return bytes;
  }

  Future<void> _publish(String key, List<int> contents) async {
    try {
      await storage.publish(key, List<int>.unmodifiable(contents));
    } on Object {
      throw MemoryException(sanitizedMemoryPersistenceError());
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

final class _MemoryJsonlStoreCoordinator {
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

MemoryException _cancelledException() => MemoryException(
  MemoryError(kind: MemoryErrorKind.cancelled, message: 'cancelled'),
);

Never _throwConflict(String recordId) {
  throwMemory(
    MemoryErrorKind.conflict,
    'Memory record $recordId does not match the expected revision.',
  );
}
