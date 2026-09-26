// The low-level `Server` is the only SDK entry point that lets a fixture emit
// a multi-page `tools/list`; production code uses `McpServer` instead.
// ignore_for_file: deprecated_member_use

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

void main() {
  test(
    'adapter passes real tools/list cursors through to the server',
    () async {
      final pair = McpStreamPair.create();
      final token = CancellationSource().token;

      final server = sdk.Server(
        const sdk.Implementation(name: 'paged-server', version: '1.0.0'),
        options: const sdk.McpServerOptions(
          capabilities: sdk.ServerCapabilities(
            tools: sdk.ServerCapabilitiesTools(),
          ),
        ),
      );
      final requestedCursors = <String?>[];
      server.setRequestHandler<sdk.JsonRpcListToolsRequest>(
        sdk.Method.toolsList,
        (request, extra) async {
          final cursor = request.params?['cursor'] as String?;
          requestedCursors.add(cursor);
          return switch (cursor) {
            null => sdk.ListToolsResult(
              tools: <sdk.Tool>[_tool('alpha')],
              nextCursor: 'page-2',
            ),
            'page-2' => sdk.ListToolsResult(
              tools: <sdk.Tool>[_tool('beta')],
              nextCursor: 'page-3',
            ),
            'page-3' => sdk.ListToolsResult(tools: <sdk.Tool>[_tool('gamma')]),
            _ => throw sdk.McpError(
              sdk.ErrorCode.invalidParams.value,
              'unknown cursor',
            ),
          };
        },
        (id, params, meta) =>
            sdk.JsonRpcListToolsRequest(id: id, params: params, meta: meta),
      );
      await server.connect(
        sdk.IOStreamTransport(
          stream: pair.serverInbound,
          sink: pair.serverOutbound,
        ),
      );

      final connection = McpSdkConnection(
        connectionId: McpConnectionId('paged'),
        kind: McpTransportKind.inProcessStream,
        client: sdk.McpClient(
          const sdk.Implementation(name: 'paged-client', version: '1.0.0'),
        ),
        transport: sdk.IOStreamTransport(
          stream: pair.clientInbound,
          sink: pair.clientOutbound,
        ),
      );
      await connection.connect(
        timeout: const Duration(seconds: 10),
        cancellation: token,
      );

      final names = <String>[];
      String? cursor;
      for (var page = 0; page < 5; page += 1) {
        final result = await connection.listTools(
          cursor: cursor,
          timeout: const Duration(seconds: 10),
          cancellation: token,
        );
        names.addAll(result.tools.map((tool) => tool.originalName));
        cursor = result.nextCursor;
        if (cursor == null) {
          break;
        }
      }
      expect(names, <String>['alpha', 'beta', 'gamma']);
      expect(requestedCursors, <String?>[null, 'page-2', 'page-3']);

      await connection.close();
      await server.close();
      await pair.close();
    },
  );
}

sdk.Tool _tool(String name) => sdk.Tool(
  name: name,
  description: 'Tool $name',
  inputSchema: sdk.JsonSchema.object(
    properties: const <String, sdk.JsonSchema>{},
  ),
);
