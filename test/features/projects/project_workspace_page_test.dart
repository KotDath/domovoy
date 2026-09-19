import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/presentation/chat_composer.dart';
import 'package:domovoy/features/projects/application/project_application_service.dart';
import 'package:domovoy/features/projects/application/project_workspace_controller.dart';
import 'package:domovoy/features/projects/application/project_workspace_state.dart';
import 'package:domovoy/features/projects/presentation/project_workspace_page.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  testWidgets('desktop creation UI and Без проекта are reachable', (
    tester,
  ) async {
    await _setView(tester, const Size(1200, 800));
    final harness = await _PageHarness.desktop();
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-unassigned')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-create')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-unsupported')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('project-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-create-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-root-attach')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-root-create')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('project-add-additional')),
      findsOneWidget,
    );
    for (final key in ['project-create', 'project-create-confirm']) {
      final size = tester.getSize(find.byKey(ValueKey(key)).first);
      expect(
        size.height,
        greaterThanOrEqualTo(DomovoyDimensions.minimumTarget),
      );
    }
    await _disposePage(tester, harness);
  });

  testWidgets('android sandbox UI hides external controls', (tester) async {
    await _setView(tester, const Size(390, 844));
    final harness = await _PageHarness.mobile();
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-list-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-sandbox-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-root-attach')), findsNothing);
    expect(find.byKey(const ValueKey('project-add-additional')), findsNothing);
    expect(find.byKey(const ValueKey('project-regrant')), findsNothing);
    expect(tester.takeException(), isNull);
    await _disposePage(tester, harness);
  });

  testWidgets(
    'empty selected Project closes foreign chat and disables composer',
    (tester) async {
      final harness = await _PageHarness.desktop();
      await tester.pumpWidget(harness.app);
      await tester.pumpAndSettle();
      await harness.controller.chat.createChat();
      harness.fs!.mount(components: ['home', 'empty-project']);
      harness.fs!.bindHandle('empty', ['home', 'empty-project']);
      harness.picker!.enqueue(
        const ProjectPickedDirectory(
          handleId: 'empty',
          safeLabel: 'empty-project',
        ),
      );
      final created = await harness.controller.createProject(
        const ProjectCreateDraft(
          name: 'Empty',
          mode: ProjectDesktopRootMode.attachExisting,
        ),
      );
      expect(created.isSuccess, isTrue);
      await tester.pumpAndSettle();
      expect(harness.controller.chat.state.selectedSession, isNull);
      expect(find.byType(ChatUnavailableComposer), findsOneWidget);
      await _disposePage(tester, harness);
    },
  );

  testWidgets('web unsupported stays reachable at 390x844', (tester) async {
    await _setView(tester, const Size(390, 844));
    final harness = await _PageHarness.web();
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-list-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-unsupported')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-create')), findsNothing);
    expect(find.byKey(const ValueKey('project-unassigned')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await _disposePage(tester, harness);
  });
}

Future<void> _setView(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _disposePage(WidgetTester tester, _PageHarness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await harness.dispose();
}

final class _PageHarness {
  _PageHarness(this.controller, this.runtime, {this.fs, this.picker});

  final ProjectWorkspaceController controller;
  final InMemoryAgentRuntime runtime;
  final FakeDesktopFilesystem? fs;
  final ScriptedProjectDirectoryPicker? picker;

  Widget get app => MaterialApp(
    theme: DomovoyTheme.dark(),
    home: ProjectWorkspacePage(controller: controller),
  );

  static Future<_PageHarness> desktop() => _create(
    provisionerBuilder: (fs, picker, grants) => DesktopProjectRootProvisioner(
      capabilities: ProjectPlatformCapabilities.linux,
      filesystem: fs,
      picker: picker,
      grantStore: grants,
    ),
  );

  static Future<_PageHarness> mobile() async {
    final sessions = InMemoryAgentSessionRepository();
    final runtime = _runtime(sessions);
    final chat = _chat(runtime, sessions);
    final projects = InMemoryProjectRepository();
    final sandbox = FakeMobileSandbox(
      platformKind: ProjectPlatformKind.android,
    );
    final provisioner = MobileSandboxProjectRootProvisioner(
      capabilities: ProjectPlatformCapabilities.android,
      sandbox: sandbox,
    );
    final controller = ProjectWorkspaceController(
      service: ProjectApplicationService(
        projects: projects,
        projectCatalog: projects,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisioner,
      ),
      projects: projects,
      projectCatalog: projects,
      sessionCatalog: sessions,
      chat: chat,
    );
    return _PageHarness(controller, runtime);
  }

  static Future<_PageHarness> web() async {
    final sessions = InMemoryAgentSessionRepository();
    final runtime = _runtime(sessions);
    final chat = _chat(runtime, sessions);
    final projects = InMemoryProjectRepository();
    final provisioner = WebUnsupportedProjectRootProvisioner();
    final controller = ProjectWorkspaceController(
      service: ProjectApplicationService(
        projects: projects,
        projectCatalog: projects,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisioner,
      ),
      projects: projects,
      projectCatalog: projects,
      sessionCatalog: sessions,
      chat: chat,
    );
    return _PageHarness(controller, runtime);
  }

  static Future<_PageHarness> _create({
    required ProjectRootProvisioner Function(
      FakeDesktopFilesystem fs,
      ScriptedProjectDirectoryPicker picker,
      InMemoryProjectDirectoryGrantStore grants,
    )
    provisionerBuilder,
  }) async {
    final sessions = InMemoryAgentSessionRepository();
    final runtime = _runtime(sessions);
    final chat = _chat(runtime, sessions);
    final projects = InMemoryProjectRepository();
    final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
    final picker = ScriptedProjectDirectoryPicker();
    final grants = InMemoryProjectDirectoryGrantStore();
    final controller = ProjectWorkspaceController(
      service: ProjectApplicationService(
        projects: projects,
        projectCatalog: projects,
        sessions: sessions,
        sessionCatalog: sessions,
        provisioner: provisionerBuilder(fs, picker, grants),
        grants: grants,
      ),
      projects: projects,
      projectCatalog: projects,
      sessionCatalog: sessions,
      chat: chat,
      grants: grants,
    );
    return _PageHarness(controller, runtime, fs: fs, picker: picker);
  }

  static InMemoryAgentRuntime _runtime(
    InMemoryAgentSessionRepository sessions,
  ) {
    return testRuntime(
      provider: QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      ),
      repository: sessions,
    );
  }

  static ChatWorkspaceController _chat(
    InMemoryAgentRuntime runtime,
    InMemoryAgentSessionRepository sessions,
  ) {
    return ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: sessions,
      repository: sessions,
      registry: runtime.registry,
    );
  }

  Future<void> dispose() async {
    await controller.dispose();
    await controller.chat.dispose();
    await runtime.close();
  }
}
