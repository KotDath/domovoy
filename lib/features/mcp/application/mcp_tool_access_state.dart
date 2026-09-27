import '../../../core/mcp/mcp.dart';

enum McpToolAccessStatus { loading, ready, failed }

/// One selectable tool in the permission view.
final class McpToolAccessTool {
  const McpToolAccessTool({
    required this.toolId,
    required this.originalName,
    required this.selected,
    required this.inCatalog,
    this.title,
    this.description,
    this.destructive = false,
    this.unavailableReason,
    this.connectionUnavailableReason,
  });

  /// B2 stable identity used in grants and persisted selections.
  final String toolId;
  final String originalName;
  final bool selected;
  final bool inCatalog;
  final String? title;
  final String? description;
  final bool destructive;

  /// Reason this catalog tool cannot be offered for this provider.
  final String? unavailableReason;

  /// Reason the owning connection is currently unusable, if any.
  final String? connectionUnavailableReason;

  bool get isAvailable => inCatalog && unavailableReason == null;
}

/// Tools grouped by their owning connection.
final class McpToolAccessConnection {
  const McpToolAccessConnection({
    required this.connectionId,
    required this.alias,
    required this.tools,
    this.enabled = true,
    this.connected = false,
    this.unavailableReason,
  });

  final McpConnectionId connectionId;
  final String alias;
  final List<McpToolAccessTool> tools;
  final bool enabled;
  final bool connected;
  final String? unavailableReason;

  int get selectedCount => tools.where((tool) => tool.selected).length;
}

final class McpToolAccessState {
  const McpToolAccessState({
    this.status = McpToolAccessStatus.loading,
    this.target,
    this.scope = McpToolAccessTargetKind.chat,
    this.hasChat = false,
    this.hasProject = false,
    this.error,
    this.connections = const <McpToolAccessConnection>[],
    this.selectedToolIds = const <String>{},
    this.missingSelectedToolIds = const <String>[],
    this.busy = false,
    this.revision = 0,
  });

  final McpToolAccessStatus status;
  final McpToolAccessTarget? target;
  final McpToolAccessTargetKind scope;
  final bool hasChat;
  final bool hasProject;
  final String? error;
  final List<McpToolAccessConnection> connections;

  /// Selection of the current scope target.
  final Set<String> selectedToolIds;

  /// Stored selections that are absent from the live catalog.
  final List<String> missingSelectedToolIds;

  final bool busy;
  final int revision;

  bool get isReady => status == McpToolAccessStatus.ready;
  bool get isLoading => status == McpToolAccessStatus.loading;

  int get selectedCount => selectedToolIds.length;

  McpToolAccessState copyWith({
    McpToolAccessStatus? status,
    McpToolAccessTarget? target,
    McpToolAccessTargetKind? scope,
    bool? hasChat,
    bool? hasProject,
    String? error,
    bool clearError = false,
    List<McpToolAccessConnection>? connections,
    Set<String>? selectedToolIds,
    List<String>? missingSelectedToolIds,
    bool? busy,
    int? revision,
  }) {
    return McpToolAccessState(
      status: status ?? this.status,
      target: target ?? this.target,
      scope: scope ?? this.scope,
      hasChat: hasChat ?? this.hasChat,
      hasProject: hasProject ?? this.hasProject,
      error: clearError ? null : error ?? this.error,
      connections: connections ?? this.connections,
      selectedToolIds: selectedToolIds ?? this.selectedToolIds,
      missingSelectedToolIds:
          missingSelectedToolIds ?? this.missingSelectedToolIds,
      busy: busy ?? this.busy,
      revision: revision ?? this.revision,
    );
  }
}
