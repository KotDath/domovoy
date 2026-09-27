import 'package:flutter/widgets.dart';

import '../../core/mcp/mcp.dart';
import 'application/mcp_connection_probe.dart';
import 'application/mcp_connections_controller.dart';
import 'application/mcp_tool_access_controller.dart';
import 'domain/platform_capabilities.dart';
import 'presentation/mcp_connections_page.dart';

/// Composition-ready MCP feature bundle for B9.
///
/// B9 constructs one instance with the already-composed host, repositories,
/// secure vault and platform capabilities, calls [initialize], embeds
/// [buildConnectionsPage] in settings, and passes [toolAccess] to the chat
/// pages for per-chat/project permission selection. Widgets themselves stay
/// here so production composition adds no UI code of its own.
///
/// ```dart
/// final mcp = McpFeature.build(
///   host: mcpHost,
///   repository: connectionRepository,
///   secrets: secretVault,
///   selections: JsonlMcpToolSelectionStore(
///     storage: createPlatformMcpJsonlStreamStorage()!,
///   ),
///   capabilities: McpPlatformCapabilities.desktop,
///   probeTransports: transports,
///   hostChanges: mcpHostManager,
///   unavailableReasons: () => bridge.source.unavailableTools,
/// );
/// await mcp.initialize();
/// ```
final class McpFeature {
  McpFeature._({
    required this.capabilities,
    required this.connections,
    required this.toolAccess,
  });

  factory McpFeature.build({
    required McpHost host,
    required McpConnectionRepository repository,
    required McpSecretVault secrets,
    required McpToolSelectionStore selections,
    required McpPlatformCapabilities capabilities,
    required McpTransportFactory probeTransports,
    Listenable? hostChanges,
    McpTimeouts timeouts = const McpTimeouts(),
    Set<String> builtInConnectionIds = const <String>{},
    Map<String, String> Function()? unavailableReasons,
  }) {
    return McpFeature._(
      capabilities: capabilities,
      connections: McpConnectionsController(
        host: host,
        repository: repository,
        secrets: secrets,
        capabilities: capabilities,
        probe: McpConnectionProbe(
          transports: probeTransports,
          timeouts: timeouts,
        ),
        hostChanges: hostChanges,
        builtInConnectionIds: builtInConnectionIds,
      ),
      toolAccess: McpToolAccessController(
        host: host,
        store: selections,
        hostChanges: hostChanges,
        unavailableReasons: unavailableReasons,
      ),
    );
  }

  final McpPlatformCapabilities capabilities;
  final McpConnectionsController connections;
  final McpToolAccessController toolAccess;

  Future<void> initialize() async {
    await connections.initialize();
    await toolAccess.initialize();
  }

  Widget buildConnectionsPage({Key? key}) =>
      McpConnectionsPage(controller: connections, key: key);

  void dispose() {
    connections.dispose();
    toolAccess.dispose();
  }
}
