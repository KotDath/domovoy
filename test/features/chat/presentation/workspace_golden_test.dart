import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/presentation/workspace_preview.dart';
import 'package:domovoy/features/chat/presentation/workspace_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
    for (final viewport in <String, Size>{
      'desktop': const Size(1200, 800),
      'narrow': const Size(390, 844),
    }.entries) {
      testWidgets('${brightness.name} ${viewport.key} shell golden', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport.value;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(_goldenApp(brightness));
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(WorkspaceShell),
          matchesGoldenFile(
            '../../../goldens/chat_workspace/'
            '${brightness.name}_${viewport.key}.png',
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Widget _goldenApp(Brightness brightness) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  final chats = <AgentSessionSummary>[
    _summary('release', 'Plan the release checklist'),
    _summary('persistence', 'Review persistence behavior'),
    _summary('linux', 'Linux packaging notes'),
    _summary('tokens', 'Token accounting edge cases'),
  ];
  return MaterialApp(
    theme: brightness == Brightness.dark
        ? DomovoyTheme.dark()
        : DomovoyTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
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
      onNewChat: () {},
      onSelectChat: (_) {},
      onOpenSettings: () {},
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
