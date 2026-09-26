import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_fixture_servers.dart';

final class _UnsupportedHttpLauncher implements McpHttpServerLauncher {
  const _UnsupportedHttpLauncher();

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

final class _UnsupportedStdioLauncher implements McpStdioLauncher {
  const _UnsupportedStdioLauncher();

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

void main() {
  test('desktop VM advertises stdio and loopback HTTP capabilities', () {
    expect(createMcpStdioLauncher().isSupported, isTrue);
    final httpLauncher = createMcpHttpServerLauncher();
    expect(httpLauncher.isSupported, isTrue);
    final host = LocalMcpServerHost(httpLauncher: httpLauncher);
    expect(host.supportsLoopbackHttp, isTrue);
  });

  test(
    'platforms without a loopback listener fall back to in-process streams',
    () async {
      final host = LocalMcpServerHost(
        httpLauncher: const _UnsupportedHttpLauncher(),
      );
      expect(host.supportsLoopbackHttp, isFalse);
      host.register(
        FixtureMcpServerFactory(
          serverId: 'fallback',
          tools: fixtureToolsFor('fallback'),
        ),
      );
      final endpoint = await host.start('fallback');
      expect(endpoint, isA<LocalMcpStreamEndpoint>());
      expect(
        host.connectionConfig('fallback').transport,
        isA<McpInProcessStreamTransportConfig>(),
      );
      await host.stopAll();
    },
  );

  test(
    'stdio is refused explicitly when the platform cannot offer it',
    () async {
      final factory = McpSdkTransportFactory(
        stdioLauncher: const _UnsupportedStdioLauncher(),
      );
      expect(factory.supportsStdio, isFalse);
      await expectLater(
        factory.create(
          McpConnectionConfig(
            connectionId: McpConnectionId('external'),
            alias: 'external',
            transport: McpStdioTransportConfig(
              command: 'node',
              args: const <String>['server.js'],
            ),
          ),
          secrets: InMemoryMcpSecretVault(),
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.unsupported,
          ),
        ),
      );
    },
  );
}
