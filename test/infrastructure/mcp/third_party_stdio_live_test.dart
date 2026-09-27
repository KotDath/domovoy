import 'dart:io';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live desktop smoke of a pinned third-party **stdio** MCP server.
///
/// Not part of the hermetic suite: it downloads and runs the pinned
/// open-source `duckduckgo-mcp-server==0.7.0` through `uvx`, which needs
/// network access. Run it explicitly:
///
/// ```sh
/// DOMOVOY_MCP_LIVE_DDG=1 flutter test \
///   test/infrastructure/mcp/third_party_stdio_live_test.dart
/// ```
void main() {
  final enabled = Platform.environment['DOMOVOY_MCP_LIVE_DDG'] == '1';

  test(
    'the pinned DuckDuckGo stdio server lists and answers tools',
    () async {
      final diagnostics = MemoryMcpDiagnosticsSink();
      final host = McpHostManager(
        transports: McpSdkTransportFactory(diagnostics: diagnostics),
        repository: InMemoryMcpConnectionRepository(),
        secrets: RuntimeMcpSecretResolver(),
        diagnostics: diagnostics,
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
      );
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      await host.upsertConnection(
        McpConnectionConfig(
          connectionId: McpConnectionId('ddg'),
          alias: 'DuckDuckGo',
          transport: McpStdioTransportConfig(
            command: 'uvx',
            args: const <String>[
              '--from',
              'duckduckgo-mcp-server==0.7.0',
              'duckduckgo-mcp-server',
            ],
            environment: const <String, String>{'DDG_SAFE_SEARCH': 'MODERATE'},
          ),
        ),
      );

      final status = host.snapshot.statusFor(McpConnectionId('ddg'));
      expect(status, isNotNull);
      expect(status!.phase, McpConnectionPhase.ready, reason: status.lastError);
      expect(host.snapshot.catalog.lookup('mcp_ddg__search'), isNotNull);

      final result = await host.callTool(
        modelToolName: 'mcp_ddg__search',
        arguments: const <String, Object?>{
          'query': 'model context protocol specification',
          'max_results': 3,
        },
        timeout: const Duration(seconds: 60),
        cancellation: CancellationSource().token,
      );
      expect(result.isError, isFalse, reason: result.textContent);
      expect(result.textContent.trim(), isNotEmpty);
      // The token of the child's stderr diagnostics never contains parent
      // secrets: the fixture app secrets are not in this process, so only the
      // allowlist behavior is exercised here (see mcp_stdio_transport_test).
      await host.stop();
    },
    skip: enabled
        ? false
        : 'set DOMOVOY_MCP_LIVE_DDG=1 to run the live stdio smoke',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
