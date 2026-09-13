import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/presentation/chat_workspace_page.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';

void main() {
  testWidgets('loading remains distinct from an actionable empty catalog', (
    tester,
  ) async {
    final pending = Completer<AgentSessionCatalogSnapshot>();
    final harness = _PageHarness(_DelayedCatalog(pending.future));
    await tester.pumpWidget(harness.app);

    expect(find.byKey(const ValueKey('workspace-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-empty')), findsNothing);

    pending.complete(AgentSessionCatalogSnapshot());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-loading')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-empty')), findsOneWidget);
    expect(find.text('Новый чат'), findsWidgets);
    await harness.dispose(tester);
  });

  testWidgets('catalog failure is sanitized and settings remain actionable', (
    tester,
  ) async {
    final launcher = _RecordingSettingsLauncher();
    final harness = _PageHarness(
      const _FailingCatalog(),
      settingsLauncher: launcher,
    );
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-error')), findsOneWidget);
    expect(find.textContaining('secret-path'), findsNothing);
    await tester.tap(find.text('Открыть настройки'));
    await tester.pump();
    expect(launcher.opens, 1);
    await harness.dispose(tester);
  });

  testWidgets(
    'token details stay reachable and deletion returns deterministic focus',
    (tester) async {
      await _setView(tester, const Size(1200, 800));
      final repository = InMemoryAgentSessionRepository();
      final record = _savedRecord();
      await repository.save(
        record,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final registry = LlmProviderRegistry();
      BuiltInLlmCatalog.registerInto(registry);
      registry.registerProvider(
        QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
      );
      final runtime = InMemoryAgentRuntime(
        registry: registry,
        tools: AgentToolRegistry(),
        policies: const <String, ToolPermissionPolicy>{'deny': DenyAllPolicy()},
        repository: repository,
        router: InMemorySessionRouter(),
      );
      final controller = ChatWorkspaceController(
        runtime: runtime,
        definition: PromptWorkspace.definition(),
        catalog: repository,
        repository: repository,
        registry: registry,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: DomovoyTheme.dark(),
          home: ChatWorkspacePage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('token-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('token-details')), findsOneWidget);
      expect(find.text('Токены и контекст'), findsOneWidget);
      expect(find.textContaining('legacy'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('token-details-close')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('chat-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Удалить «Durable focus chat»?'), findsOneWidget);
      expect(find.textContaining('необратимо'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-cancel')));
      await tester.pumpAndSettle();
      expect(controller.state.chats, hasLength(1));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'chat-delete');

      await tester.tap(find.byKey(const ValueKey('chat-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(await repository.load(record.id), isNull);
      expect(controller.state.chats, isEmpty);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'chat-new');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await runtime.close();
    },
  );
}

AgentSessionRecord _savedRecord() => AgentSessionRecord(
  id: AgentSessionId('focus-chat'),
  revision: 0,
  definition: PromptWorkspace.definition(),
  title: 'Durable focus chat',
  transcript: AgentTranscript(
    messages: <LlmMessage>[
      LlmMessage(
        role: LlmMessageRole.user,
        parts: <LlmContentPart>[LlmTextPart('Keep this visible')],
      ),
    ],
  ),
  usage: LlmUsage(totalTokens: 4),
  modelTurns: 0,
  toolAttempts: 0,
  createdAtMicros: 1,
  updatedAtMicros: 1,
);

final class _PageHarness {
  _PageHarness(
    AgentSessionCatalog catalog, {
    ChatSettingsLauncher? settingsLauncher,
  }) {
    repository = InMemoryAgentSessionRepository();
    registry = LlmProviderRegistry();
    BuiltInLlmCatalog.registerInto(registry);
    runtime = InMemoryAgentRuntime(
      registry: registry,
      tools: AgentToolRegistry(),
      policies: const <String, ToolPermissionPolicy>{'deny': DenyAllPolicy()},
      repository: repository,
      router: InMemorySessionRouter(),
    );
    controller = ChatWorkspaceController(
      runtime: runtime,
      definition: PromptWorkspace.definition(),
      catalog: catalog,
      repository: repository,
      registry: registry,
      settingsLauncher: settingsLauncher,
    );
  }

  late final InMemoryAgentSessionRepository repository;
  late final LlmProviderRegistry registry;
  late final InMemoryAgentRuntime runtime;
  late final ChatWorkspaceController controller;

  Widget get app => MaterialApp(
    theme: DomovoyTheme.dark(),
    home: ChatWorkspacePage(controller: controller),
  );

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
    await runtime.close();
  }
}

Future<void> _setView(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

final class _DelayedCatalog implements AgentSessionCatalog {
  const _DelayedCatalog(this.snapshot);

  final Future<AgentSessionCatalogSnapshot> snapshot;

  @override
  Future<AgentSessionCatalogSnapshot> list() => snapshot;
}

final class _FailingCatalog implements AgentSessionCatalog {
  const _FailingCatalog();

  @override
  Future<AgentSessionCatalogSnapshot> list() {
    throw StateError('secret-path/credential');
  }
}

final class _RecordingSettingsLauncher implements ChatSettingsLauncher {
  var opens = 0;

  @override
  Future<void> openSettings() async {
    opens += 1;
  }
}
