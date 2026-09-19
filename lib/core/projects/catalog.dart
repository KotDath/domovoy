import '../llm/json.dart';
import 'enums.dart';
import 'errors.dart';
import 'ids.dart';
import 'record.dart';

abstract interface class ProjectCatalog {
  Future<ProjectCatalogSnapshot> list();
}

final class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.revision,
    required this.name,
    required this.rootKind,
    required this.additionalGrantCount,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    required this.lifecycle,
    this.deletionOperationId,
    this.chatCount = 0,
  });

  final ProjectId id;
  final int revision;
  final String name;
  final ProjectRootKind rootKind;
  final int additionalGrantCount;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ProjectLifecycle lifecycle;
  final ProjectDeletionOperationId? deletionOperationId;
  final int chatCount;

  ProjectSummary withChatCount(int count) => ProjectSummary(
    id: id,
    revision: revision,
    name: name,
    rootKind: rootKind,
    additionalGrantCount: additionalGrantCount,
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
    lifecycle: lifecycle,
    deletionOperationId: deletionOperationId,
    chatCount: count,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectSummary &&
          other.id == id &&
          other.revision == revision &&
          other.name == name &&
          other.rootKind == rootKind &&
          other.additionalGrantCount == additionalGrantCount &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.lifecycle == lifecycle &&
          other.deletionOperationId == deletionOperationId &&
          other.chatCount == chatCount;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    name,
    rootKind,
    additionalGrantCount,
    createdAtMicros,
    updatedAtMicros,
    lifecycle,
    deletionOperationId,
    chatCount,
  );
}

final class ProjectCatalogIssue {
  const ProjectCatalogIssue({required this.reason, this.id});

  final ProjectId? id;
  final ProjectError reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCatalogIssue && other.id == id && other.reason == reason;

  @override
  int get hashCode => Object.hash(id, reason);
}

final class ProjectCatalogSnapshot {
  ProjectCatalogSnapshot({
    List<ProjectSummary> available = const <ProjectSummary>[],
    List<ProjectCatalogIssue> issues = const <ProjectCatalogIssue>[],
  }) : available = List<ProjectSummary>.unmodifiable(available),
       issues = List<ProjectCatalogIssue>.unmodifiable(issues);

  final List<ProjectSummary> available;
  final List<ProjectCatalogIssue> issues;

  bool get isFullyHealthy => issues.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCatalogSnapshot &&
          listEquals(other.available, available) &&
          listEquals(other.issues, issues);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(available), Object.hashAll(issues));
}

ProjectSummary summarizeProject(ProjectRecord record, {int chatCount = 0}) {
  return ProjectSummary(
    id: record.id,
    revision: record.revision,
    name: record.name,
    rootKind: record.root.kind,
    additionalGrantCount: record.additionalGrantIds.length,
    createdAtMicros: record.createdAtMicros,
    updatedAtMicros: record.updatedAtMicros,
    lifecycle: record.lifecycle,
    deletionOperationId: record.deletionOperationId,
    chatCount: chatCount,
  );
}

int compareProjectSummaries(ProjectSummary left, ProjectSummary right) {
  final byUpdated = right.updatedAtMicros.compareTo(left.updatedAtMicros);
  return byUpdated != 0 ? byUpdated : left.id.value.compareTo(right.id.value);
}
