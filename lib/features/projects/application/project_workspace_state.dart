import '../../../core/agents/catalog.dart';
import '../../../core/projects/catalog.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/provisioning.dart';

const unassignedProjectLabel = 'Без проекта';

enum ProjectWorkspaceStatus { loading, ready, failed }

enum ProjectSelectionKind { unassigned, project }

final class ProjectChatGroup {
  ProjectChatGroup({
    required this.kind,
    required this.title,
    this.projectId,
    this.project,
    this.access,
    List<AgentSessionSummary> chats = const <AgentSessionSummary>[],
    this.unresolvedWarning = false,
    this.deleting = false,
  }) : chats = List<AgentSessionSummary>.unmodifiable(chats);

  final ProjectSelectionKind kind;
  final String title;
  final ProjectId? projectId;
  final ProjectSummary? project;
  final ProjectAccessStatus? access;
  final List<AgentSessionSummary> chats;
  final bool unresolvedWarning;
  final bool deleting;

  bool get admitsNewChat =>
      kind == ProjectSelectionKind.unassigned ||
      (kind == ProjectSelectionKind.project &&
          project?.lifecycle == ProjectLifecycle.active &&
          access == ProjectAccessStatus.active &&
          !deleting);
}

final class ProjectWorkspaceState {
  ProjectWorkspaceState({
    required this.status,
    required this.capabilities,
    List<ProjectChatGroup> groups = const <ProjectChatGroup>[],
    List<ProjectCatalogIssue> projectIssues = const <ProjectCatalogIssue>[],
    this.selectedKind = ProjectSelectionKind.unassigned,
    this.selectedProjectId,
    this.mutationError,
    this.cleanupWarning = false,
    this.busy = false,
  }) : groups = List<ProjectChatGroup>.unmodifiable(groups),
       projectIssues = List<ProjectCatalogIssue>.unmodifiable(projectIssues);

  factory ProjectWorkspaceState.initial(
    ProjectPlatformCapabilities capabilities,
  ) => ProjectWorkspaceState(
    status: ProjectWorkspaceStatus.loading,
    capabilities: capabilities,
  );

  final ProjectWorkspaceStatus status;
  final ProjectPlatformCapabilities capabilities;
  final List<ProjectChatGroup> groups;
  final List<ProjectCatalogIssue> projectIssues;
  final ProjectSelectionKind selectedKind;
  final ProjectId? selectedProjectId;
  final ProjectError? mutationError;
  final bool cleanupWarning;
  final bool busy;

  ProjectChatGroup? get selectedGroup {
    if (selectedKind == ProjectSelectionKind.unassigned) {
      return groups.cast<ProjectChatGroup?>().firstWhere(
        (group) => group?.kind == ProjectSelectionKind.unassigned,
        orElse: () => null,
      );
    }
    return groups.cast<ProjectChatGroup?>().firstWhere(
      (group) => group?.projectId == selectedProjectId,
      orElse: () => null,
    );
  }

  bool get canCreateProject => capabilities.projectCreationSupported;

  bool get showDesktopRootControls => capabilities.desktopExternalRoots;

  bool get showMobileSandboxCopy => capabilities.mobileSandboxRoots;

  bool get showRegrant =>
      capabilities.regrantSupported &&
      selectedGroup?.access == ProjectAccessStatus.requiresRegrant;

  ProjectWorkspaceState copyWith({
    ProjectWorkspaceStatus? status,
    List<ProjectChatGroup>? groups,
    List<ProjectCatalogIssue>? projectIssues,
    ProjectSelectionKind? selectedKind,
    Object? selectedProjectId = _keep,
    Object? mutationError = _keep,
    bool? cleanupWarning,
    bool? busy,
  }) {
    return ProjectWorkspaceState(
      status: status ?? this.status,
      capabilities: capabilities,
      groups: groups ?? this.groups,
      projectIssues: projectIssues ?? this.projectIssues,
      selectedKind: selectedKind ?? this.selectedKind,
      selectedProjectId: identical(selectedProjectId, _keep)
          ? this.selectedProjectId
          : selectedProjectId as ProjectId?,
      mutationError: identical(mutationError, _keep)
          ? this.mutationError
          : mutationError as ProjectError?,
      cleanupWarning: cleanupWarning ?? this.cleanupWarning,
      busy: busy ?? this.busy,
    );
  }

  static const _keep = Object();
}

final class ProjectCreateDraft {
  const ProjectCreateDraft({
    required this.name,
    this.mode,
    this.folderName = 'Project',
    this.additionalCount = 0,
  });

  final String name;
  final ProjectDesktopRootMode? mode;
  final String folderName;
  final int additionalCount;
}
