import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/mcp/application/mcp_connection_probe.dart';
import 'package:domovoy/features/mcp/application/mcp_connections_controller.dart';
import 'package:domovoy/features/mcp/application/mcp_tool_access_controller.dart';
import 'package:domovoy/features/mcp/domain/platform_capabilities.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';

import 'mcp_fakes.dart';

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

  final InMemoryMcpConnectionRepository repository;
  final InMemoryMcpSecretVault vault;
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
    McpTimeouts timeouts = const McpTimeouts(
      connect: Duration(milliseconds: 200),
      catalog: Duration(milliseconds: 200),
    ),
    bool startHost = true,
  }) async {
    final repository = InMemoryMcpConnectionRepository();
    final vault = InMemoryMcpSecretVault();
    final transports = ScriptedMcpTransportFactory(builders);
    final host = McpHostManager(
      transports: transports,
      repository: repository,
      secrets: vault,
      timeouts: timeouts,
      reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
      delay: (duration) async {},
    );
    final resolvedSelections =
        selectionStore ?? InMemoryMcpToolSelectionStore();
    final connections = McpConnectionsController(
      host: host,
      repository: repository,
      secrets: vault,
      capabilities: capabilities,
      probe: McpConnectionProbe(transports: transports, timeouts: timeouts),
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
      repository: repository,
      vault: vault,
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
