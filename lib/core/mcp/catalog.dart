import 'ids.dart';
import 'naming.dart';
import 'protocol.dart';

/// Mapping between a model-facing tool name and its server identity.
final class McpToolRoute {
  const McpToolRoute({
    required this.connectionId,
    required this.modelToolName,
    required this.descriptor,
  });

  final McpConnectionId connectionId;
  final McpModelToolName modelToolName;
  final McpToolDescriptor descriptor;

  String get originalToolName => descriptor.originalName;

  Map<String, Object?> toJson() => <String, Object?>{
    'connectionId': connectionId.value,
    'tool': originalToolName,
    'modelName': modelToolName.value,
  };

  @override
  String toString() =>
      'McpToolRoute(${modelToolName.value} -> '
      '${connectionId.value}/$originalToolName)';
}

/// Immutable catalog snapshot with the routing table for the whole host.
final class McpCatalog {
  McpCatalog({required this.revision, required List<McpToolRoute> routes})
    : routes = List<McpToolRoute>.unmodifiable(
        routes.toList(growable: false)..sort(
          (a, b) => a.modelToolName.value.compareTo(b.modelToolName.value),
        ),
      ),
      _byModelName = Map<String, McpToolRoute>.unmodifiable(
        <String, McpToolRoute>{
          for (final route in routes) route.modelToolName.value: route,
        },
      ),
      _byConnection = Map<String, List<McpToolRoute>>.unmodifiable(
        _groupByConnection(routes),
      );

  static final McpCatalog empty = McpCatalog(
    revision: 0,
    routes: const <McpToolRoute>[],
  );

  final int revision;
  final List<McpToolRoute> routes;
  final Map<String, McpToolRoute> _byModelName;
  final Map<String, List<McpToolRoute>> _byConnection;

  int get length => routes.length;

  bool get isEmpty => routes.isEmpty;

  McpToolRoute? lookup(String modelToolName) => _byModelName[modelToolName];

  List<McpToolRoute> forConnection(McpConnectionId connectionId) =>
      _byConnection[connectionId.value] ?? const <McpToolRoute>[];

  bool containsConnection(McpConnectionId connectionId) =>
      _byConnection.containsKey(connectionId.value);

  static Map<String, List<McpToolRoute>> _groupByConnection(
    Iterable<McpToolRoute> routes,
  ) {
    final grouped = <String, List<McpToolRoute>>{};
    for (final route in routes) {
      grouped
          .putIfAbsent(route.connectionId.value, () => <McpToolRoute>[])
          .add(route);
    }
    return grouped;
  }
}

/// Builds a [McpCatalog] with deterministic names and collision handling.
final class McpCatalogBuilder {
  McpCatalogBuilder({
    this.policy = const McpToolNamePolicy(),
    this.revision = 1,
  });

  final McpToolNamePolicy policy;
  final int revision;
  final List<McpToolDescriptor> _tools = <McpToolDescriptor>[];

  /// Adds or replaces the full tool catalog of one connection.
  void addConnection(
    McpConnectionId connectionId,
    Iterable<McpToolDescriptor> tools,
  ) {
    _tools.removeWhere((tool) => tool.connectionId == connectionId);
    _tools.addAll(tools);
  }

  void removeConnection(McpConnectionId connectionId) {
    _tools.removeWhere((tool) => tool.connectionId == connectionId);
  }

  McpCatalog build() {
    final sorted = _tools.toList(growable: false)
      ..sort((a, b) {
        final byConnection = a.connectionId.value.compareTo(
          b.connectionId.value,
        );
        if (byConnection != 0) {
          return byConnection;
        }
        return a.originalName.compareTo(b.originalName);
      });
    final seenPairs = <String>{};
    final usedNames = <String>{};
    final routes = <McpToolRoute>[];
    for (final tool in sorted) {
      final pairKey = '${tool.connectionId.value}\u0000${tool.originalName}';
      if (!seenPairs.add(pairKey)) {
        continue;
      }
      final route = McpToolRoute(
        connectionId: tool.connectionId,
        modelToolName: _allocateName(tool, usedNames),
        descriptor: tool,
      );
      routes.add(route);
    }
    return McpCatalog(revision: revision, routes: routes);
  }

  McpModelToolName _allocateName(
    McpToolDescriptor tool,
    Set<String> usedNames,
  ) {
    final base = policy.candidate(
      connectionId: tool.connectionId,
      originalToolName: tool.originalName,
    );
    var candidate = base;
    var ordinal = 1;
    while (!usedNames.add(candidate)) {
      ordinal += 1;
      candidate = policy.withOrdinal(base, ordinal);
    }
    return McpModelToolName(candidate);
  }
}
