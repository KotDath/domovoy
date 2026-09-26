import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';
import '../stdio_environment.dart';
import 'mcp_sdk_connection.dart';
import 'mcp_sdk_transports.dart';

McpStdioLauncher createMcpStdioLauncher() => const DartIoMcpStdioLauncher();

/// Spawns a configured command with a minimal environment.
///
/// stdout is reserved for protocol frames; stderr is drained into diagnostics
/// after secret redaction.
final class DartIoMcpStdioLauncher implements McpStdioLauncher {
  const DartIoMcpStdioLauncher();

  @override
  Future<McpTransportConnection> launch({
    required McpConnectionId connectionId,
    required McpStdioTransportConfig config,
    required Map<String, String> secretValues,
    required McpSecretRedactor redactor,
    required McpDiagnosticsSink diagnostics,
  }) async {
    final environment = buildStdioEnvironment(
      parent: Platform.environment,
      explicit: config.environment,
      secretValues: secretValues,
      windows: Platform.isWindows,
    );
    final transport = sdk.StdioClientTransport(
      sdk.StdioServerParameters(
        command: config.command,
        args: config.args,
        environment: environment,
        includeParentEnvironment: false,
        workingDirectory: config.workingDirectory,
        stderrMode: ProcessStartMode.normal,
        restartOnUnexpectedExit: false,
      ),
    );
    return McpSdkConnection(
      connectionId: connectionId,
      kind: McpTransportKind.stdio,
      client: sdk.McpClient(
        const sdk.Implementation(
          name: domovoyMcpClientName,
          version: domovoyMcpClientVersion,
        ),
      ),
      transport: transport,
      diagnostics: diagnostics,
      redactor: redactor,
      stderrSource: () => transport.stderr
          ?.transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
  }
}
