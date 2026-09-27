import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression for the one-off stdio handshake failure seen during B6
/// verification: mcp_dart's fixed 5 s `legacyDiscoveryTimeout` raced a cold
/// `dart run` fixture under load, and the SDK then fell back to a legacy
/// `initialize` against a modern stateless peer.
///
/// The production factory now configures a longer, bounded discovery budget;
/// these tests prove both sides of the contract with intentionally delayed
/// and genuinely legacy fixtures instead of relying on nondeterministic load.
void main() {
  McpConnectionConfig stdioConfig({
    required String id,
    required List<String> args,
    Map<String, String> environment = const <String, String>{},
  }) {
    return McpConnectionConfig(
      connectionId: McpConnectionId(id),
      alias: id,
      transport: McpStdioTransportConfig(
        command: 'dart',
        args: args,
        environment: environment,
      ),
    );
  }

  test(
    'a delayed modern child still negotiates stateless discovery',
    () async {
      const delayedStartupMs = 6000;
      final diagnostics = MemoryMcpDiagnosticsSink();
      final factory = McpSdkTransportFactory(
        diagnostics: diagnostics,
        legacyDiscoveryTimeout: const Duration(seconds: 25),
      );
      final secrets = RuntimeMcpSecretResolver();
      final config = stdioConfig(
        id: 'stdio-delayed',
        args: const <String>[
          'run',
          'test/support/mcp_fixtures/stdio_fixture_server.dart',
        ],
        environment: const <String, String>{
          'MCP_FIXTURE_ID': 'stdio-delayed',
          'MCP_FIXTURE_STARTUP_DELAY_MS': '$delayedStartupMs',
        },
      );
      final connection = await factory.create(config, secrets: secrets);
      addTearDown(connection.close);

      final handshake = await connection.connect(
        timeout: const Duration(seconds: 60),
        cancellation: CancellationSource().token,
      );
      expect(handshake.serverName, 'stdio-delayed');
      expect(
        handshake.protocolVersion,
        '2026-07-28',
        reason: 'the delayed modern peer must not be mistaken for legacy',
      );
      final page = await connection.listTools(
        timeout: const Duration(seconds: 30),
        cancellation: CancellationSource().token,
      );
      expect(page.tools.map((tool) => tool.originalName), contains('search'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a genuinely legacy peer still falls back to initialize',
    () async {
      final diagnostics = MemoryMcpDiagnosticsSink();
      final factory = McpSdkTransportFactory(
        diagnostics: diagnostics,
        legacyDiscoveryTimeout: const Duration(seconds: 25),
      );
      final secrets = RuntimeMcpSecretResolver();
      final config = stdioConfig(
        id: 'stdio-legacy',
        args: const <String>[
          'run',
          'test/support/mcp_fixtures/legacy_stdio_fixture_server.dart',
        ],
      );
      final connection = await factory.create(config, secrets: secrets);
      addTearDown(connection.close);

      final handshake = await connection.connect(
        timeout: const Duration(seconds: 60),
        cancellation: CancellationSource().token,
      );
      expect(handshake.serverName, 'legacy-stdio-fixture');
      expect(handshake.protocolVersion, '2025-11-25');
      final page = await connection.listTools(
        timeout: const Duration(seconds: 30),
        cancellation: CancellationSource().token,
      );
      expect(page.tools.map((tool) => tool.originalName), <String>[
        'legacy_search',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
