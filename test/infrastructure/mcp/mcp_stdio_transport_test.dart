import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_fakes.dart';

/// Real stdio integration: spawns the fixture server with `dart run`,
/// negotiates MCP, lists and calls tools, and checks environment isolation.
///
/// The fixture reports whether `DEEPSEEK_API_KEY` and
/// `DOMOVOY_MCP_TEST_SECRET` leaked into the child. Run this file with those
/// variables set in the parent to make the negative assertion meaningful:
///
/// ```sh
/// DEEPSEEK_API_KEY=sk-parent DOMOVOY_MCP_TEST_SECRET=parent-secret \
///   flutter test test/infrastructure/mcp/mcp_stdio_transport_test.dart
/// ```
void main() {
  test('stdio handshake, catalog, call, isolation and redaction', () async {
    final diagnostics = MemoryMcpDiagnosticsSink();
    final factory = McpSdkTransportFactory(diagnostics: diagnostics);
    final token = CancellationSource().token;
    final secretReference = McpSecretReference.stdioEnvironment(
      McpConnectionId('stdio-fixture'),
      'MCP_FIXTURE_TOKEN',
    );
    final secrets = RuntimeMcpSecretResolver();
    secrets.put(secretReference, 'stdio-secret-token-12345');

    final config = McpConnectionConfig(
      connectionId: McpConnectionId('stdio-fixture'),
      alias: 'stdio-fixture',
      transport: McpStdioTransportConfig(
        command: 'dart',
        args: const <String>[
          'run',
          'test/support/mcp_fixtures/stdio_fixture_server.dart',
        ],
        environment: const <String, String>{
          'MCP_FIXTURE_ID': 'stdio-fixture',
          'MCP_FIXTURE_REPORT_ENV': '1',
        },
        secretEnvironment: <String, McpSecretReference>{
          'MCP_FIXTURE_TOKEN': secretReference,
        },
      ),
    );

    final connection = await factory.create(config, secrets: secrets);
    final handshake = await connection.connect(
      timeout: const Duration(seconds: 60),
      cancellation: token,
    );
    expect(handshake.serverName, 'stdio-fixture');
    expect(handshake.protocolVersion, isNotEmpty);

    final page = await connection.listTools(
      timeout: const Duration(seconds: 30),
      cancellation: token,
    );
    expect(page.tools.map((tool) => tool.originalName).toSet(), <String>{
      'search',
      'fail',
    });

    final result = await connection.callTool(
      originalToolName: 'search',
      arguments: const <String, Object?>{'query': 'stdio'},
      timeout: const Duration(seconds: 30),
      cancellation: token,
    );
    expect(result.isError, isFalse);
    expect(result.textContent, 'stdio-fixture:search:stdio');

    final failure = await connection.callTool(
      originalToolName: 'fail',
      arguments: const <String, Object?>{},
      timeout: const Duration(seconds: 30),
      cancellation: token,
    );
    expect(failure.isError, isTrue);
    expect(failure.textContent, 'stdio domain failure');

    await connection.close();
    expect(connection.isConnected, isFalse);

    await waitFor(
      () => diagnostics.lines.any((line) => line.contains('env-report')),
    );
    final joined = diagnostics.lines.join('\n');
    expect(joined, contains('leak-deepseek=false'));
    expect(joined, contains('leak-app-secret=false'));
    expect(joined, contains('token-present=true'));
    expect(joined, isNot(contains('stdio-secret-token-12345')));
    expect(joined, isNot(contains('token=stdio-secret')));
    expect(joined, contains('[redacted]'));
  });

  test(
    'a noisy startup child is drained and does not block the handshake',
    () async {
      final diagnostics = MemoryMcpDiagnosticsSink();
      final factory = McpSdkTransportFactory(diagnostics: diagnostics);
      final token = CancellationSource().token;
      final secretReference = McpSecretReference.stdioEnvironment(
        McpConnectionId('stdio-noisy'),
        'MCP_FIXTURE_TOKEN',
      );
      final secrets = RuntimeMcpSecretResolver();
      secrets.put(secretReference, 'stdio-secret-token-12345');

      final config = McpConnectionConfig(
        connectionId: McpConnectionId('stdio-noisy'),
        alias: 'stdio-noisy',
        transport: McpStdioTransportConfig(
          command: 'dart',
          args: const <String>[
            'run',
            'test/support/mcp_fixtures/stdio_fixture_server.dart',
          ],
          environment: const <String, String>{
            'MCP_FIXTURE_ID': 'stdio-noisy',
            'MCP_FIXTURE_NOISE_LINES': '2000',
          },
          secretEnvironment: <String, McpSecretReference>{
            'MCP_FIXTURE_TOKEN': secretReference,
          },
        ),
      );

      final connection = await factory.create(config, secrets: secrets);
      final handshake = await connection.connect(
        timeout: const Duration(seconds: 60),
        cancellation: token,
      );
      expect(handshake.serverName, 'stdio-noisy');
      final page = await connection.listTools(
        timeout: const Duration(seconds: 30),
        cancellation: token,
      );
      expect(page.tools.map((tool) => tool.originalName), contains('search'));

      // The earliest noise line proves stderr was drained from process start:
      // a late listener would only retain the last 64 KiB. Every line carries
      // the token, so the whole stream is also a redaction check.
      await waitFor(
        () => diagnostics.lines.any((line) => line.contains('noise-0001 ')),
        timeout: const Duration(seconds: 15),
      );
      final joined = diagnostics.lines.join('\n');
      expect(joined, contains('noise-2000 '));
      expect(joined, isNot(contains('stdio-secret-token-12345')));
      expect(joined, contains('[redacted]'));
      await connection.close();
    },
  );
}
