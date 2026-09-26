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
  String? get unsupportedReason =>
      'stdio MCP servers are not available on this platform.';

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

  test('stdio policy covers only confirmed desktop platforms', () {
    bool policy(
      String operatingSystem, {
      bool linux = false,
      bool windows = false,
      bool macOS = false,
      bool disabledByPolicy = false,
    }) {
      return supportsStdioOnPlatform(
        operatingSystem: operatingSystem,
        isLinux: linux,
        isWindows: windows,
        isMacOS: macOS,
        disabledByPolicy: disabledByPolicy,
      );
    }

    expect(policy('linux', linux: true), isTrue);
    expect(policy('windows', windows: true), isTrue);
    expect(policy('macos', macOS: true), isTrue);
    expect(policy('android'), isFalse);
    expect(policy('ios'), isFalse);
    expect(policy('fuchsia'), isFalse);
    // Runtimes exposing a distinct Aurora OS string are excluded directly.
    expect(policy('aurora'), isFalse);
  });

  test('Aurora reporting as Linux requires the composition override', () {
    // Dart defines Platform.isLinux as `operatingSystem == 'linux'`, so a real
    // Aurora runtime cannot be told apart from Linux by platform facts alone.
    expect(
      supportsStdioOnPlatform(
        operatingSystem: 'linux',
        isLinux: true,
        isWindows: false,
        isMacOS: false,
      ),
      isTrue,
    );
    expect(
      supportsStdioOnPlatform(
        operatingSystem: 'linux',
        isLinux: true,
        isWindows: false,
        isMacOS: false,
        disabledByPolicy: true,
      ),
      isFalse,
    );
  });

  test('force-disabled launcher refuses stdio with its reason', () async {
    final launcher = createMcpStdioLauncher(
      forceDisabled: true,
      disabledReason: auroraStdioDisabledReason,
    );
    expect(launcher.isSupported, isFalse);
    expect(launcher.unsupportedReason, auroraStdioDisabledReason);

    final factory = McpSdkTransportFactory(stdioLauncher: launcher);
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
        isA<McpException>()
            .having(
              (error) => error.error.kind,
              'kind',
              McpErrorKind.unsupported,
            )
            .having(
              (error) => error.error.message,
              'message',
              auroraStdioDisabledReason,
            ),
      ),
    );
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
