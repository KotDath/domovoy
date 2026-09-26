import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/mcp/mcp.dart';

/// Callback that registers all tools of one local MCP server.
typedef LocalMcpToolRegistrar = void Function(sdk.McpServer server);

/// Declarative description of one built-in local MCP server.
///
/// B3-B6 implement [LocalMcpServerFactory] and return this definition; the
/// host owns process/session lifecycle and never inspects server internals.
final class LocalMcpServerDefinition {
  LocalMcpServerDefinition({
    required String serverId,
    required String displayName,
    required String version,
    this.instructions,
    required this.registerTools,
  }) : serverId = McpConnectionId(serverId),
       displayName = _requireDisplayName(displayName),
       version = _requireVersion(version);

  /// Stable identity, also used as the default connection ID.
  final McpConnectionId serverId;
  final String displayName;
  final String version;
  final String? instructions;
  final LocalMcpToolRegistrar registerTools;

  String get id => serverId.value;
}

/// Factory interface implemented by each built-in server (B3-B6).
abstract interface class LocalMcpServerFactory {
  LocalMcpServerDefinition create();
}

/// Builds a fresh `McpServer` for one definition.
///
/// The Streamable HTTP helper calls this per session; the in-process stream
/// transport uses one instance per endpoint.
sdk.McpServer createLocalMcpServer(LocalMcpServerDefinition definition) {
  final server = sdk.McpServer(
    sdk.Implementation(name: definition.id, version: definition.version),
    options: sdk.McpServerOptions(
      capabilities: const sdk.ServerCapabilities(
        tools: sdk.ServerCapabilitiesTools(),
      ),
      instructions: definition.instructions,
    ),
  );
  definition.registerTools(server);
  return server;
}

String _requireDisplayName(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 64) {
    throwMcp(
      McpErrorKind.configuration,
      'Local MCP server display name must be 1-64 characters.',
    );
  }
  return candidate;
}

String _requireVersion(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 32) {
    throwMcp(
      McpErrorKind.configuration,
      'Local MCP server version must be 1-32 characters.',
    );
  }
  return candidate;
}
