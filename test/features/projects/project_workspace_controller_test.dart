import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/projects/application/project_application_service.dart';
import 'package:domovoy/features/projects/application/project_workspace_controller.dart';
import 'package:domovoy/features/projects/application/project_workspace_state.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  test('groups chats under Project and Без проекта', () async {
    final harness = await _Harness.create();
    harness.fs.mount(components: ['home', 'work']);
    harness.fs.bindHandle('h', ['home', 'work']);
    harness.picker.enqueue(
      const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
    );
    final created = await harness.projects.createProject(
      const ProjectCreateDraft(
        name: 'Alpha',
        mode: ProjectDesktopRootMode.attachExisting,
      ),
    );
    expect(created.isSuccess, isTrue);
    await harness.projects.selectProject(created.project!.id);
    final chat = await harness.projects.createChat();
    expect(chat.isSuccess, isTrue);
    await harness.projects.selectUnassigned();
    await harness.projects.createChat();
    final titles = harness.projects.state.groups.map((group) => group.title);
    expect(titles, containsAll(['Alpha', unassignedProjectLabel]));
    final alpha = harness.projects.state.groups.firstWhere(
      (group) => group.title == 'Alpha',
    );
    expect(alpha.chats, hasLength(1));
    final unassigned = harness.projects.state.groups.firstWhere(
      (group) => group.kind == ProjectSelectionKind.unassigned,
    );
    expect(unassigned.chats, hasLength(1));
    await harness.dispose();
  });

  test('deleting Project moves chats to Без проекта', () async {
    final harness = await _Harness.create();
    harness.fs.mount(components: ['home', 'work']);
    harness.fs.bindHandle('h', ['home', 'work']);
    harness.picker.enqueue(
      const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
    );
    final created = await harness.projects.createProject(
      const ProjectCreateDraft(
        name: 'Alpha',
        mode: ProjectDesktopRootMode.attachExisting,
      ),
    );
    await harness.projects.selectProject(created.project!.id);
    await harness.projects.createChat();
    final deleted = await harness.projects.deleteSelected();
    expect(deleted.isSuccess, isTrue);
    expect(
      harness.projects.state.groups.any((group) => group.title == 'Alpha'),
      isFalse,
    );
    final unassigned = harness.projects.state.groups.singleWhere(
      (group) => group.kind == ProjectSelectionKind.unassigned,
    );
    expect(unassigned.chats, isNotEmpty);
    await harness.dispose();
  });

  test(
    'selection always aligns the selected chat with visible group',
    () async {
      final harness = await _Harness.create();
      harness.fs.mount(components: ['home', 'work']);
      harness.fs.bindHandle('h', ['home', 'work']);
      harness.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await harness.projects.createProject(
        const ProjectCreateDraft(
          name: 'Alpha',
          mode: ProjectDesktopRootMode.attachExisting,
        ),
      );
      await harness.projects.selectProject(created.project!.id);
      await harness.projects.createChat();
      final projectChat = harness.chat.state.selectedSession!;
      await harness.projects.selectUnassigned();
      expect(harness.chat.state.selectedSession, isNull);
      await harness.projects.createChat();
      final unassignedChat = harness.chat.state.selectedSession!;
      expect(unassignedChat.projectId, isNull);

      await harness.projects.selectProject(created.project!.id);
      expect(harness.chat.state.selectedId, projectChat.id);
      expect(
        harness.chat.state.selectedSession!.projectId,
        created.project!.id,
      );
      await harness.projects.selectUnassigned();
      expect(harness.chat.state.selectedId, unassignedChat.id);
      await harness.dispose();
    },
  );

  test('direct chat catalog mutations refresh Project groups', () async {
    final harness = await _Harness.create();
    harness.fs.mount(components: ['home', 'work']);
    harness.fs.bindHandle('h', ['home', 'work']);
    harness.picker.enqueue(
      const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
    );
    final created = await harness.projects.createProject(
      const ProjectCreateDraft(
        name: 'Alpha',
        mode: ProjectDesktopRootMode.attachExisting,
      ),
    );
    await harness.projects.selectProject(created.project!.id);
    final appeared = harness.projects.states.firstWhere(
      (state) => state.selectedGroup?.chats.length == 1,
    );
    await harness.chat.createChat(projectId: created.project!.id);
    await appeared;
    final chatId = harness.chat.state.selectedId!;
    expect(harness.projects.state.selectedGroup!.chats.single.id, chatId);

    final retitled = harness.projects.states.firstWhere(
      (state) =>
          state.selectedGroup?.chats.single.title == 'catalog refresh title',
    );
    await harness.chat.send('catalog refresh title');
    await retitled;
    expect(
      harness.projects.state.selectedGroup!.chats.single.title,
      'catalog refresh title',
    );

    final disappeared = harness.projects.states.firstWhere(
      (state) => state.selectedGroup?.chats.isEmpty ?? false,
    );
    final intent = harness.chat.deletionIntentFor(chatId)!;
    await harness.chat.deleteChat(intent);
    await disappeared;
    expect(harness.projects.state.selectedGroup!.chats, isEmpty);
    await harness.dispose();
  });

  test('chat admission loses race to deleting Project', () async {
    final deletingPublished = Completer<void>();
    final continueDeletion = Completer<void>();
    final harness = await _Harness.create(
      hook: (boundary) async {
        if (boundary == ProjectMutationBoundary.afterDeletingPublished) {
          deletingPublished.complete();
          await continueDeletion.future;
        }
      },
    );
    harness.fs.mount(components: ['home', 'work']);
    harness.fs.bindHandle('h', ['home', 'work']);
    harness.picker.enqueue(
      const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
    );
    final created = await harness.projects.createProject(
      const ProjectCreateDraft(
        name: 'Alpha',
        mode: ProjectDesktopRootMode.attachExisting,
      ),
    );
    await harness.projects.selectProject(created.project!.id);
    final deleting = harness.projects.deleteSelected();
    await deletingPublished.future;
    final creating = harness.projects.createChat();
    continueDeletion.complete();
    expect((await deleting).isSuccess, isTrue);
    expect((await creating).isSuccess, isFalse);
    expect((await harness.sessions.list()).available, isEmpty);
    await harness.dispose();
  });

  test(
    'deletion failure refreshes visible deleting state and clears busy',
    () async {
      final harness = await _Harness.create(
        hook: (boundary) async {
          if (boundary == ProjectMutationBoundary.afterDeletingPublished) {
            throwAgent(AgentErrorKind.persistence, 'unsafe native detail');
          }
        },
      );
      harness.fs.mount(components: ['home', 'work']);
      harness.fs.bindHandle('h', ['home', 'work']);
      harness.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await harness.projects.createProject(
        const ProjectCreateDraft(
          name: 'Alpha',
          mode: ProjectDesktopRootMode.attachExisting,
        ),
      );
      await harness.projects.selectProject(created.project!.id);
      final result = await harness.projects.deleteSelected();
      expect(result.isSuccess, isFalse);
      expect(harness.projects.state.busy, isFalse);
      expect(
        harness.projects.state.mutationError?.kind,
        ProjectErrorKind.persistence,
      );
      expect(
        harness.projects.state.groups
            .singleWhere((group) => group.projectId == created.project!.id)
            .deleting,
        isTrue,
      );
      await harness.dispose();
    },
  );
}

