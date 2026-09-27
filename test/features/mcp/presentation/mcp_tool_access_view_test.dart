import 'package:domovoy/core/agents/ids.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/mcp/application/mcp_tool_access_controller.dart';
import 'package:domovoy/features/mcp/presentation/mcp_tool_access_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';

final chatId = AgentSessionId('chat-1');
final projectId = ProjectId('project-1');

final searchToolId = McpToolNamePolicy().candidate(
  connectionId: McpConnectionId('arxiv'),
  originalToolName: 'search_papers',
);
final getToolId = McpToolNamePolicy().candidate(
  connectionId: McpConnectionId('arxiv'),
  originalToolName: 'get_paper',
);

Widget app(McpToolAccessController controller) {
  return MaterialApp(
    theme: DomovoyTheme.light(),
    home: Scaffold(body: McpToolAccessView(controller: controller)),
  );
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<({McpFeatureFixture fixture, ScriptedMcpConnection connection})>
fixtureWithTools() async {
  final connection = ScriptedMcpConnection(
    connectionId: McpConnectionId('arxiv'),
    kind: McpTransportKind.streamableHttp,
    pages: <McpToolPage>[
      McpToolPage(
        tools: <McpToolDescriptor>[
          scriptedTool('arxiv', 'search_papers'),
          scriptedTool('arxiv', 'get_paper'),
        ],
      ),
    ],
  );
  final fixture = await McpFeatureFixture.create(
    builders: <String, ScriptedMcpConnection Function()>{
      'arxiv': () => connection,
    },
  );
  await fixture.saveConnection(
    McpConnectionConfig(
      connectionId: McpConnectionId('arxiv'),
      alias: 'arXiv',
      transport: McpHttpTransportConfig(url: 'https://mcp.example.com/arxiv'),
    ),
    connect: true,
  );
  expect(fixture.host.snapshot.catalog.length, 2);
  return (fixture: fixture, connection: connection);
}

void main() {
  testWidgets('tools can be granted and the selection is persisted', (
    tester,
  ) async {
    setSize(tester, const Size(1200, 900));
    final scenario = await fixtureWithTools();
    addTearDown(scenario.fixture.dispose);
    final fixture = scenario.fixture;
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: projectId);

    await tester.pumpWidget(app(fixture.toolAccess));
    await tester.pumpAndSettle();

    expect(find.text('arXiv'), findsOneWidget);
    expect(find.text('Выбрано: 0'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('mcp-tool-checkbox-$searchToolId')));
    await tester.pumpAndSettle();

    expect(find.text('Выбрано: 1'), findsOneWidget);
    final record = await fixture.selectionStore.load(
      McpToolAccessTarget.chat(chatId.value),
    );
    expect(record!.toolIds, <String>[searchToolId]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope selector switches between chat and project records', (
    tester,
  ) async {
    setSize(tester, const Size(1200, 900));
    final scenario = await fixtureWithTools();
    addTearDown(scenario.fixture.dispose);
    final fixture = scenario.fixture;
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: projectId);

    await tester.pumpWidget(app(fixture.toolAccess));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp-tool-scope-selector')),
      findsOneWidget,
    );
    // The sheet explains that chat selection overrides the project scope.
    expect(
      find.byKey(const ValueKey('mcp-tool-scope-explanation')),
      findsOneWidget,
    );
    expect(find.textContaining('переопределяет выбор проекта'), findsOneWidget);

    await tester.tap(find.text('Проект'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('чатов без собственного выбора'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('mcp-tool-checkbox-$searchToolId')));
    await tester.pumpAndSettle();

    final projectRecord = await fixture.selectionStore.load(
      McpToolAccessTarget.project(projectId.value),
    );
    expect(projectRecord!.toolIds, <String>[searchToolId]);
    expect(
      await fixture.selectionStore.load(McpToolAccessTarget.chat(chatId.value)),
      isNull,
    );
  });

  testWidgets('disappeared tools keep a visible, explained entry', (
    tester,
  ) async {
    setSize(tester, const Size(1000, 900));
    final scenario = await fixtureWithTools();
    addTearDown(scenario.fixture.dispose);
    final fixture = scenario.fixture;
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);
    await fixture.toolAccess.toggleTool(searchToolId, true);
    await fixture.toolAccess.toggleTool(getToolId, true);

    scenario.connection.replacePages(<McpToolPage>[
      McpToolPage(
        tools: <McpToolDescriptor>[scriptedTool('arxiv', 'search_papers')],
      ),
    ]);
    await fixture.host.refreshCatalog(McpConnectionId('arxiv'));
    expect(fixture.host.snapshot.catalog.length, 1);

    await tester.pumpWidget(app(fixture.toolAccess));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mcp-missing-tools')), findsOneWidget);
    expect(find.byKey(ValueKey('mcp-missing-tool-$getToolId')), findsOneWidget);
    expect(find.text('Выбрано: 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat header button opens the permission sheet for its scope', (
    tester,
  ) async {
    setSize(tester, const Size(900, 900));
    final scenario = await fixtureWithTools();
    addTearDown(scenario.fixture.dispose);
    final fixture = scenario.fixture;

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: Scaffold(
          body: Center(
            child: McpChatToolsButton(
              controller: fixture.toolAccess,
              chatId: chatId,
              projectId: projectId,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-tools-open')));
    await tester.pumpAndSettle();

    expect(find.text('Инструменты MCP'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mcp-tool-scope-selector')),
      findsOneWidget,
    );
    expect(fixture.toolAccess.state.target, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout renders the selection surface', (tester) async {
    setSize(tester, const Size(360, 720));
    final scenario = await fixtureWithTools();
    addTearDown(scenario.fixture.dispose);
    final fixture = scenario.fixture;
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);

    await tester.pumpWidget(app(fixture.toolAccess));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('mcp-tool-row-$searchToolId')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
