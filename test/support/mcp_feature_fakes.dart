import 'dart:async';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/mcp/application/mcp_connection_probe.dart';
import 'package:domovoy/features/mcp/application/mcp_connections_controller.dart';
import 'package:domovoy/features/mcp/application/mcp_tool_access_controller.dart';
import 'package:domovoy/features/mcp/domain/platform_capabilities.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';

import 'mcp_fakes.dart';

/// Vault whose writes for one reference can be paused by the test.
final class GatedMcpSecretVault implements McpSecretVault {
  GatedMcpSecretVault([Map<String, String>? initial])
    : inner = InMemoryMcpSecretVault(initial);

  final InMemoryMcpSecretVault inner;
  McpSecretReference? _gateReference;
  Completer<void>? _writeGate;
  Completer<void>? _writeReached;

  void armWriteGate(McpSecretReference reference) {
    _gateReference = reference;
    _writeGate = Completer<void>();
    _writeReached = Completer<void>();
  }

  Future<void> waitForWriteGate() => _writeReached!.future;

  /// Optional hook awaited after a value is stored, to simulate a writer that
  /// lands immediately after ours.
  Future<void> Function(McpSecretReference reference)? onAfterWrite;

  void releaseWriteGate() {
    _writeGate?.complete();
    _writeGate = null;
    _gateReference = null;
  }

  @override
  Future<String?> read(McpSecretReference reference) => inner.read(reference);

  @override
  Future<void> write(McpSecretReference reference, String value) async {
    if (_gateReference == reference && _writeGate != null) {
      _writeReached!.complete();
      await _writeGate!.future;
    }
    await inner.write(reference, value);
    final hook = onAfterWrite;
    if (hook != null) {
      await hook(reference);
    }
  }

  @override
  Future<void> delete(McpSecretReference reference) => inner.delete(reference);
}

/// Repository that fails `save` on demand, simulating a persistence failure
/// after the vault was already updated.
final class FailingSaveMcpConnectionRepository
    implements McpConnectionRepository {
  FailingSaveMcpConnectionRepository(this.inner);

  final McpConnectionRepository inner;
  bool failSave = false;

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) => inner.load(id);

  @override
  Future<List<McpConnectionConfig>> loadAll() => inner.loadAll();

  @override
  Future<Map<String, int>> loadTombstones() => inner.loadTombstones();

  @override
  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (failSave) {
      return Future<void>.error(
        McpException(
          McpError(
            kind: McpErrorKind.persistence,
            message: sanitizedMcpPersistenceMessage(),
          ),
        ),
      );
    }
    return inner.save(
      config,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    McpConnectionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => inner.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );
}

/// Vault that fails deletions on demand.
final class FlakyDeleteMcpSecretVault implements McpSecretVault {
  FlakyDeleteMcpSecretVault([Map<String, String>? initial])
    : inner = InMemoryMcpSecretVault(initial);

  final InMemoryMcpSecretVault inner;
  bool failDelete = false;

  @override
  Future<String?> read(McpSecretReference reference) => inner.read(reference);

  @override
  Future<void> write(McpSecretReference reference, String value) =>
      inner.write(reference, value);

  @override
  Future<void> delete(McpSecretReference reference) {
    if (failDelete) {
      return Future<void>.error(StateError('delete failed'));
    }
    return inner.delete(reference);
  }
}

/// Shared fixture for B7 controller and widget tests.
final class McpFeatureFixture {
  McpFeatureFixture._({
    required this.repository,
    required this.vault,
    required this.transports,
    required this.host,
    required this.connections,
    required this.toolAccess,
    required this.selectionStore,
  });

  final McpConnectionRepository repository;
  final McpSecretVault vault;
  final ScriptedMcpTransportFactory transports;
  final McpHostManager host;
  final McpConnectionsController connections;
  final McpToolAccessController toolAccess;
  final McpToolSelectionStore selectionStore;

  static Future<McpFeatureFixture> create({
    Map<String, ScriptedMcpConnection Function()> builders =
        const <String, ScriptedMcpConnection Function()>{},
    McpPlatformCapabilities capabilities = McpPlatformCapabilities.desktop,
    Set<String> builtInConnectionIds = const <String>{},
    Map<String, String> Function()? unavailableReasons,
    McpToolSelectionStore? selectionStore,
    McpConnectionRepository? repository,
    McpSecretVault? vault,
    McpTransportFactory? probeTransports,
    McpTimeouts timeouts = const McpTimeouts(
      connect: Duration(milliseconds: 200),
      catalog: Duration(milliseconds: 200),
    ),
    bool startHost = true,
  }) async {
    final resolvedRepository = repository ?? InMemoryMcpConnectionRepository();
    final resolvedVault = vault ?? InMemoryMcpSecretVault();
    final transports = ScriptedMcpTransportFactory(builders);
    final host = McpHostManager(
      transports: transports,
      repository: resolvedRepository,
      secrets: resolvedVault,
      timeouts: timeouts,
      reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
      delay: (duration) async {},
    );
    final resolvedSelections =
        selectionStore ?? InMemoryMcpToolSelectionStore();
    final connections = McpConnectionsController(
      host: host,
      repository: resolvedRepository,
      secrets: resolvedVault,
      capabilities: capabilities,
      probe: McpConnectionProbe(
        transports: probeTransports ?? transports,
        timeouts: timeouts,
      ),
      hostChanges: host,
      builtInConnectionIds: builtInConnectionIds,
    );
    final toolAccess = McpToolAccessController(
      host: host,
      store: resolvedSelections,
      hostChanges: host,
      unavailableReasons: unavailableReasons,
    );
    await connections.initialize();
    await toolAccess.initialize();
    if (startHost) {
      await host.start();
    }
    return McpFeatureFixture._(
      repository: resolvedRepository,
      vault: resolvedVault,
      transports: transports,
      host: host,
      connections: connections,
      toolAccess: toolAccess,
      selectionStore: resolvedSelections,
    );
  }

  Future<void> saveConnection(
    McpConnectionConfig config, {
    bool connect = false,
  }) => host.upsertConnection(config, connect: connect);

  Future<void> dispose() async {
    connections.dispose();
    toolAccess.dispose();
    await host.stop();
    host.dispose();
  }
}
