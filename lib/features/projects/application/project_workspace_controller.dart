import 'dart:async';

import '../../../core/agents/catalog.dart';
import '../../../core/agents/errors.dart';
import '../../../core/agents/ids.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/projects/catalog.dart';
import '../../../core/projects/default_project.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/provisioning.dart';
import '../../../core/projects/record.dart';
import '../../../core/projects/redaction.dart';
import '../../../core/projects/repository.dart';
import '../../chat/application/chat_workspace_controller.dart';
import '../../chat/application/chat_workspace_state.dart';
import '../../chat/domain/chat_deletion_intent.dart';
import 'project_application_service.dart';
import 'project_command_result.dart';
import 'project_workspace_state.dart';

final class ProjectWorkspaceController {
  ProjectWorkspaceController({
    required this.service,
    required this.projects,
    required this.projectCatalog,
    required this.sessionCatalog,
    required this.chat,
    this.grants,
  }) {
    _chatCatalogFingerprint = _catalogFingerprint(chat.state);
    _chatSubscription = chat.states.listen(_onChatState);
  }

  final ProjectApplicationService service;
  final ProjectRepository projects;
  final ProjectCatalog projectCatalog;
  final AgentSessionCatalog sessionCatalog;
  final ChatWorkspaceController chat;
  final ProjectDirectoryGrantStore? grants;

  final StreamController<ProjectWorkspaceState> _states =
      StreamController<ProjectWorkspaceState>.broadcast(sync: true);
  late ProjectWorkspaceState _state = ProjectWorkspaceState.initial(
    service.capabilities,
  );
  var _disposed = false;
  StreamSubscription<ChatWorkspaceState>? _chatSubscription;
  String _chatCatalogFingerprint = '';
  bool _refreshScheduled = false;
  bool _initialized = false;
  final _refreshLock = _ProjectControllerSerialLock();

  ProjectWorkspaceState get state => _state;
  Stream<ProjectWorkspaceState> get states => _states.stream;
  ProjectPlatformCapabilities get capabilities => service.capabilities;

  Future<void> initialize() async {
    _emit(_state.copyWith(status: ProjectWorkspaceStatus.loading, busy: true));
    try {
      await service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      await service.recoverDeletingProjects(
        stopSelectedMember: (id) async {
          if (chat.state.selectedSession != null) {
            await chat.stop();
            await chat.closeSelected();
          }
        },
      );
      await service.cleanupOrphans();
      await chat.initialize();
      await _refresh();
      _initialized = true;
    } on Object catch (error) {
      _emit(
        _state.copyWith(
          status: ProjectWorkspaceStatus.failed,
          busy: false,
          mutationError: _sanitize(error),
        ),
      );
    }
  }

  Future<void> selectUnassigned() async {
    _emit(
      _state.copyWith(
        selectedKind: ProjectSelectionKind.unassigned,
        selectedProjectId: null,
        mutationError: null,
      ),
    );
    await _alignChatSelection();
  }

  Future<void> selectProject(ProjectId id) async {
    if (!_state.groups.any((group) => group.projectId == id)) return;
    _emit(
      _state.copyWith(
        selectedKind: ProjectSelectionKind.project,
        selectedProjectId: id,
        mutationError: null,
      ),
    );
    await _alignChatSelection();
  }

  Future<ProjectCommandResult> createProject(ProjectCreateDraft draft) async {
    _emit(_state.copyWith(busy: true, mutationError: null));
    final result = await service.createProject(
      name: draft.name,
      desktopMode: draft.mode,
      folderName: draft.folderName,
      additionalCount: draft.additionalCount,
      cancellation: CancellationSource().token,
    );
    await _refresh(error: result.error, cleanupWarning: result.cleanupWarning);
    if (result.project != null) {
      await selectProject(result.project!.id);
    }
    return result;
  }

  Future<ProjectCommandResult> deleteSelected() async {
    final group = _state.selectedGroup;
    final project = group?.project;
    if (project == null) {
      return const ProjectCommandResult.cancelled();
    }
    _emit(_state.copyWith(busy: true, mutationError: null));
    late ProjectCommandResult result;
    try {
      result = await service.deleteProject(
        id: project.id,
        expectedRevision: project.revision,
        cancellation: CancellationSource().token,
        stopSelectedMember: () async {
          await chat.stop();
          await chat.stabilize();
          await chat.closeSelected();
        },
      );
    } on Object catch (error) {
      result = ProjectCommandResult.failed(_sanitize(error));
    } finally {
      await _refresh(error: result.error);
    }
    if (result.isSuccess) {
      await selectUnassigned();
    }
    return result;
  }

