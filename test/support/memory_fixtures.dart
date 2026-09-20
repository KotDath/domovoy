import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/ids.dart';

List<MemorySourceId> sources(List<String> values) =>
    values.map(MemorySourceId.new).toList(growable: false);

MemoryEntry workingEntry({
  String id = 'entry-working-1',
  int revision = 0,
  MemoryKind kind = MemoryKind.requirement,
  String content = 'Retrieval must be deterministic.',
  String project = 'project-1',
  List<String> sourceValues = const <String>['source-1'],
  MemoryEntryStatus status = MemoryEntryStatus.active,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
  MemoryEntryId? supersedesEntryId,
}) {
  return MemoryEntry(
    id: MemoryEntryId(id),
    revision: revision,
    layer: MemoryLayer.working,
    scope: MemoryScope.project,
    kind: kind,
    content: content,
    sourceIds: sources(sourceValues),
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    projectId: ProjectId(project),
    status: status,
    supersedesEntryId: supersedesEntryId,
  );
}

MemoryEntry longTermEntry({
  String id = 'entry-longterm-1',
  int revision = 0,
  MemoryKind kind = MemoryKind.preference,
  String content = 'Prefers concise answers.',
  List<String> sourceValues = const <String>['source-2'],
  MemoryEntryStatus status = MemoryEntryStatus.active,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
  MemoryEntryId? supersedesEntryId,
}) {
  return MemoryEntry(
    id: MemoryEntryId(id),
    revision: revision,
    layer: MemoryLayer.longTerm,
    scope: MemoryScope.global,
    kind: kind,
    content: content,
    sourceIds: sources(sourceValues),
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    status: status,
    supersedesEntryId: supersedesEntryId,
  );
}

MemoryCandidate createCandidate({
  String id = 'candidate-1',
  int revision = 0,
  MemoryLayer layer = MemoryLayer.working,
  MemoryScope scope = MemoryScope.project,
  MemoryKind kind = MemoryKind.requirement,
  String? content = 'Retrieval must be deterministic.',
  String project = 'project-1',
  MemoryEntryId? targetEntryId,
  List<String> sourceValues = const <String>['source-1'],
  MemoryCandidateStatus status = MemoryCandidateStatus.pending,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
}) {
  return MemoryCandidate(
    id: MemoryCandidateId(id),
    revision: revision,
    operation: MemoryProposalOperation.create,
    layer: layer,
    scope: scope,
    kind: kind,
    content: content,
    sourceIds: sources(sourceValues),
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    projectId: scope == MemoryScope.project ? ProjectId(project) : null,
    targetEntryId: targetEntryId,
    status: status,
  );
}

MemoryCandidate updateCandidate({
  String id = 'candidate-update-1',
  int revision = 0,
  required MemoryEntryId targetEntryId,
  MemoryKind kind = MemoryKind.requirement,
  String? content = 'Retrieval must stay deterministic.',
  String project = 'project-1',
  List<String> sourceValues = const <String>['source-1'],
  MemoryCandidateStatus status = MemoryCandidateStatus.pending,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
}) {
  return MemoryCandidate(
    id: MemoryCandidateId(id),
    revision: revision,
    operation: MemoryProposalOperation.update,
    layer: MemoryLayer.working,
    scope: MemoryScope.project,
    kind: kind,
    content: content,
    sourceIds: sources(sourceValues),
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    projectId: ProjectId(project),
    targetEntryId: targetEntryId,
    status: status,
  );
}

MemoryCandidate noopCandidate({
  String id = 'candidate-noop-1',
  int revision = 0,
  MemoryEntryId? targetEntryId,
  String project = 'project-1',
  MemoryCandidateStatus status = MemoryCandidateStatus.pending,
  int createdAtMicros = 1,
  int updatedAtMicros = 1,
}) {
  return MemoryCandidate(
    id: MemoryCandidateId(id),
    revision: revision,
    operation: MemoryProposalOperation.noop,
    layer: MemoryLayer.working,
    scope: MemoryScope.project,
    kind: MemoryKind.requirement,
    sourceIds: const <MemorySourceId>[],
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    projectId: ProjectId(project),
    targetEntryId: targetEntryId,
    status: status,
  );
}
