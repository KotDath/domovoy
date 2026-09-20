import '../llm/json.dart';
import '../projects/ids.dart';
import 'enums.dart';
import 'errors.dart';
import 'entry.dart';
import 'ids.dart';
import 'validation.dart';

/// An untrusted memory proposal produced by an extractor or an explicit phrase.
///
/// Candidates are never eligible for retrieval. Only an accepted candidate can
/// be materialized into a [MemoryEntry] by the host.
final class MemoryCandidate {
  MemoryCandidate({
    required this.id,
    required this.revision,
    required this.operation,
    required this.layer,
    required this.scope,
    required this.kind,
    required List<MemorySourceId> sourceIds,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    String? content,
    this.projectId,
    this.targetEntryId,
    this.status = MemoryCandidateStatus.pending,
  }) : content = content == null ? null : normalizeMemoryContent(content),
       sourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(sourceIds),
       ) {
    if (revision < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Candidate revision must be non-negative.',
      );
    }
    if (createdAtMicros < 0 || updatedAtMicros < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Candidate timestamps must be non-negative.',
      );
    }
    if (updatedAtMicros < createdAtMicros) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Candidate timestamps must be monotonic.',
      );
    }
    validateMemoryLayerScope(layer: layer, scope: scope, projectId: projectId);
    if (!kind.allowsLayer(layer)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Kind ${kind.name} is not allowed in layer ${layer.name}.',
      );
    }
    switch (operation) {
      case MemoryProposalOperation.create:
        if (targetEntryId != null) {
          throwMemory(
            MemoryErrorKind.configuration,
            'A create candidate must not target an existing entry.',
          );
        }
        if (this.content == null) {
          throwMemory(
            MemoryErrorKind.configuration,
            'A create candidate requires content.',
          );
        }
      case MemoryProposalOperation.update:
        if (targetEntryId == null) {
          throwMemory(
            MemoryErrorKind.configuration,
            'An update candidate requires a target entry.',
          );
        }
        if (this.content == null) {
          throwMemory(
            MemoryErrorKind.configuration,
            'An update candidate requires content.',
          );
        }
      case MemoryProposalOperation.noop:
        break;
    }
    if (operation.requiresContent && this.sourceIds.isEmpty) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A content candidate requires at least one source identity.',
      );
    }
    validateMemorySourceIds(this.sourceIds);
  }

  factory MemoryCandidate.fromJson(Object? json) {
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
        'operation',
        'layer',
        'scope',
        'kind',
        'sourceIds',
        'createdAtMicros',
        'updatedAtMicros',
        'status',
      };
      if (map['projectId'] != null) {
        expected.add('projectId');
      }
      if (map['targetEntryId'] != null) {
        expected.add('targetEntryId');
      }
      if (map['content'] != null) {
        expected.add('content');
      }
      _expectKeys(map, expected);
      return MemoryCandidate(
        id: MemoryCandidateId.fromJson(map['id']),
        revision: requireInt(map, 'revision'),
        operation: MemoryProposalOperationCodec.parse(
          requireNonBlankString(map, 'operation'),
        ),
        layer: MemoryLayerCodec.parse(requireNonBlankString(map, 'layer')),
        scope: MemoryScopeCodec.parse(requireNonBlankString(map, 'scope')),
        kind: MemoryKindCodec.parse(requireNonBlankString(map, 'kind')),
        sourceIds: requireList(
          map,
          'sourceIds',
        ).map(MemorySourceId.fromJson).toList(growable: false),
        createdAtMicros: requireInt(map, 'createdAtMicros'),
        updatedAtMicros: requireInt(map, 'updatedAtMicros'),
        content: map['content'] == null ? null : requireString(map, 'content'),
        projectId: map['projectId'] == null
            ? null
            : ProjectId.fromJson(map['projectId']),
        targetEntryId: map['targetEntryId'] == null
            ? null
            : MemoryEntryId.fromJson(map['targetEntryId']),
        status: MemoryCandidateStatusCodec.parse(
          requireNonBlankString(map, 'status'),
        ),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.candidate';
  static const currentJsonVersion = 1;

  final MemoryCandidateId id;
  final int revision;
  final MemoryProposalOperation operation;
  final MemoryLayer layer;
  final MemoryScope scope;
  final MemoryKind kind;
  final String? content;
  final List<MemorySourceId> sourceIds;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ProjectId? projectId;
  final MemoryEntryId? targetEntryId;
  final MemoryCandidateStatus status;

  bool get isPending => status.isPending;

  bool get isTerminal => status.isTerminal;

  MemoryCandidate confirm({required int updatedAtMicros}) {
    if (!isPending) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Only pending candidates can be confirmed.',
      );
    }
    if (operation == MemoryProposalOperation.noop) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A noop candidate cannot be confirmed.',
      );
    }
    final next = _successor(
      status: MemoryCandidateStatus.accepted,
      updatedAtMicros: updatedAtMicros,
    );
    validateMemoryCandidateTransition(this, next);
    return next;
  }

  MemoryCandidate reject({required int updatedAtMicros}) {
    if (!isPending) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Only pending candidates can be rejected.',
      );
    }
    final next = _successor(
      status: MemoryCandidateStatus.rejected,
      updatedAtMicros: updatedAtMicros,
    );
    validateMemoryCandidateTransition(this, next);
    return next;
  }

  /// Returns an edited successor. Operation, layer, scope, and project
  /// membership are immutable; content, kind, and provenance may change.
  MemoryCandidate edit({
    String? content,
    MemoryKind? kind,
    List<MemorySourceId>? sourceIds,
    required int updatedAtMicros,
  }) {
    if (!isPending) {
      throwMemory(
        MemoryErrorKind.conflict,
        'Only pending candidates can be edited.',
      );
    }
    final next = MemoryCandidate(
      id: id,
      revision: revision + 1,
      operation: operation,
      layer: layer,
      scope: scope,
      kind: kind ?? this.kind,
      content: content ?? this.content,
      sourceIds: sourceIds ?? this.sourceIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros,
      projectId: projectId,
      targetEntryId: targetEntryId,
      status: status,
    );
    validateMemoryCandidateTransition(this, next);
    return next;
  }

  MemoryCandidate _successor({
    required MemoryCandidateStatus status,
    required int updatedAtMicros,
  }) {
    return MemoryCandidate(
      id: id,
      revision: revision + 1,
      operation: operation,
      layer: layer,
      scope: scope,
      kind: kind,
      content: content,
      sourceIds: sourceIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros,
      projectId: projectId,
      targetEntryId: targetEntryId,
      status: status,
    );
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: currentJsonVersion,
    fields: <String, Object?>{
      'id': id.toJson(),
      'revision': revision,
      'operation': operation.name,
      'layer': layer.name,
      'scope': scope.name,
      'kind': kind.name,
      'sourceIds': sourceIds.map((source) => source.toJson()).toList(),
      'createdAtMicros': createdAtMicros,
      'updatedAtMicros': updatedAtMicros,
      'status': status.name,
      if (projectId != null) 'projectId': projectId!.toJson(),
      if (targetEntryId != null) 'targetEntryId': targetEntryId!.toJson(),
      if (content != null) 'content': content,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryCandidate &&
          other.id == id &&
          other.revision == revision &&
          other.operation == operation &&
          other.layer == layer &&
          other.scope == scope &&
          other.kind == kind &&
          other.content == content &&
          listEquals(other.sourceIds, sourceIds) &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.projectId == projectId &&
          other.targetEntryId == targetEntryId &&
          other.status == status;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    operation,
    layer,
    scope,
    kind,
    content,
    Object.hashAll(sourceIds),
    createdAtMicros,
    updatedAtMicros,
    projectId,
    targetEntryId,
    status,
  );

  @override
  String toString() =>
      'MemoryCandidate(${id.value}, rev=$revision, ${operation.name}, '
      '${status.name})';
}

