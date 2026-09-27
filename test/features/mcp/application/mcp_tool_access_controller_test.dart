import 'package:domovoy/core/agents/ids.dart';
import 'package:domovoy/core/agents/policies.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/features/mcp/application/mcp_tool_access_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';

final chatId = AgentSessionId('chat-1');
final otherChatId = AgentSessionId('chat-2');
final projectId = ProjectId('project-1');

final searchToolId = McpToolNamePolicy().candidate(
  connectionId: McpConnectionId('arxiv'),
  originalToolName: 'search_papers',
);
final getToolId = McpToolNamePolicy().candidate(
  connectionId: McpConnectionId('arxiv'),
  originalToolName: 'get_paper',
);

ScriptedMcpConnection arxivConnection({
  List<McpToolDescriptor>? tools,
  Object? listError,
}) {
  return ScriptedMcpConnection(
    connectionId: McpConnectionId('arxiv'),
    kind: McpTransportKind.streamableHttp,
    pages: <McpToolPage>[
      McpToolPage(
        tools:
            tools ??
            <McpToolDescriptor>[
              scriptedTool(
                'arxiv',
                'search_papers',
                annotations: const <String, Object?>{'destructiveHint': true},
              ),
              scriptedTool('arxiv', 'get_paper'),
            ],
      ),
    ],
    listError: listError,
  );
}

