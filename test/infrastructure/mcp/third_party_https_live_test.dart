import 'dart:io';

import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Supplemental live evidence against a public no-auth HTTPS Streamable HTTP
/// endpoint (`https://mcp.deepwiki.com/mcp`, verified with mcp_dart during B9
/// planning to negotiate 2025-11-25 and list `ask_wiki_question`,
/// `read_wiki_contents`, `read_wiki_structure`).
///
/// This is not the controlled bearer test: the hermetic suite covers bearer
/// acceptance/rejection on the loopback endpoint and the cross-origin
/// redirect rule. Run explicitly:
///
/// ```sh
/// DOMOVOY_MCP_LIVE_HTTPS=1 flutter test \
///   test/infrastructure/mcp/third_party_https_live_test.dart
/// ```
void main() {
  final enabled = Platform.environment['DOMOVOY_MCP_LIVE_HTTPS'] == '1';

  test(
    'the public DeepWiki endpoint negotiates and lists its tools',
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
          connectionId: McpConnectionId('deepwiki'),
          alias: 'DeepWiki',
          transport: McpHttpTransportConfig(
            url: 'https://mcp.deepwiki.com/mcp',
          ),
        ),
      );
      final status = host.snapshot.statusFor(McpConnectionId('deepwiki'));
      expect(
        status?.phase,
        McpConnectionPhase.ready,
        reason: status?.lastError,
      );
      expect(
        status!.handshake?.protocolVersion,
        '2025-11-25',
        reason: 'negotiated protocol of the public endpoint',
      );
      final tools = host.snapshot.catalog.routes
          .where((route) => route.connectionId.value == 'deepwiki')
          .map((route) => route.originalToolName)
          .toSet();
      expect(
        tools,
        containsAll(<String>[
          'ask_wiki_question',
          'read_wiki_contents',
          'read_wiki_structure',
        ]),
      );
      await host.stop();
    },
    skip: enabled
        ? false
        : 'set DOMOVOY_MCP_LIVE_HTTPS=1 to run the live HTTPS smoke',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
