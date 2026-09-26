import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/mcp/mcp.dart';
import '../local/local_mcp_server_host.dart';
import '../mcp_diagnostics.dart';
import 'mcp_sdk_connection.dart';
import 'mcp_sdk_transports_stub.dart'
    if (dart.library.io) 'mcp_sdk_transports_io.dart'
    as platform;

/// Client identity advertised to MCP servers.
const domovoyMcpClientName = 'domovoy';
const domovoyMcpClientVersion = '1.0.0';

/// Creates stdio client sessions on platforms that can spawn processes.
abstract interface class McpStdioLauncher {
  /// True when this platform can offer third-party stdio servers.
  ///
  /// Mobile platforms cannot guarantee launching arbitrary external
  /// executables; Domovoy only offers built-in servers and HTTPS there.
  bool get isSupported;

  Future<McpTransportConnection> launch({
    required McpConnectionId connectionId,
    required McpStdioTransportConfig config,
    required Map<String, String> secretValues,
    required McpSecretRedactor redactor,
    required McpDiagnosticsSink diagnostics,
  });
}

/// Returns the platform stdio launcher; the stub throws `unsupported`.
McpStdioLauncher createMcpStdioLauncher() => platform.createMcpStdioLauncher();

/// Builds SDK transports for every `McpTransportConfig` variant.
final class McpSdkTransportFactory implements McpTransportFactory {
  McpSdkTransportFactory({
    this.streams,
    this.diagnostics = const NoopMcpDiagnosticsSink(),
    McpStdioLauncher? stdioLauncher,
  }) : _stdioLauncher = stdioLauncher ?? createMcpStdioLauncher();

  /// Registry of running built-in servers for `inProcessStream` connections.
  final LocalMcpStreamRegistry? streams;
  final McpDiagnosticsSink diagnostics;
  final McpStdioLauncher _stdioLauncher;

  /// True when third-party stdio servers can be offered on this platform.
  bool get supportsStdio => _stdioLauncher.isSupported;

  @override
  Future<McpTransportConnection> create(
    McpConnectionConfig config, {
    required McpSecretResolver secrets,
  }) async {
    final resolved = await _resolveSecrets(config, secrets);
    switch (config.transport) {
      case final McpStdioTransportConfig stdio:
        if (!supportsStdio) {
          throwMcp(
            McpErrorKind.unsupported,
            'stdio MCP servers are not offered on this platform.',
          );
        }
        return _stdioLauncher.launch(
          connectionId: config.connectionId,
          config: stdio,
          secretValues: resolved.stdioEnvironment,
          redactor: resolved.redactor,
          diagnostics: diagnostics,
        );
      case final McpHttpTransportConfig http:
        final headers = <String, String>{
          if (resolved.bearer != null)
            'Authorization': 'Bearer ${resolved.bearer}',
        };
        final transport = sdk.StreamableHttpClientTransport(
          http.uri,
          opts: sdk.StreamableHttpClientTransportOptions(
            requestInit: <String, dynamic>{'headers': headers},
            // SSE reconnection is disabled; the host owns reconnect policy.
            reconnectionOptions: const sdk.StreamableHttpReconnectionOptions(
              initialReconnectionDelay: 0,
              maxReconnectionDelay: 0,
              reconnectionDelayGrowFactor: 1,
              maxRetries: 0,
            ),
          ),
        );
        return McpSdkConnection(
          connectionId: config.connectionId,
          kind: McpTransportKind.streamableHttp,
          client: _newClient(),
          transport: transport,
          diagnostics: diagnostics,
          redactor: resolved.redactor,
        );
      case final McpInProcessStreamTransportConfig streamConfig:
        final registry = streams;
        if (registry == null) {
          throwMcp(
            McpErrorKind.unavailable,
            'Local MCP server "${streamConfig.serverId}" is not running.',
          );
        }
        final pair = await registry.acquireStreams(streamConfig.serverId);
        final transport = sdk.IOStreamTransport(
          stream: pair.clientInbound,
          sink: pair.clientOutbound,
        );
        return McpSdkConnection(
          connectionId: config.connectionId,
          kind: McpTransportKind.inProcessStream,
          client: _newClient(),
          transport: transport,
          diagnostics: diagnostics,
          redactor: resolved.redactor,
        );
    }
  }

  sdk.McpClient _newClient() => sdk.McpClient(
    const sdk.Implementation(
      name: domovoyMcpClientName,
      version: domovoyMcpClientVersion,
    ),
  );

  Future<_ResolvedSecrets> _resolveSecrets(
    McpConnectionConfig config,
    McpSecretResolver secrets,
  ) async {
    final stdioEnvironment = <String, String>{};
    String? bearer;
    final redactionValues = <String>[];
    switch (config.transport) {
      case McpStdioTransportConfig(:final secretEnvironment):
        for (final entry in secretEnvironment.entries) {
          final value = await secrets.read(entry.value);
          if (value == null || value.isEmpty) {
            throwMcp(
              McpErrorKind.configuration,
              'Missing secret for environment variable "${entry.key}".',
            );
          }
          stdioEnvironment[entry.key] = value;
          redactionValues.add(value);
        }
      case McpHttpTransportConfig(:final bearerSecret):
        if (bearerSecret != null) {
          final value = await secrets.read(bearerSecret);
          if (value == null || value.isEmpty) {
            throwMcp(
              McpErrorKind.configuration,
              'Missing bearer token for MCP connection "${config.connectionId}".',
            );
          }
          bearer = value;
          redactionValues.add(value);
        }
      case McpInProcessStreamTransportConfig():
        break;
    }
    return _ResolvedSecrets(
      stdioEnvironment: stdioEnvironment,
      bearer: bearer,
      redactor: McpSecretRedactor(redactionValues),
    );
  }
}

final class _ResolvedSecrets {
  const _ResolvedSecrets({
    required this.stdioEnvironment,
    required this.bearer,
    required this.redactor,
  });

  final Map<String, String> stdioEnvironment;
  final String? bearer;
  final McpSecretRedactor redactor;
}