/// Validates that [next] is a legal successor revision of [previous].
void validateMemoryCandidateTransition(
  MemoryCandidate previous,
  MemoryCandidate next,
) {
  if (previous.id != next.id) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate transition must preserve identity.',
    );
  }
  if (previous.isTerminal) {
    throwMemory(
      MemoryErrorKind.conflict,
      'Terminal candidates cannot be transitioned.',
    );
  }
  if (next.revision != previous.revision + 1) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate transition must advance the revision by exactly one.',
    );
  }
  if (next.updatedAtMicros < previous.updatedAtMicros) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate transition must not move timestamps backwards.',
    );
  }
  if (next.createdAtMicros != previous.createdAtMicros ||
      next.operation != previous.operation ||
      next.layer != previous.layer ||
      next.scope != previous.scope ||
      next.projectId != previous.projectId ||
      next.targetEntryId != previous.targetEntryId) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate transition must preserve creation time, operation, layer, '
      'scope, project membership, and target.',
    );
  }
  final nextSources = next.sourceIds.map((source) => source.value).toSet();
  if (!previous.sourceIds.every(
    (source) => nextSources.contains(source.value),
  )) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate transition must preserve source provenance.',
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
      'A candidate transition must change content, kind, provenance, or status.',
    );
  }
}

/// Materializes an accepted, non-noop candidate into a new entry revision.
///
/// The host owns identity and revision: callers pass the entry identity and
/// revision that persistence will publish.
MemoryEntry memoryEntryFromCandidate({
  required MemoryCandidate candidate,
  required MemoryEntryId entryId,
  required int revision,
  required int createdAtMicros,
  required int updatedAtMicros,
}) {
  if (!candidate.status.isAccepted) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Only accepted candidates can become entries.',
    );
  }
  if (candidate.operation == MemoryProposalOperation.noop) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Noop candidates do not become entries.',
    );
  }
  final content = candidate.content;
  if (content == null) {
    throwMemory(
      MemoryErrorKind.configuration,
      'A candidate must carry content before it becomes an entry.',
    );
  }
  final supersedes = candidate.operation == MemoryProposalOperation.update
      ? candidate.targetEntryId
      : null;
  return MemoryEntry(
    id: entryId,
    revision: revision,
    layer: candidate.layer,
    scope: candidate.scope,
    kind: candidate.kind,
    content: content,
    sourceIds: candidate.sourceIds,
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    projectId: candidate.projectId,
    supersedesEntryId: supersedes == entryId ? null : supersedes,
  );
}

void _expectKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Unexpected memory candidate fields.',
    );
  }
}

final class MemoryCandidateCodec {
  const MemoryCandidateCodec();

  Map<String, Object?> encode(MemoryCandidate candidate) =>
      freezeJsonMap(candidate.toJson());

  MemoryCandidate decode(Object? json) => MemoryCandidate.fromJson(json);
}
