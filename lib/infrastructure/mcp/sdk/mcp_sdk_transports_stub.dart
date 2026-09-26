import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';
import 'mcp_sdk_transports.dart';

McpStdioLauncher createMcpStdioLauncher() =>
    const UnsupportedMcpStdioLauncher();

/// stdio is unavailable outside Dart IO platforms (web/WASM).
final class UnsupportedMcpStdioLauncher implements McpStdioLauncher {
  const UnsupportedMcpStdioLauncher();

  @override
  bool get isSupported => false;

  @override
  Future<McpTransportConnection> launch({
    required McpConnectionId connectionId,
    required McpStdioTransportConfig config,
    required Map<String, String> secretValues,
    required McpSecretRedactor redactor,
    required McpDiagnosticsSink diagnostics,
  }) {
    throwMcp(
      McpErrorKind.unsupported,
      'stdio MCP servers are not available on this platform.',
    );
  }
}
