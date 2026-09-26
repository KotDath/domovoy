import 'dart:async';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_fixture_servers.dart';

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
      preference: McpLocalTransportPreference.stream,
      runtimeSecrets: secrets,
      diagnostics: diagnostics,
    );
    factory = McpSdkTransportFactory(streams: host, diagnostics: diagnostics);
    token = CancellationSource().token;
  });

  tearDown(() async {
    await host.stopAll();
  });

  Future<McpSdkConnection> connectFixture({bool includeSlow = false}) async {
    final fixture = FixtureMcpServerFactory(
      serverId: 'stream-fixture',
      tools: fixtureToolsFor('stream-fixture', includeSlow: includeSlow),
    );
    host.register(fixture);
    await host.start('stream-fixture');
    final config = host.connectionConfig('stream-fixture');
    final connection = await factory.create(config, secrets: secrets);
    return connection as McpSdkConnection;
  }

  test(
    'handshake, tools/list and tools/call work over IOStreamTransport',
    () async {
      final connection = await connectFixture();
      final handshake = await connection.connect(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(handshake.serverName, 'stream-fixture');
      expect(handshake.serverVersion, '1.0.0');
      expect(handshake.protocolVersion, isNotEmpty);
      expect(connection.kind, McpTransportKind.inProcessStream);

      final page = await connection.listTools(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(page.tools.map((tool) => tool.originalName).toSet(), <String>{
        'search',
        'echo',
        'fail',
      });
      final search = page.tools.firstWhere(
        (tool) => tool.originalName == 'search',
      );
      expect(search.description, 'Search on stream-fixture');
      expect(search.inputSchema['required'], <String>['query']);

      final result = await connection.callTool(
        originalToolName: 'search',
        arguments: const <String, Object?>{'query': 'mcp'},
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(result.isError, isFalse);
      expect(result.textContent, 'stream-fixture:search:mcp');
      expect(result.structuredContent, <String, Object?>{
        'server': 'stream-fixture',
        'tool': 'search',
        'query': 'mcp',
      });

      await connection.close();
      expect(connection.isConnected, isFalse);
    },
  );

  test('domain failures arrive as isError results, not exceptions', () async {
    final connection = await connectFixture();
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    final result = await connection.callTool(
      originalToolName: 'fail',
      arguments: const <String, Object?>{},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(result.isError, isTrue);
    expect(result.textContent, 'domain failure');
    await connection.close();
  });

  test('calls after close fail with an explicit unavailable error', () async {
    final connection = await connectFixture();
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    await connection.close();
    expect(
      () => connection.callTool(
        originalToolName: 'echo',
        arguments: const <String, Object?>{'value': 'x'},
        timeout: const Duration(seconds: 10),
        cancellation: token,
      ),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.unavailable,
        ),
      ),
    );
  });

  test('timeout is reported explicitly and the session stays usable', () async {
    final connection = await connectFixture(includeSlow: true);
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    await expectLater(
      connection.callTool(
        originalToolName: 'slow',
        arguments: const <String, Object?>{'milliseconds': 3000},
        timeout: const Duration(milliseconds: 150),
        cancellation: token,
      ),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.timeout,
        ),
      ),
    );

    final healthy = await connection.callTool(
      originalToolName: 'echo',
      arguments: const <String, Object?>{'value': 'after-timeout'},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(healthy.textContent, 'echo:after-timeout');
    await connection.close();
  });

  test('cancellation aborts an in-flight call', () async {
    final connection = await connectFixture(includeSlow: true);
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    final source = CancellationSource();
    Timer(const Duration(milliseconds: 100), source.cancel);
    await expectLater(
      connection.callTool(
        originalToolName: 'slow',
        arguments: const <String, Object?>{'milliseconds': 5000},
        timeout: const Duration(seconds: 30),
        cancellation: source.token,
      ),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.cancelled,
        ),
      ),
    );
    await connection.close();
  });
}
