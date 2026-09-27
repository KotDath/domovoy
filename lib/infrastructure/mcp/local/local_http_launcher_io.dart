import 'package:mcp_dart/mcp_dart.dart' as sdk;

import 'local_http_launcher.dart';
import 'local_http_sidecar_io.dart';
import 'local_mcp_definition.dart';

McpHttpServerLauncher createMcpHttpServerLauncher({
  bool useDesktopSidecar = false,
}) => _IoMcpHttpServerLauncher(useDesktopSidecar: useDesktopSidecar);

final class _IoMcpHttpServerLauncher implements McpHttpServerLauncher {
  const _IoMcpHttpServerLauncher({required this.useDesktopSidecar});

  final bool useDesktopSidecar;

  @override
  bool get isSupported => true;

  @override
  Future<McpHttpServerHandle> start(
    LocalMcpServerDefinition definition, {
    required String bearerToken,
  }) async {
    final expected = 'Bearer $bearerToken';
    final server = sdk.StreamableMcpServer(
      serverFactory: (_) => createLocalMcpServer(definition),
      host: '127.0.0.1',
      port: 0,
      path: '/mcp',
      enableDnsRebindingProtection: true,
      allowedHosts: const <String>{'127.0.0.1', 'localhost'},
      authenticationHandler: (request) {
        final header = request.headers.value('authorization');
        if (header != null && _constantTimeEquals(header, expected)) {
          return const sdk.StreamableMcpAuthenticationResult.allow();
        }
        return const sdk.StreamableMcpAuthenticationResult.unauthorized();
      },
    );
    await server.start();
    final backend = McpHttpServerHandle(
      url: Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.boundPort,
        path: '/mcp',
      ),
      stop: server.stop,
    );
    if (!useDesktopSidecar) {
      return backend;
    }
    try {
      final sidecar = await launchMcpHttpSidecar(
        serverId: definition.id,
        backendUrl: backend.url,
        bearerToken: bearerToken,
      );
      return McpHttpServerHandle(
        url: sidecar.url,
        processId: sidecar.processId,
        stop: () async {
          try {
            await sidecar.stop();
          } finally {
            await backend.stop();
          }
        },
      );
    } on Object {
      await backend.stop();
      rethrow;
    }
  }
}

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}