  Future<ProjectCommandResult> regrantSelected() async {
    final group = _state.selectedGroup;
    final projectId = group?.projectId;
    if (projectId == null || grants == null || !capabilities.regrantSupported) {
      return const ProjectCommandResult.unsupported();
    }
    final record = await projects.load(projectId);
    if (record == null || record.root is! ExternalGrantRootReference) {
      return ProjectCommandResult.failed(sanitizedProjectAccessError());
    }
    final root = record.root as ExternalGrantRootReference;
    final identity = service.provisioner.identityForRoot(grantId: root.grantId);
    if (identity == null) {
      return ProjectCommandResult.failed(sanitizedProjectAccessError());
    }
    try {
      await grants!.regrant(
        grantId: root.grantId,
        projectId: projectId,
        expectedIdentity: identity,
      );
      await _refresh();
      return const ProjectCommandResult.succeeded();
    } on ProjectException catch (error) {
      await _refresh(error: error.error);
      return ProjectCommandResult.failed(error.error);
    }
  }

  Future<ChatCommandResult> createChat() async {
    final group = _state.selectedGroup;
    if (group == null || !group.admitsNewChat) {
      return ChatCommandResult.failed(
        ChatWorkspaceError(
          kind: AgentErrorKind.configuration,
          message: 'Нельзя создать чат в недоступном проекте.',
        ),
      );
    }
    ProjectId? projectId;
    if (group.kind == ProjectSelectionKind.project) {
      projectId = group.projectId;
    } else {
      final defaultProject = await projects.load(defaultProjectId);
      if (defaultProject?.lifecycle == ProjectLifecycle.active) {
        projectId = defaultProjectId;
      }
    }
    if (group.kind == ProjectSelectionKind.project) {
      final recordReady = group.project?.lifecycle == ProjectLifecycle.active;
      if (!recordReady) {
        return ChatCommandResult.failed(
          ChatWorkspaceError(
            kind: AgentErrorKind.configuration,
            message: 'Проект недоступен для новых чатов.',
          ),
        );
      }
    }
    final result = await service.createProjectSession<ChatCommandResult>(
      projectId: projectId,
      create: () => chat.createChat(projectId: projectId),
      denied: (_) => ChatCommandResult.failed(
        ChatWorkspaceError(
          kind: AgentErrorKind.configuration,
          message: 'Проект недоступен для новых чатов.',
        ),
      ),
    );
    try {
      await _refresh();
    } on Object {
      // _refresh records its own sanitized failure.
    }
    return result;
  }

  Future<ChatCommandResult> selectChat(AgentSessionId id) async {
    final group = _state.groups.cast<ProjectChatGroup?>().firstWhere(
      (candidate) => candidate!.chats.any((summary) => summary.id == id),
      orElse: () => null,
    );
    if (group == null) {
      return ChatCommandResult.failed(
        ChatWorkspaceError(
          kind: AgentErrorKind.configuration,
          message: 'Чат не принадлежит выбранному проекту.',
        ),
      );
    }
    if (group.kind == ProjectSelectionKind.unassigned) {
      await selectUnassigned();
    } else if (group.projectId != null) {
      await selectProject(group.projectId!);
    }
    return chat.selectChat(id);
  }

  ChatDeletionIntent? deletionIntentFor(AgentSessionId id) {
    final group = _state.selectedGroup;
    if (group == null || !group.chats.any((summary) => summary.id == id)) {
      return null;
    }
    return chat.deletionIntentFor(id);
  }

  void discardDeletionIntent(ChatDeletionIntent intent) =>
      chat.discardDeletionIntent(intent);

  Future<ChatCommandResult> deleteChat(ChatDeletionIntent intent) async {
    final result = await chat.deleteChat(intent);
    await _refresh();
    return result;
  }

  Future<void> _refresh({ProjectError? error, bool cleanupWarning = false}) {
    return _refreshLock.run(() async {
      try {
        final projectSnapshot = await projectCatalog.list();
        final sessionSnapshot = await sessionCatalog.list();
        final groups = await _projectGroups(projectSnapshot, sessionSnapshot);
        var selectedKind = _state.selectedKind;
        var selectedProjectId = _state.selectedProjectId;
        if (selectedKind == ProjectSelectionKind.project &&
            !groups.any((group) => group.projectId == selectedProjectId)) {
          selectedKind = ProjectSelectionKind.unassigned;
          selectedProjectId = null;
        }
        _emit(
          _state.copyWith(
            status: ProjectWorkspaceStatus.ready,
            groups: groups,
            projectIssues: projectSnapshot.issues,
            busy: false,
            mutationError: error,
            cleanupWarning: cleanupWarning,
            selectedKind: selectedKind,
            selectedProjectId: selectedProjectId,
          ),
        );
        await _alignChatSelection();
      } on Object catch (caught) {
        _emit(
          _state.copyWith(
            status: ProjectWorkspaceStatus.failed,
            busy: false,
            mutationError: error ?? _sanitize(caught),
          ),
        );
      }
    });
  }

