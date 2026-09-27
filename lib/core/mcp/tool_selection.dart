import '../llm/cancellation.dart';
import '../llm/json.dart';
import 'errors.dart';

/// Version of the persisted MCP tool-selection record.
const mcpToolSelectionSchemaVersion = 1;

/// Scope a durable MCP tool selection belongs to.
enum McpToolAccessTargetKind {
  /// One interactive chat, identified by its stable session ID.
  chat,

  /// One project, shared by the chats assigned to it.
  project,
}

/// Stable identity of one chat or project tool-selection scope.
///
/// IDs come from the owning store (`AgentSessionId`/`ProjectId`) and are kept
/// as plain strings here so this domain type does not depend on agent or
/// project internals. The selection is deny-by-default: a target without a
/// stored record grants nothing.
final class McpToolAccessTarget {
  McpToolAccessTarget._(this.kind, String id) : id = _validateId(id);

  factory McpToolAccessTarget.chat(String chatId) =>
      McpToolAccessTarget._(McpToolAccessTargetKind.chat, chatId);

  factory McpToolAccessTarget.project(String projectId) =>
      McpToolAccessTarget._(McpToolAccessTargetKind.project, projectId);

  factory McpToolAccessTarget.fromJson(Object? json) {
    if (json is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool access target must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    json.forEach((key, value) {
      if (key is! String) {
        throwMcp(
          McpErrorKind.configuration,
          'MCP tool access target keys must be strings.',
        );
      }
      map[key] = value;
    });
    final kindName = map['kind'];
    final kind = McpToolAccessTargetKind.values
        .where((candidate) => candidate.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Unsupported MCP tool access target kind "$kindName".',
      );
    }
    final id = map['id'];
    if (id is! String) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool access target id must be text.',
      );
    }
    return switch (kind) {
      McpToolAccessTargetKind.chat => McpToolAccessTarget.chat(id),
      McpToolAccessTargetKind.project => McpToolAccessTarget.project(id),
    };
  }

  final McpToolAccessTargetKind kind;
  final String id;

  /// Stream/record key unique across both scopes.
  String get storeKey => '${kind.name}:$id';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'id': id,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpToolAccessTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'McpToolAccessTarget($storeKey)';
}

/// Explicit, durable allowlist of model-facing tool IDs for one target.
///
/// The unit is the B2 stable tool identity (the model-facing name derived by
/// the B1 naming policy). New or renamed tools are never added implicitly:
/// only IDs stored in [toolIds] are granted, and a stored ID whose tool is no
/// longer in the live catalog fails closed at call time.
final class McpToolSelectionRecord {
  McpToolSelectionRecord({
    required this.target,
    Iterable<String> toolIds = const <String>[],
    int revision = 0,
  }) : toolIds = List<String>.unmodifiable(_validateToolIds(toolIds)),
       revision = _validateRevision(revision);

  factory McpToolSelectionRecord.fromJson(Object? json) =>
      const McpToolSelectionCodec().decode(json);

  final McpToolAccessTarget target;

  /// Sorted, unique model-facing tool names.
  final List<String> toolIds;
  final int revision;

  bool allows(String toolId) => toolIds.contains(toolId);

  McpToolSelectionRecord copyWith({Iterable<String>? toolIds, int? revision}) =>
      McpToolSelectionRecord(
        target: target,
        toolIds: toolIds ?? this.toolIds,
        revision: revision ?? this.revision,
      );

  Map<String, Object?> toJson() => const McpToolSelectionCodec().encode(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpToolSelectionRecord &&
          other.target == target &&
          other.revision == revision &&
          jsonEquals(other.toolIds, toolIds);

  @override
  int get hashCode => Object.hash(target, revision, jsonHash(toolIds));

  @override
  String toString() =>
      'McpToolSelectionRecord(${target.storeKey}, ${toolIds.length} tools, '
      'r$revision)';
}

final class McpToolSelectionCodec {
  const McpToolSelectionCodec();

  Map<String, Object?> encode(McpToolSelectionRecord record) =>
      freezeJsonMap(<String, Object?>{
        'schemaVersion': mcpToolSelectionSchemaVersion,
        'target': record.target.toJson(),
        'toolIds': record.toolIds,
        'revision': record.revision,
      });

