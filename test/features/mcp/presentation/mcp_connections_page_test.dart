import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/mcp/application/mcp_connections_controller.dart';
import 'package:domovoy/features/mcp/domain/platform_capabilities.dart';
import 'package:domovoy/features/mcp/presentation/mcp_connections_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';

ScriptedMcpConnection remoteConnection(
  String id, {
  Object? connectError,
  List<String> toolNames = const <String>['search', 'fetch'],
}) {
  return ScriptedMcpConnection(
    connectionId: McpConnectionId(id),
    kind: McpTransportKind.streamableHttp,
    handshake: const McpHandshake(
      serverName: 'remote-server',
      serverVersion: '2.0.0',
      protocolVersion: '2026-07-28',
    ),
    pages: <McpToolPage>[
      McpToolPage(
        tools: toolNames
            .map((name) => scriptedTool(id, name))
            .toList(growable: false),
      ),
    ],
    connectError: connectError,
  );
}

Widget app(McpConnectionsController controller) {
  return MaterialApp(
    theme: DomovoyTheme.light(),
    home: Scaffold(body: McpConnectionsPage(controller: controller)),
  );
}

Future<void> setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('desktop layout lists connections and their full catalog', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 800));
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('remote'),
        alias: 'Remote server',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/mcp'),
      ),
      connect: true,
    );
    await fixture.connections.refresh();

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();

    expect(find.text('Remote server'), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-status-remote')), findsOneWidget);
    expect(find.text('готово'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-tools-remote')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp-tool-remote-search')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mcp-tool-remote-fetch')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout keeps the add action reachable without overflow', (
    tester,
  ) async {
    await setSize(tester, const Size(360, 640));
    final fixture = await McpFeatureFixture.create();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mcp-connection-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-connections-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('create flow saves a connection and never shows the token', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 900));
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mcp-connection-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-connection-editor')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-alias')),
      'Remote server',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-id')),
      'remote',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-url')),
      'https://mcp.example.com/mcp',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-token')),
      'top-secret-token',
    );
    await tester.tap(find.byKey(const ValueKey('mcp-editor-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mcp-connection-editor')), findsNothing);
    expect(find.text('Remote server'), findsOneWidget);
    expect(find.text('top-secret-token'), findsNothing);
    final stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored, isNotNull);
    expect(
      await fixture.vault.read(
        McpSecretReference.bearer(McpConnectionId('remote')),
      ),
      'top-secret-token',
    );
  });

  testWidgets('editor check shows handshake identity and complete tools', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 900));
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection(
          'remote',
          toolNames: <String>['search', 'fetch', 'store'],
        ),
      },
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-connection-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-alias')),
      'Remote',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-id')),
      'remote',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-url')),
      'https://mcp.example.com/mcp',
    );
    await tester.tap(find.byKey(const ValueKey('mcp-editor-check')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mcp-editor-probe-handshake')),
      findsOneWidget,
    );
    expect(find.textContaining('remote-server'), findsOneWidget);
    expect(find.textContaining('протокол 2026-07-28'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-editor-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-connection-editor')), findsNothing);
  });

  testWidgets('mobile capabilities show the stdio constraint', (tester) async {
    await setSize(tester, const Size(400, 800));
    final fixture = await McpFeatureFixture.create(
      capabilities: McpPlatformCapabilities.mobile,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp-stdio-constraint-page')),
      findsOneWidget,
    );
    expect(find.text(mcpStdioUnavailableReason), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-connection-add')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp-editor-stdio-constraint')),
      findsOneWidget,
    );
    expect(find.text(mcpStdioUnavailableReason), findsWidgets);
  });

  testWidgets('failure state is visible on the connection card', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 800));
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection(
          'remote',
          connectError: McpException(
            McpError(
              kind: McpErrorKind.handshake,
              message: 'protocol negotiation failed',
            ),
          ),
        ),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('remote'),
        alias: 'Broken',
        transport: McpHttpTransportConfig(url: 'https://mcp.example.com/mcp'),
      ),
      connect: true,
    );
    await fixture.connections.refresh();

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();
    expect(find.text('ошибка'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mcp-connection-error-remote')),
      findsOneWidget,
    );
    expect(find.textContaining('protocol negotiation failed'), findsOneWidget);
  });

  testWidgets('renaming a stored environment variable leaves no stale key', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 900));
    final fixture = await McpFeatureFixture.create();
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('local'),
        alias: 'Local',
        transport: McpStdioTransportConfig(
          command: 'node',
          environment: const <String, String>{'OLD': '1'},
        ),
      ),
      connect: false,
    );
    await fixture.connections.refresh();

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-edit-local')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mcp-editor-env-0-name')),
      'KEPT',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mcp-editor-save')));
    await tester.pumpAndSettle();

    final stored = await fixture.repository.load(McpConnectionId('local'));
    expect(
      (stored!.transport as McpStdioTransportConfig).environment,
      <String, String>{'KEPT': '1'},
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('built-in connections are marked and not removable', (
    tester,
  ) async {
    await setSize(tester, const Size(1200, 800));
    final fixture = await McpFeatureFixture.create(
      builtInConnectionIds: <String>{'arxiv'},
      startHost: false,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(
      McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpInProcessStreamTransportConfig(serverId: 'arxiv'),
      ),
      connect: false,
    );
    await fixture.connections.refresh();

    await tester.pumpWidget(app(fixture.connections));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-builtin-arxiv')), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-remove-arxiv')), findsNothing);
    expect(find.byKey(const ValueKey('mcp-edit-arxiv')), findsNothing);
    expect(find.byKey(const ValueKey('mcp-enabled-arxiv')), findsOneWidget);
  });
}