final class _Harness {
  _Harness._({
    required this.runtime,
    required this.chat,
    required this.projects,
    required this.fs,
    required this.picker,
    required this.sessions,
  });

  final InMemoryAgentRuntime runtime;
  final ChatWorkspaceController chat;
  final ProjectWorkspaceController projects;
  final FakeDesktopFilesystem fs;
  final ScriptedProjectDirectoryPicker picker;
  final InMemoryAgentSessionRepository sessions;

  static Future<_Harness> create({ProjectBoundaryHook? hook}) async {
    final sessions = InMemoryAgentSessionRepository();
    final runtime = testRuntime(
      provider: QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('answer')],
      ),
      repository: sessions,
    );
    final registry = runtime.registry;
    final chat = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: sessions,
      repository: sessions,
      registry: registry,
    );
    final projectRepo = InMemoryProjectRepository();
    final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
    final picker = ScriptedProjectDirectoryPicker();
    final grants = InMemoryProjectDirectoryGrantStore();
    final provisioner = DesktopProjectRootProvisioner(
      capabilities: ProjectPlatformCapabilities.linux,
      filesystem: fs,
      picker: picker,
      grantStore: grants,
    );
    final controller = ProjectWorkspaceController(
      service: ProjectApplicationService(
        projects: projectRepo,
        projectCatalog: projectRepo,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisioner,
        grants: grants,
        boundaryHook: hook,
      ),
      projects: projectRepo,
      projectCatalog: projectRepo,
      sessionCatalog: sessions,
      chat: chat,
      grants: grants,
    );
    await controller.initialize();
    return _Harness._(
      runtime: runtime,
      chat: chat,
      projects: controller,
      fs: fs,
      picker: picker,
      sessions: sessions,
    );
  }

  Future<void> dispose() async {
    await projects.dispose();
    await chat.dispose();
    await runtime.close();
  }
}
