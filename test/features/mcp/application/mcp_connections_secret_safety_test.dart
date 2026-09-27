import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/mcp/application/mcp_connections_state.dart';
import 'package:domovoy/features/mcp/domain/connection_draft.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/mcp_fakes.dart';
import '../../../support/mcp_feature_fakes.dart';

McpConnectionConfig httpConfig(
  String id, {
  String alias = 'Remote',
  String url = 'https://mcp.example.com',
  bool enabled = true,
  int revision = 0,
}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId(id),
    alias: alias,
    transport: McpHttpTransportConfig(
      url: url,
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

/// Deterministic versioned-reference suffix factory for assertions.
String Function() counterRefIds() {
  var counter = 0;
  return () => '${++counter}';
}

McpSecretReference stagedRef(String label) => McpSecretReference(label);

void main() {
  final remoteId = McpConnectionId('remote');
  final legacyBearer = McpSecretReference.bearer(remoteId);

  test('a stale revision leaves the old config and secret untouched', () async {
    final vault = GatedMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'old-token');
    final staged = stagedRef('mcp.remote.bearer.1');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(bearerToken: 'new-token'),
    );
    vault.armWriteGate(staged);
    final saving = fixture.connections.saveDraft();
    await vault.waitForWriteGate();

    // A concurrent writer moves the stored configuration while the staged
    // vault write is in flight.
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
    // The live configuration still points at the untouched legacy reference.
    expect(
      (stored.transport as McpHttpTransportConfig).bearerSecret,
      legacyBearer,
    );
    expect(await vault.read(legacyBearer), 'old-token');
    // The staged value is cleaned up as an orphan.
    expect(await vault.read(staged), isNull);
    final error = fixture.connections.state.editorError!;
    expect(error, isNot(contains('old-token')));
    expect(error, isNot(contains('new-token')));
  });

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
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'old-token');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(alias: 'Renamed', bearerToken: 'new-token'),
    );
    repository.failSave = true;
    expect(await fixture.connections.saveDraft(), isFalse);

    final stored = await repository.load(remoteId);
    expect(stored!.alias, 'Remote');
    expect(stored.revision, 0);
    expect(
      (stored.transport as McpHttpTransportConfig).bearerSecret,
      legacyBearer,
    );
    expect(await vault.read(legacyBearer), 'old-token');
    expect(await vault.read(stagedRef('mcp.remote.bearer.1')), isNull);
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
      secretRefIds: counterRefIds(),
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
    expect(await vault.read(stagedRef('mcp.created.bearer.1')), isNull);
    expect(fixture.connections.state.editorError, isNotNull);
    expect(
      fixture.connections.state.editorError,
      isNot(contains('created-secret')),
    );
  });

  test('a vault write that commits then throws is verified and used', () async {
    final vault = CommitThenThrowMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'created': () => remoteConnection('created'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Created',
        connectionId: 'created',
        url: 'https://mcp.example.com/created',
        bearerToken: 'committed-secret',
      ),
    );
    expect(await fixture.connections.saveDraft(), isTrue);

    final stored = await fixture.repository.load(McpConnectionId('created'));
    final reference =
        (stored!.transport as McpHttpTransportConfig).bearerSecret;
    expect(reference, stagedRef('mcp.created.bearer.1'));
    expect(await vault.read(reference!), 'committed-secret');
    expect(fixture.connections.state.draft, isNull);
  });

  test('a vault write that throws before commit aborts the save', () async {
    final vault = FailBeforeCommitMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'created': () => remoteConnection('created'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);

    fixture.connections.beginCreate();
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(
        alias: 'Created',
        connectionId: 'created',
        url: 'https://mcp.example.com/created',
        bearerToken: 'never-committed',
      ),
    );
    expect(await fixture.connections.saveDraft(), isFalse);

    expect(await fixture.repository.load(McpConnectionId('created')), isNull);
    expect(await vault.read(stagedRef('mcp.created.bearer.1')), isNull);
    expect(fixture.connections.state.editorError, isNotNull);
    expect(
      fixture.connections.state.editorError,
      isNot(contains('never-committed')),
    );
  });

  test(
    'a config save that commits then throws reports committed truth',
    () async {
      final repository = CommitThenThrowMcpConnectionRepository(
        InMemoryMcpConnectionRepository(),
      );
      final vault = InMemoryMcpSecretVault();
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection('remote'),
        },
        repository: repository,
        vault: vault,
        secretRefIds: counterRefIds(),
      );
      addTearDown(fixture.dispose);
      repository.throwAfterSave = false;
      await fixture.saveConnection(httpConfig('remote'));
      await vault.write(legacyBearer, 'old-token');

      repository.throwAfterSave = true;
      expect(await fixture.connections.beginEdit('remote'), isTrue);
      fixture.connections.updateDraft(
        (draft) => draft.copyWith(alias: 'Renamed', bearerToken: 'new-token'),
      );
      expect(await fixture.connections.saveDraft(), isTrue);

      final stored = await repository.inner.load(remoteId);
      expect(stored!.alias, 'Renamed');
      final reference =
          (stored.transport as McpHttpTransportConfig).bearerSecret;
      expect(reference, stagedRef('mcp.remote.bearer.1'));
      expect(await vault.read(reference!), 'new-token');
      // Superseded legacy reference is cleaned up and the editor closed.
      expect(await vault.read(legacyBearer), isNull);
      expect(fixture.connections.state.draft, isNull);
      expect(fixture.connections.state.error, isNull);
    },
  );

  test(
    'successful replacement uses a fresh ref and keeps it on later edits',
    () async {
      final vault = InMemoryMcpSecretVault();
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection('remote'),
        },
        vault: vault,
        secretRefIds: counterRefIds(),
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(httpConfig('remote'));
      await vault.write(legacyBearer, 'old-token');

      expect(await fixture.connections.beginEdit('remote'), isTrue);
      fixture.connections.updateDraft(
        (draft) => draft.copyWith(bearerToken: 'new-token'),
      );
      expect(await fixture.connections.saveDraft(), isTrue);

      final replaced = await fixture.repository.load(remoteId);
      final freshReference =
          (replaced!.transport as McpHttpTransportConfig).bearerSecret;
      expect(freshReference, stagedRef('mcp.remote.bearer.1'));
      expect(await vault.read(freshReference!), 'new-token');
      expect(await vault.read(legacyBearer), isNull);
      expect(fixture.connections.state.secretCleanupFailures, isEmpty);

      // A later alias-only edit preserves the versioned reference and value.
      expect(await fixture.connections.beginEdit('remote'), isTrue);
      expect(fixture.connections.state.draft!.bearerTokenStored, isTrue);
      fixture.connections.updateDraft(
        (draft) => draft.copyWith(alias: 'Renamed'),
      );
      expect(await fixture.connections.saveDraft(), isTrue);
      final preserved = await fixture.repository.load(remoteId);
      expect(
        (preserved!.transport as McpHttpTransportConfig).bearerSecret,
        freshReference,
      );
      expect(await vault.read(freshReference), 'new-token');
    },
  );

  test('concurrent writers never share a staged reference', () async {
    final vault = GatedMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'old-token');
    final staged = stagedRef('mcp.remote.bearer.1');

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    fixture.connections.updateDraft(
      (draft) => draft.copyWith(bearerToken: 'new-token'),
    );
    vault.armWriteGate(staged);
    final saving = fixture.connections.saveDraft();
    await vault.waitForWriteGate();

    // The other writer owns the legacy reference and replaces its value.
    final current = await fixture.repository.load(remoteId);
    await vault.inner.write(legacyBearer, 'external-token');
    await fixture.host.upsertConnection(
      current!.copyWith(alias: 'External alias'),
      connect: false,
    );
    vault.releaseWriteGate();
    expect(await saving, isFalse);

    final stored = await fixture.repository.load(remoteId);
    expect(stored!.alias, 'External alias');
    expect(
      (stored.transport as McpHttpTransportConfig).bearerSecret,
      legacyBearer,
    );
    expect(await vault.read(legacyBearer), 'external-token');
    expect(await vault.read(staged), isNull);
  });

  test(
    'arbitrary secure env names and the bearer both use fresh refs',
    () async {
      final vault = InMemoryMcpSecretVault();
      final fixture = await McpFeatureFixture.create(
        vault: vault,
        secretRefIds: counterRefIds(),
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
      fixture.connections.setSecretEnvironmentVariable('API_TOKEN', 's1');
      fixture.connections.setSecretEnvironmentVariable('SECOND_2', 's2');
      expect(await fixture.connections.saveDraft(), isTrue);

      final local = McpConnectionId('local');
      var stored = await fixture.repository.load(local);
      var transport = stored!.transport as McpStdioTransportConfig;
      expect(
        transport.secretEnvironment['API_TOKEN'],
        stagedRef('mcp.local.env.API_TOKEN.1'),
      );
      expect(
        transport.secretEnvironment['SECOND_2'],
        stagedRef('mcp.local.env.SECOND_2.2'),
      );
      expect(await vault.read(transport.secretEnvironment['API_TOKEN']!), 's1');
      expect(await vault.read(transport.secretEnvironment['SECOND_2']!), 's2');
      // Stored refs stay hidden from the transport label and config JSON.
      expect(stored.toJson().toString(), isNot(contains('s1')));
      expect(stored.toJson().toString(), isNot(contains('s2')));

      // Adding a third secret stages a new ref and preserves the others.
      expect(await fixture.connections.beginEdit('local'), isTrue);
      fixture.connections.setSecretEnvironmentVariable('THIRD_3', 's3');
      expect(await fixture.connections.saveDraft(), isTrue);
      stored = await fixture.repository.load(local);
      transport = stored!.transport as McpStdioTransportConfig;
      expect(
        transport.secretEnvironment['API_TOKEN'],
        stagedRef('mcp.local.env.API_TOKEN.1'),
      );
      expect(
        transport.secretEnvironment['SECOND_2'],
        stagedRef('mcp.local.env.SECOND_2.2'),
      );
      expect(
        transport.secretEnvironment['THIRD_3'],
        stagedRef('mcp.local.env.THIRD_3.3'),
      );
      expect(await vault.read(transport.secretEnvironment['THIRD_3']!), 's3');
    },
  );

  test('a failed repository read is visible and blocks the mutation', () async {
    final repository = FailingReadMcpConnectionRepository(
      InMemoryMcpConnectionRepository(),
    );
    final fixture = await McpFeatureFixture.create(
      repository: repository,
      startHost: false,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    repository.failLoad = false;
    await fixture.saveConnection(httpConfig('remote'));
    expect(repository.saveCalls, 1);

    repository.failLoad = true;
    await fixture.connections.setEnabled('remote', false);
    expect(fixture.connections.state.error, isNotNull);
    // No full-config write was attempted from a cached snapshot.
    expect(repository.saveCalls, 1);
    final stored = await repository.inner.load(remoteId);
    expect(stored!.enabled, isTrue);

    expect(await fixture.connections.beginEdit('remote'), isFalse);
    expect(fixture.connections.state.editorError, isNotNull);

    // With an open editor, an authoritative-read failure is a visible probe
    // failure instead of a probe against guessed references.
    repository.failLoad = false;
    expect(await fixture.connections.beginEdit('remote'), isTrue);
    repository.failLoad = true;
    await fixture.connections.checkDraft();
    expect(fixture.connections.state.probeStatus, McpProbeStatus.failure);
    expect(fixture.connections.state.probeResult!.error, isNotNull);
  });

  test(
    'setEnabled preserves an edit that lands during its first read',
    () async {
      final repository = GatedLoadMcpConnectionRepository(
        InMemoryMcpConnectionRepository(),
      );
      final fixture = await McpFeatureFixture.create(
        builders: <String, ScriptedMcpConnection Function()>{
          'remote': () => remoteConnection('remote'),
        },
        repository: repository,
        secretRefIds: counterRefIds(),
      );
      addTearDown(fixture.dispose);
      await fixture.saveConnection(
        httpConfig('remote', url: 'https://mcp.example.com/remote'),
      );

      repository.armLoadGate(remoteId);
      final enabling = fixture.connections.setEnabled('remote', false);
      await repository.waitForLoadGate();
      // A concurrent writer changes the endpoint while the read is in flight.
      final current = await repository.inner.load(remoteId);
      await fixture.host.upsertConnection(
        current!.copyWith(
          alias: 'Edited alias',
          transport: McpHttpTransportConfig(
            url: 'https://edited.example.com/mcp',
            bearerSecret: legacyBearer,
          ),
        ),
        connect: false,
      );
      repository.releaseLoadGate();
      await enabling;

      final stored = await repository.inner.load(remoteId);
      expect(stored!.alias, 'Edited alias');
      expect(stored.enabled, isFalse);
      expect(
        (stored.transport as McpHttpTransportConfig).url,
        'https://edited.example.com/mcp',
      );
    },
  );

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
        secretRefIds: counterRefIds(),
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
        secretRefIds: counterRefIds(),
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

  test('a stored secret echoed by the transport is redacted as well', () async {
    const stored = 'storedTokenValue999';
    final vault = InMemoryMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      probeTransports: EchoingSecretMcpTransportFactory(),
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, stored);

    expect(await fixture.connections.beginEdit('remote'), isTrue);
    // The form leaves the token field empty and keeps the stored value.
    await fixture.connections.checkDraft();

    final result = fixture.connections.state.probeResult!;
    expect(result.ok, isFalse);
    expect(result.error, isNot(contains(stored)));
    expect(result.error, sanitizedMcpUnavailableMessage());
  });

  test('a failed secret cleanup after removal is visible', () async {
    final vault = FlakyDeleteMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'stored-token');

    vault.failDelete = true;
    expect(await fixture.connections.removeConnection('remote'), isTrue);
    expect(await fixture.repository.load(remoteId), isNull);
    expect(await vault.read(legacyBearer), 'stored-token');
    final state = fixture.connections.state;
    expect(
      state.error,
      isNotNull,
      reason: 'a swallowed cleanup failure must stay visible',
    );
    expect(state.toString(), isNot(contains('stored-token')));
  });

  test('a failed cleanup stays visible until a successful retry', () async {
    final vault = FlakyDeleteMcpSecretVault();
    final fixture = await McpFeatureFixture.create(
      builders: <String, ScriptedMcpConnection Function()>{
        'remote': () => remoteConnection('remote'),
      },
      vault: vault,
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'stored-token');

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
    expect(await vault.read(legacyBearer), isNull);
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
      secretRefIds: counterRefIds(),
    );
    addTearDown(fixture.dispose);
    await fixture.saveConnection(httpConfig('remote'));
    await vault.write(legacyBearer, 'stored-token');

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
    expect(await vault.read(legacyBearer), 'stored-token');

    vault.failDelete = false;
    expect(await fixture.connections.retrySecretCleanup('remote'), isTrue);
    expect(await vault.read(legacyBearer), isNull);
    expect(fixture.connections.state.secretCleanupFailures, isEmpty);
  });
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
