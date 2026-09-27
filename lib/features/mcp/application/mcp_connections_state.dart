import '../../../core/mcp/mcp.dart';
import '../application/mcp_connection_probe.dart';
import '../domain/connection_draft.dart';

enum McpConnectionsStatus { loading, ready, failed }

enum McpProbeStatus { idle, running, success, failure }

/// One connection row: persisted configuration plus live host state.
final class McpConnectionEntry {
  const McpConnectionEntry({
    required this.config,
    required this.status,
    required this.routes,
    required this.isBuiltIn,
  });

  final McpConnectionConfig config;
  final McpConnectionStatus? status;
  final List<McpToolRoute> routes;
  final bool isBuiltIn;

  String get id => config.connectionId.value;
  String get alias => config.alias;
  bool get enabled => config.enabled;
  bool get isReady => status?.phase == McpConnectionPhase.ready;
  bool get isConnected => status?.phase == McpConnectionPhase.ready;
  McpHandshake? get handshake => status?.handshake;
  int get toolCount => routes.length;
  String? get lastError => status?.lastError;

  bool get canEdit => !isBuiltIn;

  String get transportLabel => switch (config.transport) {
    McpStdioTransportConfig() => 'stdio',
    McpHttpTransportConfig(:final isLoopback) =>
      isLoopback ? 'HTTP (loopback)' : 'Streamable HTTP',
    McpInProcessStreamTransportConfig() => 'встроенный',
  };
}

final class McpConnectionsState {
  const McpConnectionsState({
    this.status = McpConnectionsStatus.loading,
    this.connections = const <McpConnectionEntry>[],
    this.error,
    this.draft,
    this.selectedConnectionId,
    this.probeStatus = McpProbeStatus.idle,
    this.probeResult,
    this.busyConnectionIds = const <String>{},
    this.saving = false,
    this.editorError,
    this.configurationError,
    this.revision = 0,
  });

  final McpConnectionsStatus status;
  final List<McpConnectionEntry> connections;
  final String? error;
  final McpConnectionDraft? draft;
  final String? selectedConnectionId;
  final McpProbeStatus probeStatus;
  final McpProbeResult? probeResult;
  final Set<String> busyConnectionIds;
  final bool saving;
  final String? editorError;

  /// Stored configuration could not be read; shown instead of a silent empty
  /// list.
  final McpError? configurationError;

  final int revision;

  bool get isLoading => status == McpConnectionsStatus.loading;
  bool get hasConnections => connections.isNotEmpty;
  bool get isProbing => probeStatus == McpProbeStatus.running;
  bool get isEditorOpen => draft != null;

  McpConnectionEntry? entry(String connectionId) {
    for (final connection in connections) {
      if (connection.id == connectionId) {
        return connection;
      }
    }
    return null;
  }

  McpConnectionEntry? get selectedEntry {
    final id = selectedConnectionId;
    return id == null ? null : entry(id);
  }

  List<McpConnectionEntry> get externalConnections =>
      connections.where((connection) => !connection.isBuiltIn).toList();

  McpConnectionsState copyWith({
    McpConnectionsStatus? status,
    List<McpConnectionEntry>? connections,
    String? error,
    bool clearError = false,
    McpConnectionDraft? draft,
    bool clearDraft = false,
    String? selectedConnectionId,
    bool clearSelection = false,
    McpProbeStatus? probeStatus,
    McpProbeResult? probeResult,
    bool clearProbeResult = false,
    Set<String>? busyConnectionIds,
    bool? saving,
    String? editorError,
    bool clearEditorError = false,
    McpError? configurationError,
    bool clearConfigurationError = false,
    int? revision,
  }) {
    return McpConnectionsState(
      status: status ?? this.status,
      connections: connections ?? this.connections,
      error: clearError ? null : error ?? this.error,
      draft: clearDraft ? null : draft ?? this.draft,
      selectedConnectionId: clearSelection
          ? null
          : selectedConnectionId ?? this.selectedConnectionId,
      probeStatus: probeStatus ?? this.probeStatus,
      probeResult: clearProbeResult ? null : probeResult ?? this.probeResult,
      busyConnectionIds: busyConnectionIds ?? this.busyConnectionIds,
      saving: saving ?? this.saving,
      editorError: clearEditorError ? null : editorError ?? this.editorError,
      configurationError: clearConfigurationError
          ? null
          : configurationError ?? this.configurationError,
      revision: revision ?? this.revision,
    );
  }
}
