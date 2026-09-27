import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';
import 'mcp_sdk_transports.dart';

McpStdioLauncher createMcpStdioLauncher({
  bool forceDisabled = false,
  String? disabledReason,
  Duration legacyDiscoveryTimeout = defaultMcpLegacyDiscoveryTimeout,
}) => UnsupportedMcpStdioLauncher(disabledReason: disabledReason);

/// stdio is unavailable outside Dart IO platforms (web/WASM).
final class UnsupportedMcpStdioLauncher implements McpStdioLauncher {
  const UnsupportedMcpStdioLauncher({this.disabledReason});

  final String? disabledReason;

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason =>
      disabledReason ?? 'stdio MCP servers are not available on this platform.';

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
