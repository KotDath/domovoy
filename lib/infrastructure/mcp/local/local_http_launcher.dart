import 'local_mcp_definition.dart';
import 'local_http_launcher_stub.dart'
    if (dart.library.io) 'local_http_launcher_io.dart'
    as platform;

/// Loopback HTTP endpoint of a running local MCP server.
final class McpHttpServerHandle {
  const McpHttpServerHandle({required this.url, required this.stop});

  final Uri url;

  /// Stops the listener and closes every active MCP session.
  final Future<void> Function() stop;
}

/// Starts a loopback-only Streamable HTTP listener for a local server.
abstract interface class McpHttpServerLauncher {
  /// True when this platform can host a loopback HTTP listener.
  bool get isSupported;

  Future<McpHttpServerHandle> start(
    LocalMcpServerDefinition definition, {
    required String bearerToken,
  });
}

/// Returns the platform launcher: real on IO, unsupported on web.
McpHttpServerLauncher createMcpHttpServerLauncher() =>
    platform.createMcpHttpServerLauncher();