  McpToolSelectionRecord decode(Object? json) {
    if (json is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool selection record must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    json.forEach((key, value) {
      if (key is! String) {
        throwMcp(
          McpErrorKind.configuration,
          'MCP tool selection record keys must be strings.',
        );
      }
      map[key] = value;
    });
    final version = map['schemaVersion'];
    if (version != mcpToolSelectionSchemaVersion) {
      throwMcp(
        McpErrorKind.unsupported,
        'Unsupported MCP tool selection schemaVersion "$version".',
      );
    }
    final toolIds = map['toolIds'];
    if (toolIds is! List) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool selection toolIds must be a list.',
      );
    }
    final revision = map['revision'];
    if (revision is! int) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool selection revision must be int.',
      );
    }
    return McpToolSelectionRecord(
      target: McpToolAccessTarget.fromJson(map['target']),
      toolIds: toolIds.map((value) {
        if (value is! String) {
          throwMcp(
            McpErrorKind.configuration,
            'MCP tool selection toolIds must be text.',
          );
        }
        return value;
      }),
      revision: revision,
    );
  }
}

/// Persistence boundary for durable per-chat/project MCP tool selections.
///
/// Updates use explicit revision checks, mirroring the MCP connection store, so
/// a stale writer cannot silently replace a newer grant decision.
abstract interface class McpToolSelectionStore {
  Future<McpToolSelectionRecord?> load(McpToolAccessTarget target);

  Future<List<McpToolSelectionRecord>> loadAll();

  Future<void> save(
    McpToolSelectionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    McpToolAccessTarget target, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

/// In-memory store for tests and platforms without JSONL persistence.
final class InMemoryMcpToolSelectionStore implements McpToolSelectionStore {
  InMemoryMcpToolSelectionStore();

  final Map<String, McpToolSelectionRecord> _records =
      <String, McpToolSelectionRecord>{};
  final Map<String, int> _tombstones = <String, int>{};

  @override
  Future<McpToolSelectionRecord?> load(McpToolAccessTarget target) async =>
      _records[target.storeKey];

  @override
  Future<List<McpToolSelectionRecord>> loadAll() async {
    final records = _records.values.toList()
      ..sort((a, b) => a.target.storeKey.compareTo(b.target.storeKey));
    return List<McpToolSelectionRecord>.unmodifiable(records);
  }

  @override
  Future<void> save(
    McpToolSelectionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final key = record.target.storeKey;
    final existing = _records[key];
    if (existing != null) {
      if (existing.revision != expectedRevision ||
          record.revision != expectedRevision + 1) {
        _throwSelectionConflict(record.target);
      }
      _records[key] = record;
      return;
    }
    final tombstoneRevision = _tombstones[key];
    if (tombstoneRevision != null) {
      if (expectedRevision != tombstoneRevision ||
          record.revision != tombstoneRevision + 1) {
        _throwSelectionConflict(record.target);
      }
      _tombstones.remove(key);
      _records[key] = record;
      return;
    }
    if (expectedRevision != 0 || record.revision != 0) {
      _throwSelectionConflict(record.target);
    }
    _records[key] = record;
  }

  @override
  Future<void> delete(
    McpToolAccessTarget target, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final existing = _records[target.storeKey];
    if (existing == null || existing.revision != expectedRevision) {
      _throwSelectionConflict(target);
    }
    _records.remove(target.storeKey);
    _tombstones[target.storeKey] = existing.revision;
  }
}

List<String> _validateToolIds(Iterable<String> toolIds) {
  final unique = <String>{};
  for (final toolId in toolIds) {
    final candidate = toolId.trim();
    if (candidate.isEmpty || candidate.length > 256) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP tool selection IDs must be 1-256 characters.',
      );
    }
    unique.add(candidate);
  }
  final sorted = unique.toList()..sort();
  return sorted;
}

String _validateId(String id) {
  final candidate = id.trim();
  if (candidate.isEmpty ||
      candidate.length > 128 ||
      candidate.contains('\u0000') ||
      candidate.contains('\n') ||
      candidate.contains('\r')) {
    throwMcp(
      McpErrorKind.configuration,
      'MCP tool access target id is not valid.',
    );
  }
  return candidate;
}

int _validateRevision(int revision) {
  if (revision < 0) {
    throwMcp(
      McpErrorKind.configuration,
      'MCP tool selection revision must not be negative.',
    );
  }
  return revision;
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwMcp(McpErrorKind.cancelled, 'cancelled');
  }
}

Never _throwSelectionConflict(McpToolAccessTarget target) {
  throwMcp(
    McpErrorKind.persistence,
    'MCP tool selection for ${target.storeKey} was updated concurrently.',
  );
}
