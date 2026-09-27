import '../../../core/mcp/mcp.dart';
import 'local_http_launcher.dart';
import 'local_mcp_definition.dart';

McpHttpServerLauncher createMcpHttpServerLauncher({
  bool useDesktopSidecar = false,
}) => const _UnsupportedMcpHttpServerLauncher();

final class _UnsupportedMcpHttpServerLauncher implements McpHttpServerLauncher {
  const _UnsupportedMcpHttpServerLauncher();

  @override
  bool get isSupported => false;

  @override
  Future<McpHttpServerHandle> start(
    LocalMcpServerDefinition definition, {
    required String bearerToken,
  }) {
    throwMcp(
      McpErrorKind.unsupported,
      'Loopback HTTP MCP servers are not available on this platform.',
    );
  }
}
