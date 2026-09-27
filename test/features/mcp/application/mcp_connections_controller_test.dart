import 'dart:convert';

import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/mcp/application/mcp_connections_state.dart';
import 'package:domovoy/features/mcp/domain/connection_draft.dart';
import 'package:domovoy/features/mcp/domain/platform_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';
import '../../../support/mcp_fixture_servers.dart';

McpConnectionConfig httpConfig(
  String id, {
  String alias = 'Remote',
  bool enabled = true,
  int revision = 0,
  bool withToken = true,
}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId(id),
    alias: alias,
    transport: McpHttpTransportConfig(
      url: 'https://mcp.example.com/$id',
      bearerSecret: withToken
          ? McpSecretReference.bearer(McpConnectionId(id))
          : null,
    ),
    enabled: enabled,
    revision: revision,
  );
}

McpConnectionConfig stdioConfig(
  String id, {
  String alias = 'Local',
  Map<String, McpSecretReference> secretEnvironment =
      const <String, McpSecretReference>{},
  int revision = 0,
}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId(id),
    alias: alias,
    transport: McpStdioTransportConfig(
      command: 'node',
      args: const <String>['server.js'],
      secretEnvironment: secretEnvironment,
    ),
    revision: revision,
  );
}

ScriptedMcpConnection remoteConnection(
  String id, {
  String toolPrefix = 'tool',
  int pages = 1,
  McpHandshake handshake = const McpHandshake(
    serverName: 'remote-server',
    serverVersion: '2.0.0',
    protocolVersion: '2026-07-28',
  ),
  Object? connectError,
}) {
  final pageList = <McpToolPage>[];
  for (var page = 0; page < pages; page += 1) {
    pageList.add(
      McpToolPage(
        tools: <McpToolDescriptor>[scriptedTool(id, '$toolPrefix$page')],
        nextCursor: page + 1 < pages ? 'cursor-${page + 1}' : null,
      ),
    );
  }
  return ScriptedMcpConnection(
    connectionId: McpConnectionId(id),
    kind: McpTransportKind.streamableHttp,
    pages: pageList,
    handshake: handshake,
    connectError: connectError,
  );
}

