import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/presentation/workspace_preview.dart';
import 'package:domovoy/features/chat/presentation/workspace_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop shell exposes ordered regions and minimum targets', (
    tester,
  ) async {
    await _setView(tester, const Size(1200, 800));
    await tester.pumpWidget(_fixtureApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-wide')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('token-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('reasoning-selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('reasoning-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-preview')), findsOneWidget);

    final initialOrder =
        FocusTraversalOrder.of(FocusManager.instance.primaryFocus!.context!)
            as NumericFocusOrder;
    expect(initialOrder.order, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final nextOrder =
        FocusTraversalOrder.of(FocusManager.instance.primaryFocus!.context!)
            as NumericFocusOrder;
    expect(nextOrder.order, 2);

    final sidebar = tester.getSize(
      find
          .ancestor(
            of: find.byKey(const ValueKey('chat-list')),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(sidebar.width, DomovoyDimensions.sidebarWidth);
    for (final key in <String>['chat-new', 'open-settings', 'chat-send']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(
        size.height,
        greaterThanOrEqualTo(DomovoyDimensions.minimumTarget),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow shell retains navigation and drawer actions', (
    tester,
  ) async {
    await _setView(tester, const Size(390, 844), textScale: 2);
    await tester.pumpWidget(_fixtureApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-narrow')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-list-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('token-summary')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-list-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-list')), findsNothing);
  });

  testWidgets('central shortcuts invoke new chat and settings once', (
    tester,
  ) async {
    var newChats = 0;
    var settings = 0;
    await _setView(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _fixtureApp(
        onNewChat: () => newChats += 1,
        onSettings: () => settings += 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-new')));
    newChats = 0;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(newChats, 1);
    expect(settings, 1);
  });
}

Widget _fixtureApp({VoidCallback? onNewChat, VoidCallback? onSettings}) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  final chats = <AgentSessionSummary>[
    _summary('release', 'Plan the release checklist'),
    _summary('persistence', 'Review persistence behavior'),
    _summary('linux', 'Linux packaging notes'),
  ];
  return MaterialApp(
    theme: DomovoyTheme.dark(),
    home: WorkspaceShell(
      chats: chats,
      selectedId: chats.first.id,
      title: chats.first.title!,
      modelLabel: 'GPT-5.4',
      modelLabelFor: (_) => 'GPT-5.4',
      body: const WorkspacePreviewTimeline(),
      composer: WorkspacePreviewComposer(
        groups: registry.providerGroups,
        selection: chats.first.selection,
      ),
      onNewChat: onNewChat ?? () {},
      onSelectChat: (_) {},
      onOpenSettings: onSettings ?? () {},
      tokenProjection: workspacePreviewTokenProjection(),
      onOpenTokens: () {},
      onDeleteChat: () {},
      enabled: true,
    ),
  );
}

AgentSessionSummary _summary(String id, String title) => AgentSessionSummary(
  id: AgentSessionId(id),
  revision: 1,
  createdAtMicros: 1,
  updatedAtMicros: 2,
  model: BuiltInLlmCatalog.gpt54Model.ref,
  selection: AgentSessionSelection(
    model: BuiltInLlmCatalog.gpt54Model.ref,
    reasoningMode: ReasoningMode.enabled,
    reasoningEffort: ReasoningEffort.high,
  ),
  title: title,
  messageCount: 2,
);

Future<void> _setView(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
