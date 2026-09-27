import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/mcp/domain/connection_draft.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';

McpConnectionConfig httpConfig(
  String id, {
  String alias = 'Remote',
  bool enabled = true,
  int revision = 0,
}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId(id),
    alias: alias,
    transport: McpHttpTransportConfig(
      url: 'https://mcp.example.com/$id',
      bearerSecret: McpSecretReference.bearer(McpConnectionId(id)),
    ),
    enabled: enabled,
    revision: revision,
  );
}

ScriptedMcpConnection remoteConnection(
  String id, {
  Object? connectError,
  String toolName = 'search',
}) {
  return ScriptedMcpConnection(
    connectionId: McpConnectionId(id),
    kind: McpTransportKind.streamableHttp,
    pages: <McpToolPage>[
      McpToolPage(tools: <McpToolDescriptor>[scriptedTool(id, toolName)]),
    ],
    connectError: connectError,
  );
}

/// Probe transport that resolves the bearer token and echoes it in a
/// transport failure, like an untrusted adapter leaking a credential.
final class EchoingSecretMcpTransportFactory implements McpTransportFactory {
  @override
  Future<McpTransportConnection> create(
    McpConnectionConfig config, {
    required McpSecretResolver secrets,
  }) async {
    final value = await secrets.read(
      McpSecretReference.bearer(config.connectionId),
    );
    throw McpException(
      McpError(
        kind: McpErrorKind.transport,
        message: 'connect refused for $value',
      ),
    );
  }
}

