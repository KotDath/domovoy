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
    String Function()? secretRefIds,
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
      secretRefIds: secretRefIds,
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

/// Vault that commits a write and then throws, like an adapter that lost the
/// response after the value was stored.
final class CommitThenThrowMcpSecretVault implements McpSecretVault {
  CommitThenThrowMcpSecretVault([Map<String, String>? initial])
    : inner = InMemoryMcpSecretVault(initial);

  final InMemoryMcpSecretVault inner;
  bool throwAfterWrite = true;

  @override
  Future<String?> read(McpSecretReference reference) => inner.read(reference);

  @override
  Future<void> write(McpSecretReference reference, String value) async {
    await inner.write(reference, value);
    if (throwAfterWrite) {
      throw StateError('vault write committed then failed');
    }
  }

  @override
  Future<void> delete(McpSecretReference reference) => inner.delete(reference);
}

/// Vault that throws before storing anything.
final class FailBeforeCommitMcpSecretVault implements McpSecretVault {
  FailBeforeCommitMcpSecretVault([Map<String, String>? initial])
    : inner = InMemoryMcpSecretVault(initial);

  final InMemoryMcpSecretVault inner;
  bool failWrite = true;

  @override
  Future<String?> read(McpSecretReference reference) => inner.read(reference);

  @override
  Future<void> write(McpSecretReference reference, String value) {
    if (failWrite) {
      return Future<void>.error(StateError('vault write failed'));
    }
    return inner.write(reference, value);
  }

  @override
  Future<void> delete(McpSecretReference reference) => inner.delete(reference);
}

/// Repository that commits a save and then throws.
final class CommitThenThrowMcpConnectionRepository
    implements McpConnectionRepository {
  CommitThenThrowMcpConnectionRepository(this.inner);

  final McpConnectionRepository inner;
  bool throwAfterSave = true;

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
  }) async {
    await inner.save(
      config,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
    if (throwAfterSave) {
      throw McpException(
        McpError(
          kind: McpErrorKind.persistence,
          message: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
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

/// Repository whose single-target read fails on demand, while writes are
/// counted so tests can prove no mutation was attempted.
final class FailingReadMcpConnectionRepository
    implements McpConnectionRepository {
  FailingReadMcpConnectionRepository(this.inner);

  final McpConnectionRepository inner;
  bool failLoad = true;
  int saveCalls = 0;

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) {
    if (failLoad) {
      return Future<McpConnectionConfig?>.error(
        McpException(
          McpError(
            kind: McpErrorKind.persistence,
            message: sanitizedMcpPersistenceMessage(),
          ),
        ),
      );
    }
    return inner.load(id);
  }

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
    saveCalls += 1;
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

/// Repository whose targeted read captures a snapshot and then waits, so a
/// test can commit a concurrent edit while the read is still in flight.
final class GatedLoadMcpConnectionRepository
    implements McpConnectionRepository {
  GatedLoadMcpConnectionRepository(this.inner);

  final McpConnectionRepository inner;
  McpConnectionId? _gateId;
  Completer<void>? _gate;
  Completer<void>? _reached;

  /// Gates only the next read of [id]; later reads pass through.
  void armLoadGate(McpConnectionId id) {
    _gateId = id;
    _gate = Completer<void>();
    _reached = Completer<void>();
  }

  Future<void> waitForLoadGate() => _reached!.future;

  void releaseLoadGate() {
    _gate?.complete();
    _gate = null;
    _gateId = null;
  }

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) async {
    final snapshot = await inner.load(id);
    if (_gateId == id && _gate != null && !_gate!.isCompleted) {
      _reached!.complete();
      await _gate!.future;
    }
    return snapshot;
  }

  @override
  Future<List<McpConnectionConfig>> loadAll() => inner.loadAll();

  @override
  Future<Map<String, int>> loadTombstones() => inner.loadTombstones();

  @override
  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => inner.save(
    config,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );

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

/// Vault that commits a staged write, then throws, and whose read-back is also
/// unavailable (a broken secure-storage adapter).
final class CommitThenThrowWithUnreadableReadbackVault
    implements McpSecretVault {
  CommitThenThrowWithUnreadableReadbackVault([Map<String, String>? initial])
    : inner = InMemoryMcpSecretVault(initial);

  final InMemoryMcpSecretVault inner;
  bool failReads = true;
  bool failDeletes = false;

  @override
  Future<String?> read(McpSecretReference reference) {
    if (failReads) {
      return Future<String?>.error(StateError('vault read unavailable'));
    }
    return inner.read(reference);
  }

  @override
  Future<void> write(McpSecretReference reference, String value) async {
    await inner.write(reference, value);
    throw StateError('vault write committed then failed');
  }

  @override
  Future<void> delete(McpSecretReference reference) {
    if (failDeletes) {
      return Future<void>.error(StateError('vault delete failed'));
    }
    return inner.delete(reference);
  }
}

/// Repository that deletes the target between two reads, so the second read
/// observes a concurrent removal and returns `null`.
final class DeleteDuringSecondReadRepository
    implements McpConnectionRepository {
  DeleteDuringSecondReadRepository(this.inner);

  final McpConnectionRepository inner;
  McpConnectionId? target;
  int saveCalls = 0;
  int deleteCalls = 0;
  int _targetLoads = 0;

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) async {
    if (target == id) {
      _targetLoads += 1;
      if (_targetLoads == 2) {
        final existing = await inner.load(id);
        if (existing != null) {
          await inner.delete(
            id,
            expectedRevision: existing.revision,
            cancellation: CancellationSource().token,
          );
        }
        return null;
      }
    }
    return inner.load(id);
  }

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
    saveCalls += 1;
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
  }) {
    deleteCalls += 1;
    return inner.delete(
      id,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }
}
