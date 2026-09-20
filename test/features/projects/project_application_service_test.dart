import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/features/projects/application/project_application_service.dart';
import 'package:domovoy/features/projects/application/project_command_result.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('ProjectApplicationService creation', () {
    test(
      'desktop attach publishes one empty project after revalidation',
      () async {
        final env = _Env.linux();
        env.fs.mount(components: ['home', 'work']);
        env.fs.bindHandle('h', ['home', 'work']);
        env.picker.enqueue(
          const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
        );
        final result = await env.service.createProject(
          name: 'Alpha',
          desktopMode: ProjectDesktopRootMode.attachExisting,
          cancellation: CancellationSource().token,
        );
        expect(result.isSuccess, isTrue);
        expect(result.project!.revision, 0);
        expect(result.project!.lifecycle, ProjectLifecycle.active);
        expect(await env.projects.load(result.project!.id), isNotNull);
      },
    );

    test('web create is unsupported and writes nothing', () async {
      final projects = InMemoryProjectRepository();
      final sessions = InMemoryAgentSessionRepository();
      final provisioner = WebUnsupportedProjectRootProvisioner();
      final service = ProjectApplicationService(
        projects: projects,
        projectCatalog: projects,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisioner,
      );
      final result = await service.createProject(
        name: 'Nope',
        cancellation: CancellationSource().token,
      );
      expect(result.status, ProjectCommandStatus.unsupported);
      expect((await projects.list()).available, isEmpty);
      expect(provisioner.writeCount, 0);
    });

    test('picker cancel creates no project', () async {
      final env = _Env.linux();
      env.picker.enqueue(null);
      final result = await env.service.createProject(
        name: 'Alpha',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      expect(result.status, ProjectCommandStatus.cancelled);
      expect((await env.projects.list()).available, isEmpty);
    });

    test('pre-commit cancel rolls back empty created root', () async {
      final env = _Env.linux();
      env.fs.mount(components: ['home', 'parent']);
      env.fs.bindHandle('parent', ['home', 'parent']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'parent', safeLabel: 'parent'),
      );
      final cancel = CancellationSource();
      env.service = env.rebuild(
        hook: (boundary) async {
          if (boundary == ProjectMutationBoundary.beforeProjectCommit) {
            cancel.cancel();
          }
        },
      );
      final result = await env.service.createProject(
        name: 'Created',
        desktopMode: ProjectDesktopRootMode.createExclusive,
        folderName: 'fresh',
        cancellation: cancel.token,
      );
      expect(result.status, ProjectCommandStatus.cancelled);
      expect((await env.projects.list()).available, isEmpty);
    });

    test('default ids stay unique after service reconstruction', () async {
      final env = _Env.linux();
      env.fs.mount(components: ['home', 'one']);
      env.fs.mount(components: ['home', 'two']);
      env.fs.bindHandle('one', ['home', 'one']);
      env.fs.bindHandle('two', ['home', 'two']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'one', safeLabel: 'one'),
      );
      final first = await env.service.createProject(
        name: 'One',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      env.service = env.rebuild();
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'two', safeLabel: 'two'),
      );
      final second = await env.service.createProject(
        name: 'Two',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      expect(first.isSuccess, isTrue);
      expect(second.isSuccess, isTrue);
      expect(second.project!.id, isNot(first.project!.id));
      expect((await env.projects.list()).available, hasLength(2));
    });
  });

  group('default project bootstrap', () {
    test(
      'creates the protected default once and migrates null chats',
      () async {
        final env = _Env.linux();
        await env.sessions.save(
          _session(),
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );

        final first = await env.service.bootstrapDefaultProject(
          cancellation: CancellationSource().token,
        );
        expect(first.isSuccess, isTrue);
        final record = first.project!;
        expect(record.id, defaultProjectId);
        expect(record.kind, ProjectKind.defaultProject);
        expect(record.root, AppSandboxRootReference(defaultProjectRootId));
        expect(record.isActive, isTrue);
        expect(env.sandbox.roots.containsKey(defaultProjectId.value), isTrue);
        expect(env.provisioner.stageCount, 0);
        expect(
          (await env.sessions.load(AgentSessionId('chat-1')))!.projectId,
          defaultProjectId,
        );

        final second = await env.service.bootstrapDefaultProject(
          cancellation: CancellationSource().token,
        );
        expect(second.isSuccess, isTrue);
        expect(second.project!.revision, record.revision);
        final snapshot = await env.projects.list();
        expect(snapshot.available, hasLength(1));
        expect(snapshot.available.single.kind, ProjectKind.defaultProject);
        expect(env.sandbox.writeCount, 1);
      },
    );

    test('recovers a missing managed sandbox root', () async {
      final env = _Env.linux();
      final first = await env.service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      final record = first.project!;
      env.sandbox.roots.remove(defaultProjectId.value);

      final second = await env.service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      expect(second.isSuccess, isTrue);
      expect(env.sandbox.roots.containsKey(defaultProjectId.value), isTrue);
      expect(second.project!.revision, record.revision + 1);
      expect((await env.projects.list()).available, hasLength(1));
    });

    test('protects the default project from deletion', () async {
      final env = _Env.linux();
      final bootstrapped = await env.service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      final record = bootstrapped.project!;
      final result = await env.service.deleteProject(
        id: defaultProjectId,
        expectedRevision: record.revision,
        cancellation: CancellationSource().token,
      );
      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, ProjectErrorKind.denied);
      expect(await env.projects.load(defaultProjectId), isNotNull);
    });

    test('web bootstrap is unsupported and writes nothing', () async {
      final projects = InMemoryProjectRepository();
      final sessions = InMemoryAgentSessionRepository();
      final provisioner = WebUnsupportedProjectRootProvisioner();
      final service = ProjectApplicationService(
        projects: projects,
        projectCatalog: projects,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisioner,
      );
      final result = await service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      expect(result.status, ProjectCommandStatus.unsupported);
      expect((await projects.list()).available, isEmpty);
    });
  });

  group('deletion saga', () {
    test('reassigns chats to default, tombstones, keeps files', () async {
      final env = _Env.linux();
      await env.service.bootstrapDefaultProject(
        cancellation: CancellationSource().token,
      );
      env.fs.mount(components: ['home', 'work']);
      env.fs.bindHandle('h', ['home', 'work']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await env.service.createProject(
        name: 'Alpha',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      final project = created.project!;
      final chat = _session(projectId: project.id);
      await env.sessions.save(
        chat,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final deleted = await env.service.deleteProject(
        id: project.id,
        expectedRevision: project.revision,
        cancellation: CancellationSource().token,
      );
      expect(deleted.isSuccess, isTrue);
      expect(await env.projects.load(project.id), isNull);
      expect((await env.sessions.load(chat.id))!.projectId, defaultProjectId);
      expect(await env.fs.exists(env.fs.nodes.values.first.identity), isTrue);
    });

    test('pre-admission cancel leaves state unchanged', () async {
      final env = _Env.linux();
      env.fs.mount(components: ['home', 'work']);
      env.fs.bindHandle('h', ['home', 'work']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await env.service.createProject(
        name: 'Alpha',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      final cancel = CancellationSource()..cancel();
      final result = await env.service.deleteProject(
        id: created.project!.id,
        expectedRevision: 0,
        cancellation: cancel.token,
      );
      expect(result.status, ProjectCommandStatus.cancelled);
      expect(await env.projects.load(created.project!.id), isNotNull);
    });

    test('unreadable member blocks tombstone', () async {
      final env = _Env.linux();
      env.fs.mount(components: ['home', 'work']);
      env.fs.bindHandle('h', ['home', 'work']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await env.service.createProject(
        name: 'Alpha',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      env.sessions.replacePayload(AgentSessionId('bad'), <String, Object?>{
        'nope': true,
      });
      final result = await env.service.deleteProject(
        id: created.project!.id,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      expect(result.status, ProjectCommandStatus.conflict);
      expect(await env.projects.load(created.project!.id), isNotNull);
    });

    test('session persistence failure remains deleting and resumes', () async {
      final env = _Env.linux();
      env.fs.mount(components: ['home', 'work']);
      env.fs.bindHandle('h', ['home', 'work']);
      env.picker.enqueue(
        const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'),
      );
      final created = await env.service.createProject(
        name: 'Alpha',
        desktopMode: ProjectDesktopRootMode.attachExisting,
        cancellation: CancellationSource().token,
      );
      await env.sessions.save(
        _session(projectId: created.project!.id),
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final failing = _FailingSessionStore(env.sessions);
      final failingService = ProjectApplicationService(
        projects: env.projects,
        projectCatalog: env.projects,
        sessions: failing,
        sessionCatalog: failing,
        provisioner: env.provisioner,
        grants: env.grants,
      );
      final failed = await failingService.deleteProject(
        id: created.project!.id,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      expect(failed.status, ProjectCommandStatus.failed);
      final deleting = await env.projects.load(created.project!.id);
      expect(deleting, isNotNull);
      expect(deleting!.lifecycle, ProjectLifecycle.deleting);

      final resumed = await env.service.deleteProject(
        id: created.project!.id,
        expectedRevision: deleting.revision,
        cancellation: CancellationSource().token,
      );
      expect(resumed.isSuccess, isTrue);
      expect(await env.projects.load(created.project!.id), isNull);
    });
  });
}

final class _Env {
  _Env.linux()
    : fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux),
      picker = ScriptedProjectDirectoryPicker(),
      grants = InMemoryProjectDirectoryGrantStore(),
      sandbox = FakeMobileSandbox(platformKind: ProjectPlatformKind.linux),
      projects = InMemoryProjectRepository(),
      sessions = InMemoryAgentSessionRepository() {
    provisioner = DesktopProjectRootProvisioner(
      capabilities: ProjectPlatformCapabilities.linux,
      filesystem: fs,
      picker: picker,
      grantStore: grants,
      sandbox: sandbox,
    );
    service = rebuild();
  }

  final FakeDesktopFilesystem fs;
  final ScriptedProjectDirectoryPicker picker;
  final InMemoryProjectDirectoryGrantStore grants;
  final FakeMobileSandbox sandbox;
  final InMemoryProjectRepository projects;
  final InMemoryAgentSessionRepository sessions;
  late DesktopProjectRootProvisioner provisioner;
  late ProjectApplicationService service;

  ProjectApplicationService rebuild({ProjectBoundaryHook? hook}) {
    return ProjectApplicationService(
      projects: projects,
      projectCatalog: projects,
      sessions: sessions,
      sessionCatalog: sessions,
      provisioner: provisioner,
      grants: grants,
      boundaryHook: hook,
      nowMicros: () => 1000,
    );
  }
}

AgentSessionRecord _session({ProjectId? projectId}) {
  return AgentSessionRecord(
    id: AgentSessionId('chat-1'),
    revision: 0,
    definition: testDefinition(),
    transcript: AgentTranscript(),
    usage: LlmUsage(),
    modelTurns: 0,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: 1,
    projectId: projectId,
  );
}

final class _FailingSessionStore
    implements AgentSessionRepository, AgentSessionCatalog {
  _FailingSessionStore(this.delegate);

  final InMemoryAgentSessionRepository delegate;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<AgentSessionCatalogSnapshot> list() => delegate.list();

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    throwAgent(AgentErrorKind.persistence, 'raw storage path must not escape');
  }

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => delegate.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );
}
