import '../llm/cancellation.dart';
import 'catalog.dart';
import 'connection.dart';
import 'ids.dart';
import 'protocol.dart';
import 'transport.dart';

/// Default deadlines used by the host when the caller supplies none.
final class McpTimeouts {
  const McpTimeouts({
    this.connect = const Duration(seconds: 20),
    this.catalog = const Duration(seconds: 20),
    this.call = const Duration(minutes: 2),
  });

  final Duration connect;
  final Duration catalog;
  final Duration call;
}

/// Reads secret values by secure-storage reference.
abstract interface class McpSecretResolver {
  Future<String?> read(McpSecretReference reference);
}

/// Read/write secret storage used by settings and tests.
abstract interface class McpSecretVault implements McpSecretResolver {
  Future<void> write(McpSecretReference reference, String value);

  Future<void> delete(McpSecretReference reference);
}

/// In-memory vault for tests and for platforms without secure storage.
final class InMemoryMcpSecretVault implements McpSecretVault {
  InMemoryMcpSecretVault([Map<String, String>? initial])
    : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(McpSecretReference reference) async =>
      _values[reference.storeKey];

  @override
  Future<void> write(McpSecretReference reference, String value) async {
    _values[reference.storeKey] = value;
  }

  @override
  Future<void> delete(McpSecretReference reference) async {
    _values.remove(reference.storeKey);
  }
}

/// One live MCP client session owned by the host.
abstract interface class McpTransportConnection {
  McpConnectionId get connectionId;

  McpTransportKind get kind;

  bool get isConnected;

  /// Invoked when the peer closes the session without an explicit `close()`.
  void Function()? get onUnexpectedClose;

  set onUnexpectedClose(void Function()? callback);

  /// Invoked when the server announces that its tool catalog changed.
  void Function()? get onToolsChanged;

  set onToolsChanged(void Function()? callback);

  Future<McpHandshake> connect({
    required Duration timeout,
    required CancellationToken cancellation,
  });

  /// Requests one page of `tools/list`.
  Future<McpToolPage> listTools({
    String? cursor,
    required Duration timeout,
    required CancellationToken cancellation,
  });

  Future<McpToolCallResult> callTool({
    required String originalToolName,
    required Map<String, Object?> arguments,
    required Duration timeout,
    required CancellationToken cancellation,
    void Function(double progress)? onProgress,
  });

  Future<void> close();
}

/// Builds transport connections without exposing SDK types to `core`.
abstract interface class McpTransportFactory {
  Future<McpTransportConnection> create(
    McpConnectionConfig config, {
    required McpSecretResolver secrets,
  });
}

/// Lifecycle phase of one configured connection.
enum McpConnectionPhase { disabled, stopped, connecting, ready, failed }

final class McpConnectionStatus {
  const McpConnectionStatus({
    required this.id,
    required this.alias,
    required this.phase,
    this.handshake,
    this.toolCount = 0,
    this.lastError,
    this.updatedAt,
  });

  final McpConnectionId id;
  final String alias;
  final McpConnectionPhase phase;
  final McpHandshake? handshake;
  final int toolCount;
  final String? lastError;
  final DateTime? updatedAt;

  bool get isReady => phase == McpConnectionPhase.ready;

  McpConnectionStatus copyWith({
    String? alias,
    McpConnectionPhase? phase,
    McpHandshake? handshake,
    bool clearHandshake = false,
    int? toolCount,
    String? lastError,
    bool clearError = false,
    DateTime? updatedAt,
  }) {
    return McpConnectionStatus(
      id: id,
      alias: alias ?? this.alias,
      phase: phase ?? this.phase,
      handshake: clearHandshake ? null : handshake ?? this.handshake,
      toolCount: toolCount ?? this.toolCount,
      lastError: clearError ? null : lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'connectionId': id.value,
    'alias': alias,
    'phase': phase.name,
    if (handshake != null) 'handshake': handshake!.toJson(),
    'toolCount': toolCount,
    if (lastError != null) 'lastError': lastError,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };
}

/// Immutable host view: connection statuses plus the current catalog.
final class McpHostSnapshot {
  const McpHostSnapshot({
    required this.revision,
    required this.connections,
    required this.catalog,
  });

  static final McpHostSnapshot empty = McpHostSnapshot(
    revision: 0,
    connections: const <McpConnectionStatus>[],
    catalog: McpCatalog.empty,
  );

  final int revision;
  final List<McpConnectionStatus> connections;
  final McpCatalog catalog;

  McpConnectionStatus? statusFor(McpConnectionId id) {
    for (final status in connections) {
      if (status.id == id) {
        return status;
      }
    }
    return null;
  }
}

/// Human-readable lifecycle and call traces.
sealed class McpHostEvent {
  const McpHostEvent({required this.at});

  final DateTime at;
}

final class McpConnectionPhaseChanged extends McpHostEvent {
  const McpConnectionPhaseChanged({
    required super.at,
    required this.connectionId,
    required this.phase,
    this.error,
  });

  final McpConnectionId connectionId;
  final McpConnectionPhase phase;
  final String? error;

  @override
  String toString() =>
      'McpConnectionPhaseChanged(${connectionId.value}, ${phase.name})';
}

final class McpCatalogChanged extends McpHostEvent {
  const McpCatalogChanged({
    required super.at,
    required this.revision,
    required this.toolCount,
    required this.changedConnections,
  });

  final int revision;
  final int toolCount;
  final List<McpConnectionId> changedConnections;

  @override
  String toString() => 'McpCatalogChanged(rev $revision, $toolCount tools)';
}

final class McpToolCallCompleted extends McpHostEvent {
  const McpToolCallCompleted({
    required super.at,
    required this.modelToolName,
    required this.connectionId,
    required this.originalToolName,
    required this.isError,
    required this.duration,
  });

  final String modelToolName;
  final McpConnectionId connectionId;
  final String originalToolName;
  final bool isError;
  final Duration duration;

  @override
  String toString() =>
      'McpToolCallCompleted($modelToolName, isError: $isError, $duration)';
}

/// Host contract used by application controllers and agent bridges (B2).
abstract interface class McpHost {
  McpHostSnapshot get snapshot;

  Stream<McpHostEvent> get events;

  /// Loads stored connections and connects the enabled ones.
  Future<void> start({CancellationToken? cancellation});

  /// Disconnects every client and stops every owned server.
  Future<void> stop();

  Future<void> upsertConnection(
    McpConnectionConfig config, {
    bool connect = true,
  });

  Future<void> removeConnection(McpConnectionId id);

  Future<void> connect(McpConnectionId id);

  Future<void> disconnect(McpConnectionId id);

  /// Tears the connection down and connects it again, refreshing its catalog.
  Future<void> restart(McpConnectionId id);

  /// Refreshes every connection, or just [id] when given.
  Future<void> refreshCatalog([McpConnectionId? id]);

  /// Routes a model-facing name to `(connectionId, originalToolName)`.
  Future<McpToolCallResult> callTool({
    required String modelToolName,
    required Map<String, Object?> arguments,
    Duration? timeout,
    CancellationToken? cancellation,
    void Function(double progress)? onProgress,
  });
}