void main() {
  test('create saves configuration and keeps the token out of JSONL', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'My remote',
        connectionId: 'remote',
        url: 'https://mcp.example.com/mcp',
        bearerToken: 'super-secret-token',
      ),
    );
    expect(await fixture.connections.saveDraft(), isTrue);

    final config = await fixture.repository.load(McpConnectionId('remote'));
    expect(config, isNotNull);
    expect(config!.alias, 'My remote');
    expect(config.revision, 0);
    final transport = config.transport as McpHttpTransportConfig;
    expect(
      transport.bearerSecret,
      McpSecretReference.bearer(McpConnectionId('remote')),
    );
    expect(jsonEncode(config.toJson()), isNot(contains('super-secret-token')));
    expect(
      await fixture.vault.read(
        McpSecretReference.bearer(McpConnectionId('remote')),
      ),
      'super-secret-token',
    );
    expect(fixture.connections.state.draft, isNull);
    expect(fixture.connections.state.entry('remote'), isNotNull);
  });

  test('check performs handshake and full paged tools/list', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote', pages: 3),
      },
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Remote',
        connectionId: 'remote',
        url: 'https://mcp.example.com/mcp',
      ),
    );
    await fixture.connections.checkDraft();

    final state = fixture.connections.state;
    expect(state.probeStatus, McpProbeStatus.success);
    expect(state.probeResult!.ok, isTrue);
    expect(state.probeResult!.handshake!.serverName, 'remote-server');
    expect(state.probeResult!.handshake!.protocolVersion, '2026-07-28');
    expect(state.probeResult!.tools.map((tool) => tool.originalName), <String>[
      'tool0',
      'tool1',
      'tool2',
    ]);
  });

  test('check failure never echoes a submitted secret', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection(
          'remote',
          connectError: McpException(
            McpError(
              kind: McpErrorKind.handshake,
              message: 'Authorization: Bearer sk-supersecret123 rejected',
            ),
          ),
        ),
      },
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Remote',
        connectionId: 'remote',
        url: 'https://mcp.example.com/mcp',
        bearerToken: 'sk-supersecret123',
      ),
    );
    await fixture.connections.checkDraft();

    final result = fixture.connections.state.probeResult!;
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
    expect(result.error, isNot(contains('sk-supersecret123')));
    expect(result.error, isNot(contains('Bearer')));
  });

  test('edit keeps a stored token and removal deletes it', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await fixture.vault.write(
      McpSecretReference.bearer(McpConnectionId('remote')),
      'stored-token',
    );

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    var draft = fixture.connections.state.draft!;
    expect(draft.bearerTokenStored, isTrue);
    expect(draft.bearerToken, isEmpty);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(alias: 'Renamed'),
    );
    expect(await fixture.connections.saveDraft(), isTrue);

    var stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored!.alias, 'Renamed');
    expect(stored.revision, 1);
    expect(
      (stored.transport as McpHttpTransportConfig).bearerSecret,
      isNotNull,
    );
    expect(
      await fixture.vault.read(
        McpSecretReference.bearer(McpConnectionId('remote')),
      ),
      'stored-token',
    );

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(removeBearerToken: true),
    );
    expect(await fixture.connections.saveDraft(), isTrue);
    stored = await fixture.repository.load(McpConnectionId('remote'));
    expect((stored!.transport as McpHttpTransportConfig).bearerSecret, isNull);
    expect(
      await fixture.vault.read(
        McpSecretReference.bearer(McpConnectionId('remote')),
      ),
      isNull,
    );
  });

  test(
    'a stale editor is rejected instead of overwriting a newer change',
    () async {
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection('remote'),
        },
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(httpConfig('remote'));

      expect(await fixture.connections.beginEdit('remote'), isTrue);
      expect(fixture.connections.state.draft!.baseRevision, 0);

      // Another writer (host or another controller) updates the connection
      // while this form is open.
      final current = await fixture.repository.load(McpConnectionId('remote'));
      await fixture.host.upsertConnection(
        current!.copyWith(alias: 'Newer alias'),
        connect: false,
      );

      fixture.connections.updateDraft(
        (draft) => draft.copyWith(alias: 'Stale alias'),
      );
      expect(await fixture.connections.saveDraft(), isFalse);

      expect(fixture.connections.state.editorError, contains('изменено'));
      expect(fixture.connections.state.draft, isNotNull);
      final stored = await fixture.repository.load(McpConnectionId('remote'));
      expect(stored!.alias, 'Newer alias');
      expect(stored.revision, 1);
    },
  );

  test('a stale delete-by-id is rejected as well', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    expect(await fixture.connections.beginEdit('remote'), isTrue);
    final config = await fixture.repository.load(McpConnectionId('remote'));
    await fixture.host.upsertConnection(
      config!.copyWith(alias: 'Changed elsewhere'),
      connect: false,
    );
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(url: 'https://other.example.com/mcp'),
    );
    expect(await fixture.connections.saveDraft(), isFalse);
    final stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored!.revision, 1);
    expect(
      (stored.transport as McpHttpTransportConfig).url,
      'https://mcp.example.com/remote',
    );
  });

  test('mobile capabilities gate stdio with a clear reason', () async {
    final fixture = await McpFeatureFixture.create(
      capabilities: McpPlatformCapabilities.mobile,
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    expect(
      fixture.connections.state.draft!.transport,
      McpConnectionTransportChoice.streamableHttp,
    );

    fixture.connections.beginCreate(
      transport: McpConnectionTransportChoice.stdio,
    );
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Local',
        connectionId: 'local',
        command: 'node',
      ),
    );
    expect(await fixture.connections.saveDraft(), isFalse);
    expect(fixture.connections.state.editorError, mcpStdioUnavailableReason);
    expect(await fixture.repository.load(McpConnectionId('local')), isNull);

    await fixture.connections.checkDraft();
    expect(fixture.connections.state.probeStatus, McpProbeStatus.failure);
    expect(
      fixture.connections.state.probeResult!.error,
      mcpStdioUnavailableReason,
    );
  });

  test('aurora gating reports the policy reason', () async {
    final fixture = await McpFeatureFixture.create(
      capabilities: McpPlatformCapabilities.aurora,
    );
    addTearDown(fixture.dispose);
    fixture.connections.beginCreate(
      transport: McpConnectionTransportChoice.stdio,
    );
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Local',
        connectionId: 'local',
        command: 'node',
      ),
    );
    expect(await fixture.connections.saveDraft(), isFalse);
    expect(
      fixture.connections.state.editorError,
      mcpStdioDisabledByPolicyReason,
    );
  });

  test('stdio secrets go to the vault and can be removed', () async {
    final fixture = await McpFeatureFixture.create(
      capabilities: McpPlatformCapabilities.desktop,
    );
    addTearDown(fixture.dispose);
    final initial = stdioConfig(
      'local',
      secretEnvironment: <String, McpSecretReference>{
        'API_TOKEN': McpSecretReference.stdioEnvironment(
          McpConnectionId('local'),
          'API_TOKEN',
        ),
      },
    );
    await fixture.saveConnection(initial);
    await fixture.vault.write(
      McpSecretReference.stdioEnvironment(
        McpConnectionId('local'),
        'API_TOKEN',
      ),
      'old-secret',
    );

    expect(await fixture.connections.beginEdit('local'), isTrue);
    final draft = fixture.connections.state.draft!;
    expect(draft.secretEnvironmentStored, contains('API_TOKEN'));
    fixture.connections.setSecretEnvironmentVariable('NEW_TOKEN', 'new-secret');
    expect(await fixture.connections.saveDraft(), isTrue);

    final stored = await fixture.repository.load(McpConnectionId('local'));
    final transport = stored!.transport as McpStdioTransportConfig;
    expect(
      transport.secretEnvironment.keys,
      containsAll(<String>['API_TOKEN', 'NEW_TOKEN']),
    );
    expect(
      await fixture.vault.read(
        McpSecretReference.stdioEnvironment(
          McpConnectionId('local'),
          'NEW_TOKEN',
        ),
      ),
      'new-secret',
    );
    expect(jsonEncode(stored.toJson()), isNot(contains('new-secret')));
    expect(jsonEncode(stored.toJson()), isNot(contains('old-secret')));

    expect(await fixture.connections.beginEdit('local'), isTrue);
    fixture.connections.removeSecretEnvironmentVariable('API_TOKEN');
    expect(await fixture.connections.saveDraft(), isTrue);
    final afterRemove = await fixture.repository.load(McpConnectionId('local'));
    expect(
      (afterRemove!.transport as McpStdioTransportConfig).secretEnvironment
          .containsKey('API_TOKEN'),
      isFalse,
    );
    expect(
      await fixture.vault.read(
        McpSecretReference.stdioEnvironment(
          McpConnectionId('local'),
          'API_TOKEN',
        ),
      ),
      isNull,
    );
  });

  test('delete removes the connection and its secrets', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await fixture.vault.write(
      McpSecretReference.bearer(McpConnectionId('remote')),
      'stored-token',
    );

    expect(await fixture.connections.removeConnection('remote'), isTrue);
    expect(await fixture.repository.load(McpConnectionId('remote')), isNull);
    expect(
      await fixture.vault.read(
        McpSecretReference.bearer(McpConnectionId('remote')),
      ),
      isNull,
    );
    expect(fixture.connections.state.entry('remote'), isNull);
  });

  test('enable and disable round-trip through the host', () async {
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));

    await fixture.connections.setEnabled('remote', false);
    var stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored!.enabled, isFalse);
    expect(stored.revision, 1);
    expect(
      fixture.connections.state.entry('remote')!.status!.phase,
      McpConnectionPhase.disabled,
    );

    await fixture.connections.setEnabled('remote', true);
    stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored!.enabled, isTrue);
    expect(stored.revision, 2);
  });

  test('catalog collision is visible on the failing connection', () async {
    final broken = ScriptedMcpConnection(
      connectionId: McpConnectionId('collision'),
      kind: McpTransportKind.streamableHttp,
      pages: <McpToolPage>[
        McpToolPage(
          tools: <McpToolDescriptor>[
            scriptedTool('collision', 'x' * 80),
            scriptedTool('collision', mcpCollidingToolNames[0]),
            scriptedTool('collision', mcpCollidingToolNames[1]),
          ],
        ),
      ],
    );
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'collision': () => broken,
      },
      startHost: false,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('collision'), connect: true);
    await waitFor(
      () =>
          fixture.connections.state.entry('collision')?.status?.phase ==
          McpConnectionPhase.failed,
    );

    final entry = fixture.connections.state.entry('collision')!;
    expect(entry.lastError, isNotNull);
    expect(entry.lastError, contains('collides'));
  });

  test('built-in connections cannot be edited or removed', () async {
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
    await waitFor(() => fixture.connections.state.entry('arxiv') != null);

    final entry = fixture.connections.state.entry('arxiv')!;
    expect(entry.isBuiltIn, isTrue);
    expect(await fixture.connections.beginEdit('arxiv'), isFalse);
    expect(fixture.connections.state.editorError, isNotNull);
    expect(await fixture.connections.removeConnection('arxiv'), isFalse);
    expect(await fixture.repository.load(McpConnectionId('arxiv')), isNotNull);
  });

  test('create rejects a duplicate connection ID', () async {
    final fixture = await McpFeatureFixture.create(startHost: false);
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'), connect: false);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Duplicate',
        connectionId: 'remote',
        url: 'https://mcp.example.com/other',
      ),
    );
    expect(await fixture.connections.saveDraft(), isFalse);
    expect(fixture.connections.state.editorError, contains('уже существует'));
    final stored = await fixture.repository.load(McpConnectionId('remote'));
    expect(stored!.alias, 'Remote');
  });
}
