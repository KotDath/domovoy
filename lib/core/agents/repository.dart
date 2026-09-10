import '../llm/cancellation.dart';
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

  Future<void> delete(AgentSessionId id);
}

final class InMemoryAgentSessionRepository implements AgentSessionRepository {
  InMemoryAgentSessionRepository({this.codec = const AgentSessionCodec()});

  final AgentSessionCodec codec;
  final Map<String, Object?> _payloads = <String, Object?>{};

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
  Future<void> delete(AgentSessionId id) async {
    _payloads.remove(id.value);
  }
}
