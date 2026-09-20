import '../llm/json.dart';
import '../projects/ids.dart';
import 'enums.dart';
import 'errors.dart';
import 'ids.dart';
import 'validation.dart';

/// A confirmed, immutable memory record.
///
/// Entries are created only from an accepted candidate. Every mutation returns
/// a successor revision; layer, scope, project membership, and creation time are
/// immutable for the whole lifetime of the identity.
final class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.revision,
    required this.layer,
    required this.scope,
    required this.kind,
    required String content,
    required List<MemorySourceId> sourceIds,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    this.projectId,
    this.status = MemoryEntryStatus.active,
    this.supersedesEntryId,
  }) : content = normalizeMemoryContent(content),
       sourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(sourceIds),
       ) {
    if (revision < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory revision must be non-negative.',
      );
    }
    if (createdAtMicros < 0 || updatedAtMicros < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory timestamps must be non-negative.',
      );
    }
    if (updatedAtMicros < createdAtMicros) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory timestamps must be monotonic.',
      );
    }
    validateMemoryLayerScope(layer: layer, scope: scope, projectId: projectId);
    if (!kind.allowsLayer(layer)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Kind ${kind.name} is not allowed in layer ${layer.name}.',
      );
    }
    if (this.sourceIds.isEmpty) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory entries require at least one source identity.',
      );
    }
    validateMemorySourceIds(this.sourceIds);
    if (supersedesEntryId == id) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A memory entry cannot supersede itself.',
      );
    }
  }

  factory MemoryEntry.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(
        json,
        type: jsonType,
        version: currentJsonVersion,
      );
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'id',
        'revision',
        'layer',
        'scope',
        'kind',
        'content',
        'sourceIds',
        'createdAtMicros',
        'updatedAtMicros',
        'status',
      };
      if (map['projectId'] != null) {
        expected.add('projectId');
      }
      if (map['supersedesEntryId'] != null) {
        expected.add('supersedesEntryId');
      }
      _expectKeys(map, expected);
      return MemoryEntry(
        id: MemoryEntryId.fromJson(map['id']),
        revision: requireInt(map, 'revision'),
        layer: MemoryLayerCodec.parse(requireNonBlankString(map, 'layer')),
        scope: MemoryScopeCodec.parse(requireNonBlankString(map, 'scope')),
        kind: MemoryKindCodec.parse(requireNonBlankString(map, 'kind')),
        content: requireString(map, 'content'),
        sourceIds: requireList(
          map,
          'sourceIds',
        ).map(MemorySourceId.fromJson).toList(growable: false),
        createdAtMicros: requireInt(map, 'createdAtMicros'),
        updatedAtMicros: requireInt(map, 'updatedAtMicros'),
        projectId: map['projectId'] == null
            ? null
            : ProjectId.fromJson(map['projectId']),
        status: MemoryEntryStatusCodec.parse(
          requireNonBlankString(map, 'status'),
        ),
        supersedesEntryId: map['supersedesEntryId'] == null
            ? null
            : MemoryEntryId.fromJson(map['supersedesEntryId']),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.entry';
  static const currentJsonVersion = 1;

  final MemoryEntryId id;
  final int revision;
  final MemoryLayer layer;
  final MemoryScope scope;
  final MemoryKind kind;
  final String content;
  final List<MemorySourceId> sourceIds;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ProjectId? projectId;
  final MemoryEntryStatus status;
  final MemoryEntryId? supersedesEntryId;

  bool get isActive => status.isActive;

  bool get isForgotten => status.isForgotten;

  /// Only active entries may be supplied to the provider.
  bool get isRetrievable => isActive;

  /// Returns a forgotten successor. Automatic deletion is forbidden, so entries
  /// are tombstoned rather than removed.
  MemoryEntry forget({required int updatedAtMicros}) {
    if (isForgotten) {
      throwMemory(
        MemoryErrorKind.conflict,
        'A forgotten memory entry cannot be forgotten again.',
      );
    }
    final next = _successor(
      updatedAtMicros: updatedAtMicros,
      status: MemoryEntryStatus.forgotten,
    );
    validateMemoryEntryTransition(this, next);
    return next;
  }

  /// Returns an edited successor. Layer, scope, project membership, and
  /// creation time are preserved; provenance may only be extended.
  MemoryEntry revise({
    MemoryKind? kind,
    String? content,
    List<MemorySourceId>? sourceIds,
    required int updatedAtMicros,
  }) {
    if (isForgotten) {
      throwMemory(
        MemoryErrorKind.conflict,
        'A forgotten memory entry cannot be revised.',
      );
    }
    final next = MemoryEntry(
      id: id,
      revision: revision + 1,
      layer: layer,
      scope: scope,
      kind: kind ?? this.kind,
      content: content ?? this.content,
      sourceIds: sourceIds ?? this.sourceIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros,
      projectId: projectId,
      status: status,
      supersedesEntryId: supersedesEntryId,
    );
    validateMemoryEntryTransition(this, next);
    return next;
  }

  MemoryEntry _successor({
    required int updatedAtMicros,
    required MemoryEntryStatus status,
  }) {
    return MemoryEntry(
      id: id,
      revision: revision + 1,
      layer: layer,
      scope: scope,
      kind: kind,
      content: content,
      sourceIds: sourceIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros,
      projectId: projectId,
      status: status,
      supersedesEntryId: supersedesEntryId,
    );
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: currentJsonVersion,
    fields: <String, Object?>{
      'id': id.toJson(),
      'revision': revision,
      'layer': layer.name,
      'scope': scope.name,
      'kind': kind.name,
      'content': content,
      'sourceIds': sourceIds.map((source) => source.toJson()).toList(),
      'createdAtMicros': createdAtMicros,
      'updatedAtMicros': updatedAtMicros,
      'status': status.name,
      if (projectId != null) 'projectId': projectId!.toJson(),
      if (supersedesEntryId != null)
        'supersedesEntryId': supersedesEntryId!.toJson(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryEntry &&
          other.id == id &&
          other.revision == revision &&
          other.layer == layer &&
          other.scope == scope &&
          other.kind == kind &&
          other.content == content &&
          listEquals(other.sourceIds, sourceIds) &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.projectId == projectId &&
          other.status == status &&
          other.supersedesEntryId == supersedesEntryId;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    layer,
    scope,
    kind,
    content,
    Object.hashAll(sourceIds),
    createdAtMicros,
    updatedAtMicros,
    projectId,
    status,
    supersedesEntryId,
  );

  @override
  String toString() =>
      'MemoryEntry(${id.value}, rev=$revision, ${layer.name}, '
      '${scope.name}, ${status.name})';
}

/// Validates that [next] is a legal successor revision of [previous].
void validateMemoryEntryTransition(MemoryEntry previous, MemoryEntry next) {
  if (previous.id != next.id) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must preserve identity.',
    );
  }
  if (previous.isForgotten) {
    throwMemory(
      MemoryErrorKind.conflict,
      'Forgotten memory entries are terminal.',
    );
  }
  if (next.revision != previous.revision + 1) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must advance the revision by exactly one.',
    );
  }
  if (next.updatedAtMicros < previous.updatedAtMicros) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must not move timestamps backwards.',
    );
  }
  if (next.createdAtMicros != previous.createdAtMicros ||
      next.layer != previous.layer ||
      next.scope != previous.scope ||
      next.projectId != previous.projectId) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must preserve creation time, layer, scope, and '
      'project membership.',
    );
  }
  final nextSources = next.sourceIds.map((source) => source.value).toSet();
  final provenancePreserved = previous.sourceIds.every(
    (source) => nextSources.contains(source.value),
  );
  if (!provenancePreserved) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must preserve source provenance.',
    );
  }
  final changed =
      next.status != previous.status ||
      next.content != previous.content ||
      next.kind != previous.kind ||
      next.sourceIds.length != previous.sourceIds.length;
  if (!changed) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A memory transition must change content, kind, provenance, or status.',
    );
  }
}

void _expectKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Unexpected memory entry fields.',
    );
  }
}

final class MemoryEntryCodec {
  const MemoryEntryCodec();

  Map<String, Object?> encode(MemoryEntry entry) =>
      freezeJsonMap(entry.toJson());

  MemoryEntry decode(Object? json) => MemoryEntry.fromJson(json);
}
