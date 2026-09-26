import '../llm/cancellation.dart';
import '../llm/json.dart';
import 'errors.dart';
import 'ids.dart';
import 'transport.dart';

/// Version of the persisted MCP connection record.
const mcpConnectionSchemaVersion = 1;

/// One configured MCP server connection.
///
/// Serialization never contains secret values. Transport-level secret
/// references carry secure-storage keys only.
final class McpConnectionConfig {
  McpConnectionConfig({
    required this.connectionId,
    required String alias,
    required this.transport,
    this.enabled = true,
    int revision = 0,
  }) : alias = _requireAlias(alias),
       revision = _requireRevision(revision);

  factory McpConnectionConfig.fromJson(Object? json) {
    return const McpConnectionCodec().decode(json);
  }

  static const jsonType = 'mcp.connection';

  final McpConnectionId connectionId;
  final String alias;
  final McpTransportConfig transport;
  final bool enabled;
  final int revision;

  Iterable<McpSecretReference> get secretReferences => switch (transport) {
    McpStdioTransportConfig(:final secretReferences) => secretReferences,
    McpHttpTransportConfig(:final secretReferences) => secretReferences,
    McpInProcessStreamTransportConfig() => const <McpSecretReference>[],
  };

  McpConnectionConfig copyWith({
    String? alias,
    McpTransportConfig? transport,
    bool? enabled,
    int? revision,
  }) {
    return McpConnectionConfig(
      connectionId: connectionId,
      alias: alias ?? this.alias,
      transport: transport ?? this.transport,
      enabled: enabled ?? this.enabled,
      revision: revision ?? this.revision,
    );
  }

  Map<String, Object?> toJson() => const McpConnectionCodec().encode(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpConnectionConfig &&
          other.connectionId == connectionId &&
          other.alias == alias &&
          other.enabled == enabled &&
          other.revision == revision &&
          jsonEquals(other.transport.toJson(), transport.toJson());

  @override
  int get hashCode => Object.hash(
    connectionId,
    alias,
    enabled,
    revision,
    jsonHash(transport.toJson()),
  );

  @override
  String toString() => 'McpConnectionConfig(${connectionId.value}, "$alias")';
}

final class McpConnectionCodec {
  const McpConnectionCodec();

  Map<String, Object?> encode(McpConnectionConfig config) =>
      freezeJsonMap(<String, Object?>{
        'schemaVersion': mcpConnectionSchemaVersion,
        'connectionId': config.connectionId.value,
        'alias': config.alias,
        'transport': config.transport.toJson(),
        'enabled': config.enabled,
        'revision': config.revision,
      });

  McpConnectionConfig decode(Object? json) {
    if (json is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP connection record must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    json.forEach((key, value) {
      if (key is! String) {
        throwMcp(
          McpErrorKind.configuration,
          'MCP connection record keys must be strings.',
        );
      }
      map[key] = value;
    });
    final version = map['schemaVersion'];
    if (version != mcpConnectionSchemaVersion) {
      throwMcp(
        McpErrorKind.unsupported,
        'Unsupported MCP connection schemaVersion "$version".',
      );
    }
    final alias = map['alias'];
    if (alias is! String) {
      throwMcp(McpErrorKind.configuration, 'Connection alias must be text.');
    }
    final enabled = map['enabled'];
    if (enabled is! bool) {
      throwMcp(McpErrorKind.configuration, 'Connection enabled must be bool.');
    }
    final revision = map['revision'];
    if (revision is! int) {
      throwMcp(McpErrorKind.configuration, 'Connection revision must be int.');
    }
    if (map['transport'] is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'Connection transport must be an object.',
      );
    }
    return McpConnectionConfig(
      connectionId: McpConnectionId.fromJson(map['connectionId']),
      alias: alias,
      transport: McpTransportConfig.fromJson(map['transport']),
      enabled: enabled,
      revision: revision,
    );
  }
}

/// Persistence boundary for MCP connection configuration.
///
/// Updates use explicit revision checks, mirroring the project repository so a
/// stale writer cannot silently overwrite a newer configuration.
abstract interface class McpConnectionRepository {
  Future<McpConnectionConfig?> load(McpConnectionId id);

  Future<List<McpConnectionConfig>> loadAll();

  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    McpConnectionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

final class InMemoryMcpConnectionRepository implements McpConnectionRepository {
  InMemoryMcpConnectionRepository({this.codec = const McpConnectionCodec()});

  final McpConnectionCodec codec;
  final Map<String, McpConnectionConfig> _records =
      <String, McpConnectionConfig>{};
  final Map<String, int> _tombstones = <String, int>{};

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) async =>
      _records[id.value];

  @override
  Future<List<McpConnectionConfig>> loadAll() async {
    final records = _records.values.toList()
      ..sort((a, b) => a.connectionId.value.compareTo(b.connectionId.value));
    return List<McpConnectionConfig>.unmodifiable(records);
  }

  @override
  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final key = config.connectionId.value;
    final existing = _records[key];
    if (existing != null) {
      if (existing.revision != expectedRevision ||
          config.revision != expectedRevision + 1) {
        _throwConflict(config.connectionId);
      }
      _records[key] = config;
      return;
    }
    final tombstoneRevision = _tombstones[key];
    if (tombstoneRevision != null) {
      if (expectedRevision != tombstoneRevision ||
          config.revision != tombstoneRevision + 1) {
        _throwConflict(config.connectionId);
      }
      _tombstones.remove(key);
      _records[key] = config;
      return;
    }
    if (expectedRevision != 0 || config.revision != 0) {
      _throwConflict(config.connectionId);
    }
    _records[key] = config;
  }

  @override
  Future<void> delete(
    McpConnectionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = _records[id.value];
    if (existing == null || existing.revision != expectedRevision) {
      _throwConflict(id);
    }
    _records.remove(id.value);
    _tombstones[id.value] = existing.revision;
  }
}

/// Revision the stored record must carry for a create/update of [id].
int nextMcpConnectionRevision({
  required McpConnectionConfig? existing,
  required int? tombstoneRevision,
}) {
  if (existing != null) {
    return existing.revision + 1;
  }
  if (tombstoneRevision != null) {
    return tombstoneRevision + 1;
  }
  return 0;
}

/// Revision the caller must expect for a create/update of [id].
int expectedMcpConnectionRevision({
  required McpConnectionConfig? existing,
  required int? tombstoneRevision,
}) {
  if (existing != null) {
    return existing.revision;
  }
  if (tombstoneRevision != null) {
    return tombstoneRevision;
  }
  return 0;
}

String _requireAlias(String alias) {
  final candidate = alias.trim();
  if (candidate.isEmpty || candidate.length > 64) {
    throwMcp(
      McpErrorKind.configuration,
      'Connection alias must be 1-64 characters.',
    );
  }
  return candidate;
}

int _requireRevision(int revision) {
  if (revision < 0) {
    throwMcp(McpErrorKind.configuration, 'Revision must not be negative.');
  }
  return revision;
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwMcp(McpErrorKind.cancelled, 'cancelled');
  }
}

Never _throwConflict(McpConnectionId id) {
  throwMcp(
    McpErrorKind.persistence,
    'Connection ${id.value} was updated concurrently.',
  );
}
