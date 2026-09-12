import '../llm/cancellation.dart';
import 'catalog.dart';
import 'errors.dart';
import 'ids.dart';
import 'record.dart';

abstract interface class AgentSessionRepository {
  Future<AgentSessionRecord?> load(AgentSessionId id);

  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

final class InMemoryAgentSessionRepository
    implements AgentSessionRepository, AgentSessionCatalog {
  InMemoryAgentSessionRepository({this.codec = const AgentSessionCodec()});

  final AgentSessionCodec codec;
  final Map<String, Object?> _payloads = <String, Object?>{};
  final Map<String, int> _tombstones = <String, int>{};

  void replacePayload(AgentSessionId id, Object json) {
    _payloads[id.value] = json;
  }

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) async {
    final raw = _payloads[id.value];
    if (raw == null) {
      return null;
    }
    return codec.decode(raw);
  }

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    if (_tombstones.containsKey(record.id.value)) {
      throwAgent(
        AgentErrorKind.conflict,
        'Session ${record.id.value} has been deleted.',
      );
    }
    final existingRaw = _payloads[record.id.value];
    final existing = existingRaw == null ? null : codec.decode(existingRaw);
    if (existing == null) {
      if (expectedRevision != 0 || record.revision != 0) {
        throwAgent(
          AgentErrorKind.conflict,
          'Session ${record.id.value} does not match the expected revision.',
        );
      }
      _payloads[record.id.value] = codec.encode(record);
      return;
    }
    if (existing.revision != expectedRevision ||
        record.revision != expectedRevision + 1) {
      throwAgent(
        AgentErrorKind.conflict,
        'Session ${record.id.value} was updated concurrently.',
      );
    }
    _payloads[record.id.value] = codec.encode(record);
  }

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    final raw = _payloads[id.value];
    if (raw == null || _tombstones.containsKey(id.value)) {
      throwAgent(
        AgentErrorKind.conflict,
        'Session ${id.value} does not match the expected revision.',
      );
    }
    final existing = codec.decode(raw);
    if (existing.revision != expectedRevision) {
      throwAgent(
        AgentErrorKind.conflict,
        'Session ${id.value} was updated concurrently.',
      );
    }
    _payloads.remove(id.value);
    _tombstones[id.value] = existing.revision;
  }

  @override
  Future<AgentSessionCatalogSnapshot> list() async {
    final available = <AgentSessionSummary>[];
    final issues = <AgentSessionCatalogIssue>[];
    for (final entry in _payloads.entries) {
      try {
        final record = codec.decode(entry.value);
        if (record.id.value != entry.key) {
          throw const FormatException('identity mismatch');
        }
        available.add(summarizeAgentSession(record));
      } on Object {
        AgentSessionId? id;
        try {
          id = AgentSessionId(entry.key);
        } on Object {
          id = null;
        }
        issues.add(
          AgentSessionCatalogIssue(id: id, reason: sanitizedPersistenceError()),
        );
      }
    }
    available.sort(compareAgentSessionSummaries);
    return AgentSessionCatalogSnapshot(available: available, issues: issues);
  }
}
