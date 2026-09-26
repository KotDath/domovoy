// Standalone stdio MCP server used by `mcp_stdio_transport_test.dart`.
//
// It intentionally writes a token and an environment report to stderr so the
// host test can prove that diagnostics are redacted and that the child does
// not inherit application secrets.
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

Future<void> main() async {
  final serverId = Platform.environment['MCP_FIXTURE_ID'] ?? 'stdio-fixture';
  final reportEnvironment =
      Platform.environment['MCP_FIXTURE_REPORT_ENV'] == '1';
  final token = Platform.environment['MCP_FIXTURE_TOKEN'];

  if (reportEnvironment) {
    stderr.writeln(
      'env-report '
      'leak-deepseek=${Platform.environment.containsKey('DEEPSEEK_API_KEY')} '
      'leak-app-secret='
      '${Platform.environment.containsKey('DOMOVOY_MCP_TEST_SECRET')} '
      'token-present=${token != null && token.isNotEmpty}',
    );
  }
  if (token != null) {
    stderr.writeln('token=$token');
  }
  final noiseLines =
      int.tryParse(Platform.environment['MCP_FIXTURE_NOISE_LINES'] ?? '') ?? 0;
  for (var index = 1; index <= noiseLines; index += 1) {
    stderr.writeln('noise-${index.toString().padLeft(4, '0')} ${token ?? ''}');
  }

  final server = sdk.McpServer(
    sdk.Implementation(name: serverId, version: '1.0.0'),
  );
  server.registerTool(
    'search',
    description: 'Search fixture',
    inputSchema: sdk.JsonSchema.object(
      properties: <String, sdk.JsonSchema>{'query': sdk.JsonSchema.string()},
      required: <String>['query'],
    ),
    callback: (args, extra) async => sdk.CallToolResult(
      content: <sdk.Content>[
        sdk.TextContent(text: '$serverId:search:${args['query']}'),
      ],
      structuredContent: <String, dynamic>{
        'server': serverId,
        'query': args['query'],
      },
    ),
  );
  server.registerTool(
    'fail',
    description: 'Domain failure fixture',
    callback: (args, extra) async => const sdk.CallToolResult(
      isError: true,
      content: <sdk.Content>[sdk.TextContent(text: 'stdio domain failure')],
    ),
  );
  await server.connect(sdk.StdioServerTransport());
}