void main() {
  test('selection persists per chat and reloads deny-by-default', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'arxiv': arxivConnection,
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/arxiv'),
      ),
      connect: true,
    );
    await waitFor(() => fixture.host.snapshot.catalog.length == 2);

    await fixture.toolAccess.attachScope(chatId: chatId, projectId: projectId);
    await fixture.toolAccess.toggleTool(searchToolId, true);

    final record = await fixture.selectionStore.load(
      McpToolAccessTarget.chat(chatId.value),
    );
    expect(record!.toolIds, <String>[searchToolId]);

    // Restart: a fresh controller over the same store must keep the explicit
    // grant and leave every other tool ungranted.
    final reopened = McpToolAccessController(
      host: fixture.host,
      store: fixture.selectionStore,
      hostChanges: fixture.host,
    );
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await reopened.attachScope(chatId: chatId, projectId: projectId);
    expect(reopened.isSelected(searchToolId), isTrue);
    expect(reopened.isSelected(getToolId), isFalse);
    expect(reopened.state.selectedCount, 1);
  });

  test('a newly discovered tool is never granted implicitly', () async {
    final connection = arxivConnection(
      tools: <McpToolDescriptor>[scriptedTool('arxiv', 'search_papers')],
    );
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'arxiv': () => connection,
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/arxiv'),
      ),
      connect: true,
    );
    await waitFor(() => fixture.host.snapshot.catalog.length == 1);
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);
    await fixture.toolAccess.toggleTool(searchToolId, true);

    connection.replacePages(<McpToolPage>[
      McpToolPage(
        tools: <McpToolDescriptor>[
          scriptedTool('arxiv', 'search_papers'),
          scriptedTool('arxiv', 'new_tool'),
        ],
      ),
    ]);
    await fixture.host.refreshCatalog(McpConnectionId('arxiv'));
    await waitFor(() => fixture.host.snapshot.catalog.length == 2);

    final newToolId = McpToolNamePolicy().candidate(
      connectionId: McpConnectionId('arxiv'),
      originalToolName: 'new_tool',
    );
    expect(fixture.toolAccess.isSelected(newToolId), isFalse);
    expect(fixture.toolAccess.selectedToolIds, <String>{searchToolId});
    final record = await fixture.selectionStore.load(
      McpToolAccessTarget.chat(chatId.value),
    );
    expect(record!.toolIds, <String>[searchToolId]);
  });

  test('a disappeared tool keeps its stored state and is reported', () async {
    final connection = arxivConnection(
      tools: <McpToolDescriptor>[
        scriptedTool('arxiv', 'search_papers'),
        scriptedTool('arxiv', 'get_paper'),
      ],
    );
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'arxiv': () => connection,
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/arxiv'),
      ),
      connect: true,
    );
    await waitFor(() => fixture.host.snapshot.catalog.length == 2);
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);
    await fixture.toolAccess.toggleTool(searchToolId, true);
    await fixture.toolAccess.toggleTool(getToolId, true);

    connection.replacePages(<McpToolPage>[
      McpToolPage(
        tools: <McpToolDescriptor>[scriptedTool('arxiv', 'search_papers')],
      ),
    ]);
    await fixture.host.refreshCatalog(McpConnectionId('arxiv'));
    await waitFor(() => fixture.host.snapshot.catalog.length == 1);

    expect(fixture.toolAccess.selectedToolIds, contains(getToolId));
    expect(fixture.toolAccess.state.missingSelectedToolIds, <String>[
      getToolId,
    ]);
    final record = await fixture.selectionStore.load(
      McpToolAccessTarget.chat(chatId.value),
    );
    expect(record!.toolIds, containsAll(<String>[searchToolId, getToolId]));
  });

  test(
    'project scope grants and an explicit empty chat record denies',
    () async {
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'arxiv': arxivConnection,
        },
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(
        McpConnectionConfig(
          connectionId: McpConnectionId('arxiv'),
          alias: 'arXiv',
          transport: McpHttpTransportConfig(
            url: 'https://mcp.example.com/arxiv',
          ),
        ),
        connect: true,
      );
      await waitFor(() => fixture.host.snapshot.catalog.length == 2);
      await fixture.toolAccess.attachScope(
        chatId: chatId,
        projectId: projectId,
      );
      fixture.toolAccess.setScope(McpToolAccessTargetKind.project);
      await fixture.toolAccess.toggleTool(searchToolId, true);

      expect(
        fixture.toolAccess.effectiveToolIds(
          chatId: otherChatId,
          projectId: projectId,
        ),
        <String>[searchToolId],
      );
      final projectRecord = await fixture.selectionStore.load(
        McpToolAccessTarget.project(projectId.value),
      );
      expect(projectRecord, isNotNull);
      expect(projectRecord!.toolIds, <String>[searchToolId]);

      // The chat's explicit empty record overrides the project default.
      fixture.toolAccess.setScope(McpToolAccessTargetKind.chat);
      await fixture.toolAccess.clearSelection();
      expect(
        fixture.toolAccess.effectiveToolIds(
          chatId: chatId,
          projectId: projectId,
        ),
        isEmpty,
      );
    },
  );

  test(
    'buildGrant follows the stored allowlist and asks on destructive',
    () async {
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'arxiv': arxivConnection,
        },
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(
        McpConnectionConfig(
          connectionId: McpConnectionId('arxiv'),
          alias: 'arXiv',
          transport: McpHttpTransportConfig(
            url: 'https://mcp.example.com/arxiv',
          ),
        ),
        connect: true,
      );
      await waitFor(() => fixture.host.snapshot.catalog.length == 2);
      await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);
      await fixture.toolAccess.toggleTool(searchToolId, true);

      final grant = fixture.toolAccess.buildGrant(chatId: chatId);
      expect(grant.permits(searchToolId), isFalse);
      expect(grant.ask, contains(searchToolId));
      expect(grant.permissionFor(getToolId), ToolPermission.deny);
      expect(grant.permissionFor('mcp_unknown__tool'), ToolPermission.deny);
    },
  );

  test('unavailable reasons from the provider are shown per tool', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'arxiv': arxivConnection,
      },
      unavailableReasons: () => <String, String>{
        searchToolId: 'JSON Schema cannot be represented for this provider.',
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/arxiv'),
      ),
      connect: true,
    );
    await waitFor(() => fixture.host.snapshot.catalog.length == 2);
    await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);

    final connection = fixture.toolAccess.state.connections.single;
    final tool = connection.tools.firstWhere(
      (candidate) => candidate.toolId == searchToolId,
    );
    expect(tool.isAvailable, isFalse);
    expect(tool.unavailableReason, contains('cannot be represented'));
  });

  test(
    'a failed catalog refresh keeps old tools with a visible reason',
    () async {
      final connection = arxivConnection();
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'arxiv': () => connection,
        },
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(
        McpConnectionConfig(
          connectionId: McpConnectionId('arxiv'),
          alias: 'arXiv',
          transport: McpHttpTransportConfig(
            url: 'https://mcp.example.com/arxiv',
          ),
        ),
        connect: true,
      );
      await waitFor(() => fixture.host.snapshot.catalog.length == 2);
      await fixture.toolAccess.attachScope(chatId: chatId, projectId: null);

      connection.listError = McpException(
        McpError(kind: McpErrorKind.transport, message: 'socket closed'),
      );
      await fixture.host.refreshCatalog(McpConnectionId('arxiv'));
      await waitFor(
        () =>
            fixture.host.snapshot
                .statusFor(McpConnectionId('arxiv'))
                ?.lastError !=
            null,
      );

      final connectionView = fixture.toolAccess.state.connections.single;
      expect(connectionView.unavailableReason, isNotNull);
      expect(connectionView.tools, hasLength(2));
    },
  );
}