  Future<void> _alignChatSelection() async {
    final group = _state.selectedGroup;
    if (group == null) return;
    final selectedId = chat.state.selectedId;
    if (selectedId != null &&
        group.chats.any((summary) => summary.id == selectedId)) {
      return;
    }
    if (chat.state.isBusy) {
      await chat.stop();
      await chat.stabilize();
    }
    if (group.chats.isEmpty) {
      await chat.closeSelected();
    } else {
      await chat.selectChat(group.chats.first.id);
    }
  }

  void _onChatState(ChatWorkspaceState next) {
    final fingerprint = _catalogFingerprint(next);
    if (fingerprint == _chatCatalogFingerprint) return;
    _chatCatalogFingerprint = fingerprint;
    if (!_initialized || _disposed || _refreshScheduled) return;
    _refreshScheduled = true;
    scheduleMicrotask(() async {
      try {
        if (!_disposed) await _refresh();
      } finally {
        _refreshScheduled = false;
      }
    });
  }

  String _catalogFingerprint(ChatWorkspaceState state) => state.chats
      .map(
        (summary) =>
            '${summary.id.value}:${summary.revision}:${summary.projectId?.value}:${summary.title}',
      )
      .join('|');

  Future<List<ProjectChatGroup>> _projectGroups(
    ProjectCatalogSnapshot projectsSnapshot,
    AgentSessionCatalogSnapshot sessionsSnapshot,
  ) async {
    final byProject = <String, List<AgentSessionSummary>>{};
    final unassigned = <AgentSessionSummary>[];
    final readableIds = {
      for (final summary in projectsSnapshot.available) summary.id.value,
    };
    final deletingIds = {
      for (final summary in projectsSnapshot.available)
        if (summary.lifecycle == ProjectLifecycle.deleting) summary.id.value,
    };
    final access = <String, ProjectAccessStatus>{};
    for (final summary in projectsSnapshot.available) {
      if (summary.lifecycle != ProjectLifecycle.active) {
        continue;
      }
      final record = await projects.load(summary.id);
      if (record == null) {
        access[summary.id.value] = ProjectAccessStatus.missing;
        continue;
      }
      access[summary.id.value] = await service.accessStatus(record);
    }
    for (final chatSummary in sessionsSnapshot.available) {
      final projectId = chatSummary.projectId;
      if (projectId == null || projectId.isDefault) {
        unassigned.add(chatSummary);
        continue;
      }
      final active =
          readableIds.contains(projectId.value) &&
          !deletingIds.contains(projectId.value);
      if (!active) {
        unassigned.add(chatSummary);
        continue;
      }
      byProject
          .putIfAbsent(projectId.value, () => <AgentSessionSummary>[])
          .add(chatSummary);
    }
    final groups = <ProjectChatGroup>[];
    for (final summary in projectsSnapshot.available) {
      if (summary.isDefaultProject) {
        continue;
      }
      groups.add(
        ProjectChatGroup(
          kind: ProjectSelectionKind.project,
          title: summary.name,
          projectId: summary.id,
          project: summary,
          access: access[summary.id.value],
          chats: byProject[summary.id.value] ?? const <AgentSessionSummary>[],
          deleting: summary.lifecycle == ProjectLifecycle.deleting,
        ),
      );
    }
    final unresolved = unassigned.any(
      (chat) => chat.projectId != null && !chat.projectId!.isDefault,
    );
    groups.add(
      ProjectChatGroup(
        kind: ProjectSelectionKind.unassigned,
        title: unassignedProjectLabel,
        chats: unassigned,
        unresolvedWarning: unresolved || projectsSnapshot.issues.isNotEmpty,
      ),
    );
    return groups;
  }

  ProjectError _sanitize(Object error) {
    if (error is ProjectException) {
      return ProjectError(
        kind: error.error.kind,
        message: redactUnsafeProjectText(
          error.error.message,
          fallback: sanitizedProjectPersistenceError().message,
        ),
      );
    }
    return sanitizedProjectPersistenceError();
  }

  void _emit(ProjectWorkspaceState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _chatSubscription?.cancel();
    await _states.close();
  }
}

final class _ProjectControllerSerialLock {
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