void main() {
  final remoteId = McpConnectionId('remote');
  final bearer = McpSecretReference.bearer(remoteId);

  test(
    'a stale revision during token replacement restores the old secret',
    () async {
      final vault = GatedMcpSecretVault();
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection('remote'),
        },
        vault: vault,
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(httpConfig('remote'));
      await vault.write(bearer, 'old-token');

      expect(await fixture.connections.beginEdit('remote'), isTrue);
      fixture.connections.updateDraft(
        (draft) => draft.copyWith(bearerToken: 'new-token'),
      );
      vault.armWriteGate(bearer);
      final saving = fixture.connections.saveDraft();
      await vault.waitForWriteGate();

      // A concurrent writer moves the stored configuration while the vault
      // write is in flight.
      final current = await fixture.repository.load(remoteId);
      await fixture.host.upsertConnection(
        current!.copyWith(alias: 'Newer alias'),
        connect: false,
      );
      vault.releaseWriteGate();
      expect(await saving, isFalse);

      expect(fixture.connections.state.editorError, contains('изменено'));
      final stored = await fixture.repository.load(remoteId);
      expect(stored!.alias, 'Newer alias');
      expect(stored.revision, 1);
      expect(await vault.read(bearer), 'old-token');
      final error = fixture.connections.state.editorError!;
      expect(error, isNot(contains('old-token')));
      expect(error, isNot(contains('new-token')));
    },
  );

  test('a failed save during an edit keeps config and old secret', () async {
    final repository = FailingSaveMcpConnectionRepository(
      InMemoryMcpConnectionRepository(),
    );
    final vault = InMemoryMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      repository: repository,
      vault: vault,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, 'old-token');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(alias: 'Renamed', bearerToken: 'new-token'),
    );
    repository.failSave = true;
    expect(await fixture.connections.saveDraft(), isFalse);

    final stored = await repository.load(remoteId);
    expect(stored!.alias, 'Remote');
    expect(stored.revision, 0);
    expect(await vault.read(bearer), 'old-token');
    expect(fixture.connections.state.editorError, isNotNull);
    expect(fixture.connections.state.editorError, isNot(contains('new-token')));
  });

  test('a failed create leaves no orphan secret behind', () async {
    final repository = FailingSaveMcpConnectionRepository(
      InMemoryMcpConnectionRepository(),
    );
    final vault = InMemoryMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'created': () => remoteConnection('created'),
      },
      repository: repository,
      vault: vault,
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Created',
        connectionId: 'created',
        url: 'https://mcp.example.com/created',
        bearerToken: 'created-secret',
      ),
    );
    repository.failSave = true;
    expect(await fixture.connections.saveDraft(), isFalse);

    expect(await repository.load(McpConnectionId('created')), isNull);
    expect(
      await vault.read(McpSecretReference.bearer(McpConnectionId('created'))),
      isNull,
    );
    expect(fixture.connections.state.editorError, isNotNull);
    expect(
      fixture.connections.state.editorError,
      isNot(contains('created-secret')),
    );
  });

  test(
    'a non-pattern bearer token echoed by the server never reaches the UI',
    () async {
      const token = 'tokenValueABC123';
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection(
            'remote',
            connectError: McpException(
              McpError(
                kind: McpErrorKind.handshake,
                message: 'auth failed for $token',
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
          url: 'https://mcp.example.com/remote',
          bearerToken: token,
        ),
      );
      await fixture.connections.checkDraft();

      final result = fixture.connections.state.probeResult!;
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(result.error, isNot(contains(token)));
      // Safe fallback instead of a partially redacted message.
      expect(result.error, sanitizedMcpUnavailableMessage());
      expect(fixture.connections.state.editorError, isNull);
      expect(fixture.connections.state.toString(), isNot(contains(token)));
    },
  );

  test(
    'a non-pattern secure env value echoed by the server is redacted too',
    () async {
      const envSecret = 'envSecretXYZ789';
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'local': () => ScriptedMcpConnection(
            connectionId: McpConnectionId('local'),
            kind: McpTransportKind.stdio,
            pages: const <McpToolPage>[],
            connectError: McpException(
              McpError(
                kind: McpErrorKind.handshake,
                message: 'bad env $envSecret',
              ),
            ),
          ),
        },
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
      fixture.connections.setSecretEnvironmentVariable('API_TOKEN', envSecret);
      await fixture.connections.checkDraft();

      final result = fixture.connections.state.probeResult!;
      expect(result.ok, isFalse);
      expect(result.error, isNot(contains(envSecret)));
      expect(result.error, sanitizedMcpUnavailableMessage());
    },
  );

  test('a failed secret cleanup after removal is visible', () async {
    final vault = FlakyDeleteMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, 'stored-token');

    vault.failDelete = true;
    expect(await fixture.connections.removeConnection('remote'), isTrue);
    expect(await fixture.repository.load(remoteId), isNull);
    expect(await vault.read(bearer), 'stored-token');
    final state = fixture.connections.state;
    expect(
      state.error,
      isNotNull,
      reason: 'a swallowed cleanup failure must stay visible',
    );
    expect(state.toString(), isNot(contains('stored-token')));
  });

  test('a failed cleanup after removal is retryable to completion', () async {
    final vault = FlakyDeleteMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, 'stored-token');

    vault.failDelete = true;
    expect(await fixture.connections.removeConnection('remote'), isTrue);
    expect(fixture.connections.state.secretCleanupFailures['remote'], 1);
    expect(fixture.connections.state.error, isNotNull);

    // The vault still rejects: the failure stays visible.
    expect(await fixture.connections.retrySecretCleanup('remote'), isFalse);
    expect(fixture.connections.state.secretCleanupFailures['remote'], 1);
    expect(fixture.connections.state.error, isNotNull);

    vault.failDelete = false;
    expect(await fixture.connections.retrySecretCleanup('remote'), isTrue);
    expect(await vault.read(bearer), isNull);
    expect(fixture.connections.state.secretCleanupFailures, isEmpty);
    expect(fixture.connections.state.error, isNull);
  });

  test('a save that removes a token reports a failed cleanup too', () async {
    final vault = FlakyDeleteMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, 'stored-token');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(removeBearerToken: true),
    );
    vault.failDelete = true;
    expect(await fixture.connections.saveDraft(), isTrue);

    final stored = await fixture.repository.load(remoteId);
    expect((stored!.transport as McpHttpTransportConfig).bearerSecret, isNull);
    expect(fixture.connections.state.secretCleanupFailures['remote'], 1);
    expect(fixture.connections.state.error, isNotNull);
    expect(await vault.read(bearer), 'stored-token');

    vault.failDelete = false;
    expect(await fixture.connections.retrySecretCleanup('remote'), isTrue);
    expect(await vault.read(bearer), isNull);
    expect(fixture.connections.state.secretCleanupFailures, isEmpty);
  });

  test('a stored secret echoed by the transport is redacted as well', () async {
    const stored = 'storedTokenValue999';
    final vault = InMemoryMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      probeTransports: EchoingSecretMcpTransportFactory(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, stored);

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    // The form leaves the token field empty and keeps the stored value.
    await fixture.connections.checkDraft();

    final result = fixture.connections.state.probeResult!;
    expect(result.ok, isFalse);
    expect(result.error, isNot(contains(stored)));
    expect(result.error, sanitizedMcpUnavailableMessage());
  });

  test('rollback never clobbers a secret written after ours', () async {
    final vault = GatedMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(bearer, 'old-token');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(bearerToken: 'new-token'),
    );
    vault.armWriteGate(bearer);
    final saving = fixture.connections.saveDraft();
    await vault.waitForWriteGate();
    final current = await fixture.repository.load(remoteId);
    await fixture.host.upsertConnection(
      current!.copyWith(alias: 'Newer alias'),
      connect: false,
    );
    // A different writer stores its own value right after our write lands.
    vault.onAfterWrite = (reference) async {
      if (reference == bearer) {
        vault.onAfterWrite = null;
        await vault.inner.write(bearer, 'external-token');
      }
    };
    vault.releaseWriteGate();
    expect(await saving, isFalse);

    expect(fixture.connections.state.editorError, contains('изменено'));
    expect(await vault.read(bearer), 'external-token');
  });
}
