import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/presentation/chat_workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';

void main() {
  testWidgets('new chat returns from providers to the chat pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryAgentSessionRepository();
    final runtime = testRuntime(
      provider: QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      ),
      repository: repository,
    );
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
    );
    addTearDown(() async {
      await controller.dispose();
      await runtime.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: ChatWorkspacePage(
          controller: controller,
          providersView: const Center(child: Text('Панель провайдеров')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Провайдеры'));
    await tester.pumpAndSettle();
    expect(find.text('Панель провайдеров'), findsOneWidget);

    await tester.tap(find.text('Новый чат'));
    await tester.pumpAndSettle();

    expect(find.text('Панель провайдеров'), findsNothing);
    expect(controller.state.selectedSession, isNotNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('new chat failure is reported in a snackbar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FailingSaveRepository();
    final runtime = testRuntime(
      provider: QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      ),
      repository: repository,
    );
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
    );
    addTearDown(() async {
      await controller.dispose();
      await runtime.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: ChatWorkspacePage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Новый чат').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(
      find.text('Не удалось прочитать или сохранить состояние чата.'),
      findsOneWidget,
    );
    expect(controller.state.selectedSession, isNull);
  });
}

final class _FailingSaveRepository
    implements AgentSessionRepository, AgentSessionCatalog {
  final InMemoryAgentSessionRepository _delegate =
      InMemoryAgentSessionRepository();

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => _delegate.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );

  @override
  Future<AgentSessionCatalogSnapshot> list() => _delegate.list();

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => Future<void>.error(AgentException(sanitizedPersistenceError()));
}
