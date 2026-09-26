import 'dart:async';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../support/mcp_fixture_servers.dart';

/// Test factory whose first tool registration fails.
final class _FlakyStreamFactory implements LocalMcpServerFactory {
  _FlakyStreamFactory({required this.serverId});

  final String serverId;
  var registrations = 0;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: serverId,
    displayName: serverId,
    version: '1.0.0',
    registerTools: (server) {
      registrations += 1;
      if (registrations == 1) {
        throw StateError('registration failed');
      }
      server.registerTool(
        'ping',
        description: 'Ping',
        inputSchema: sdk.JsonSchema.object(
          properties: const <String, sdk.JsonSchema>{},
        ),
        callback: (args, extra) async => const sdk.CallToolResult(
          content: <sdk.Content>[sdk.TextContent(text: 'pong')],
        ),
      );
    },
  );
}

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

  test('a closed in-process session is replaced with a fresh one', () async {
    final fixture = FixtureMcpServerFactory(
      serverId: 'stream-fixture',
      tools: fixtureToolsFor('stream-fixture'),
    );
    host.register(fixture);
    await host.start('stream-fixture');
    final config = host.connectionConfig('stream-fixture');

    final first = await factory.create(config, secrets: secrets);
    await first.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    final firstPage = await first.listTools(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(firstPage.tools, isNotEmpty);
    await first.close();
    expect(first.isConnected, isFalse);

    // A single-subscription pair cannot be reused; the host must hand out a
    // fresh server session for the reconnect.
    final second = await factory.create(config, secrets: secrets);
    expect(
      identical(second, first),
      isFalse,
      reason: 'each client session is its own connection object',
    );
    final handshake = await second.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(handshake.serverName, 'stream-fixture');
    final result = await second.callTool(
      originalToolName: 'echo',
      arguments: const <String, Object?>{'value': 'again'},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(result.textContent, 'echo:again');
    await second.close();
  });

  test('a failed local server start can be retried', () async {
    final flaky = _FlakyStreamFactory(serverId: 'flaky');
    host.register(flaky);

    await expectLater(host.start('flaky'), throwsA(isA<StateError>()));
    expect(host.isRunning('flaky'), isFalse);
    expect(host.endpointFor('flaky'), isNull);

    final endpoint = await host.start('flaky');
    expect(endpoint, isA<LocalMcpStreamEndpoint>());
    expect(host.isRunning('flaky'), isTrue);

    final connection = await factory.create(
      host.connectionConfig('flaky'),
      secrets: secrets,
    );
    final handshake = await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(handshake.serverName, 'flaky');
    final page = await connection.listTools(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(page.tools.single.originalName, 'ping');
    final result = await connection.callTool(
      originalToolName: 'ping',
      arguments: const <String, Object?>{},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(result.textContent, 'pong');
    await connection.close();
  });

  test(
    'acquire fails and cleans up when the server is stopped mid-start',
    () async {
      host.register(
        FixtureMcpServerFactory(
          serverId: 'raced',
          tools: fixtureToolsFor('raced'),
        ),
      );
      await host.start('raced');
      // Consume the initial session so the next acquire must create a fresh one.
      final first = await host.acquireStreams('raced');
      host.releaseStreams('raced', first);

      final pending = host.acquireStreams('raced');
      await host.stop('raced');
      await expectLater(
        pending,
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.unavailable,
          ),
        ),
      );
      expect(host.isRunning('raced'), isFalse);
      expect(host.endpointFor('raced'), isNull);
      expect(
        diagnostics.lines.join('\n'),
        contains('discarded a session started after stop'),
      );

      // A fresh start serves a client normally.
      await host.start('raced');
      final connection = await factory.create(
        host.connectionConfig('raced'),
        secrets: secrets,
      );
      final handshake = await connection.connect(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(handshake.serverName, 'raced');
      final page = await connection.listTools(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );
      expect(page.tools, isNotEmpty);
      await connection.close();
    },
  );

  test('a live stream client reserves its session', () async {
    host.register(
      FixtureMcpServerFactory(
        serverId: 'reserved',
        tools: fixtureToolsFor('reserved'),
      ),
    );
    await host.start('reserved');
    final config = host.connectionConfig('reserved');

    final first = await factory.create(config, secrets: secrets);
    await first.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );

    // A second client must not close the session the first one owns.
    await expectLater(
      factory.create(config, secrets: secrets),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.unavailable,
        ),
      ),
    );
    final echo = await first.callTool(
      originalToolName: 'echo',
      arguments: const <String, Object?>{'value': 'live'},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(echo.textContent, 'echo:live');
    await first.close();

    // After release a fresh session is handed out and works.
    final second = await factory.create(config, secrets: secrets);
    final handshake = await second.connect(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(handshake.serverName, 'reserved');
    final again = await second.callTool(
      originalToolName: 'echo',
      arguments: const <String, Object?>{'value': 'again'},
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    expect(again.textContent, 'echo:again');
    await second.close();
  });

  test('concurrent stream acquisitions are rejected', () async {
    host.register(
      FixtureMcpServerFactory(
        serverId: 'concurrent',
        tools: fixtureToolsFor('concurrent'),
      ),
    );
    await host.start('concurrent');
    final first = await host.acquireStreams('concurrent');
    host.releaseStreams('concurrent', first);

    final pending = host.acquireStreams('concurrent');
    await expectLater(
      host.acquireStreams('concurrent'),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.unavailable,
        ),
      ),
    );
    final second = await pending;
    expect(identical(second, first), isFalse);
    host.releaseStreams('concurrent', second);
  });
}
