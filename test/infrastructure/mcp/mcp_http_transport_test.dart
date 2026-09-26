import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_fixture_servers.dart';

/// Loopback Streamable HTTP smoke test.
///
/// Runs on the Dart VM (Linux desktop CI): the loopback listener on 127.0.0.1
/// with a dynamic port is exercised end to end. Android/Aurora results are
/// recorded separately in the B1 report because no device is attached here.
void main() {
  late LocalMcpServerHost host;
  late RuntimeMcpSecretResolver secrets;
  late McpSdkTransportFactory factory;
  late MemoryMcpDiagnosticsSink diagnostics;
  late CancellationToken token;

  setUp(() {
    secrets = RuntimeMcpSecretResolver();
    diagnostics = MemoryMcpDiagnosticsSink();
    host = LocalMcpServerHost(
      preference: McpLocalTransportPreference.http,
      runtimeSecrets: secrets,
      diagnostics: diagnostics,
    );
    factory = McpSdkTransportFactory(streams: host, diagnostics: diagnostics);
    token = CancellationSource().token;
  });

  tearDown(() async {
    await host.stopAll();
  });

  Future<LocalMcpHttpEndpoint> startFixture({
    String id = 'http-fixture',
  }) async {
    host.register(
      FixtureMcpServerFactory(serverId: id, tools: fixtureToolsFor(id)),
    );
    final endpoint = await host.start(id);
    expect(endpoint, isA<LocalMcpHttpEndpoint>());
    return endpoint as LocalMcpHttpEndpoint;
  }

  test(
    'loopback endpoint binds 127.0.0.1 and serves the full MCP cycle',
    () async {
      final endpoint = await startFixture();
      expect(endpoint.url.scheme, 'http');
      expect(endpoint.url.host, '127.0.0.1');
      expect(endpoint.url.port, greaterThan(0));
      expect(endpoint.bearerToken.length, 64);

      final config = host.connectionConfig('http-fixture');
      final connection = await factory.create(config, secrets: secrets);
      final handshake = await connection.connect(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(handshake.serverName, 'http-fixture');

      final page = await connection.listTools(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(page.tools.length, 3);

      final result = await connection.callTool(
        originalToolName: 'echo',
        arguments: const <String, Object?>{'value': 'http'},
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(result.structuredContent, <String, Object?>{
        'server': 'http-fixture',
        'value': 'http',
      });
      await connection.close();
    },
  );

  test('a wrong bearer token is rejected before any catalog access', () async {
    final endpoint = await startFixture();
    final wrongSecrets = RuntimeMcpSecretResolver(
      fallback: InMemoryMcpSecretVault(<String, String>{
        'mcp.http-fixture.bearer': 'wrong-token',
      }),
    );
    final config = McpConnectionConfig(
      connectionId: McpConnectionId('http-fixture'),
      alias: 'http-fixture',
      transport: McpHttpTransportConfig(
        url: endpoint.url.toString(),
        bearerSecret: McpSecretReference.bearer(
          McpConnectionId('http-fixture'),
        ),
      ),
    );
    final connection = await factory.create(config, secrets: wrongSecrets);
    await expectLater(
      connection.connect(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );
  });

  test('stopping a local server invalidates its endpoint and calls', () async {
    await startFixture();
    final config = host.connectionConfig('http-fixture');
    final connection = await factory.create(config, secrets: secrets);
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    await host.stop('http-fixture');
    await expectLater(
      connection.listTools(
        timeout: const Duration(seconds: 5),
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );
    expect(
      () => host.connectionConfig('http-fixture'),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.configuration,
        ),
      ),
    );
    await connection.close();
  });
}
