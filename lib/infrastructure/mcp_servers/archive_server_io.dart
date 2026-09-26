import 'package:mcp_dart/mcp_dart.dart';

import 'archive_api_io.dart';
import 'archive_task_store_io.dart';

CallToolResult _result(Map<String, Object?> value) =>
    CallToolResult.fromStructuredContent(value);

CallToolResult _error(Object error) =>
    CallToolResult(content: [TextContent(text: '$error')], isError: true);

/// First standalone HTTP MCP server: real Internet Archive search and metadata.
final class ArchiveMcpService {
  ArchiveMcpService({
    required this.api,
    required this.tasks,
    this.host = '127.0.0.1',
    this.port = 8401,
    Set<String>? allowedHosts,
    this.allowedOrigins,
  }) : allowedHosts = allowedHosts ?? {'127.0.0.1', 'localhost'},
       assert(port >= 0);

  final ArchiveApi api;
  final ArchiveTaskStore tasks;
  final String host;
  final int port;
  final Set<String> allowedHosts;
  final Set<String>? allowedOrigins;
  StreamableMcpServer? _http;

  int get boundPort => _http?.boundPort ?? port;

  Future<void> start() async {
    if (_http != null) throw StateError('Archive MCP server already started.');
    await tasks.load();
    final http = StreamableMcpServer(
      serverFactory: (_) => createServer(),
      host: host,
      port: port,
      path: '/mcp',
      enableDnsRebindingProtection: true,
      allowedHosts: allowedHosts,
      allowedOrigins: allowedOrigins,
    );
    await http.start();
    _http = http;
  }

  Future<void> stop() async {
    final http = _http;
    _http = null;
    await http?.stop();
    await tasks.close();
    api.close();
  }

  McpServer createServer() {
    final server = McpServer(
      const Implementation(name: 'domovoy-archive', version: '1.0.0'),
      options: const McpServerOptions(protocol: McpProtocol.stable),
    );
    server.registerTool(
      'archive_search',
      description:
          'Search public Internet Archive items. Returns identifiers, titles, descriptions, and links.',
      inputSchema: JsonSchema.object(
        properties: {
          'query': JsonSchema.string(
            description: 'Internet Archive search query',
          ),
          'limit': JsonSchema.integer(
            description: 'Maximum number of items, 1 to 20',
          ),
        },
        required: ['query'],
      ),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async {
        try {
          return _result(
            await api.search(
              args['query'] as String,
              limit: args['limit'] as int? ?? 5,
            ),
          );
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'archive_item',
      description:
          'Read metadata for one public Internet Archive item by identifier.',
      inputSchema: JsonSchema.object(
        properties: {
          'identifier': JsonSchema.string(
            description: 'Internet Archive item identifier',
          ),
        },
        required: ['identifier'],
      ),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async {
        try {
          return _result(await api.item(args['identifier'] as String));
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'task_create',
      description:
          'Create a persistent implementation or research task, optionally linked to an Internet Archive item.',
      inputSchema: JsonSchema.object(
        properties: {
          'title': JsonSchema.string(),
          'details': JsonSchema.string(),
          'itemIdentifier': JsonSchema.string(),
        },
        required: ['title', 'details'],
      ),
      callback: (args, _) async {
        try {
          return _result(
            await tasks.create(
              title: args['title'] as String,
              details: args['details'] as String,
              itemIdentifier: args['itemIdentifier'] as String?,
            ),
          );
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'task_list',
      description: 'List persistent implementation or research tasks.',
      inputSchema: JsonSchema.object(
        properties: {
          'status': JsonSchema.string(enumValues: ['open', 'done']),
        },
      ),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async =>
          _result({'tasks': tasks.list(status: args['status'] as String?)}),
    );
    server.registerTool(
      'task_complete',
      description: 'Mark an implementation or research task as done.',
      inputSchema: JsonSchema.object(
        properties: {'taskId': JsonSchema.string()},
        required: ['taskId'],
      ),
      callback: (args, _) async {
        try {
          return _result(await tasks.complete(args['taskId'] as String));
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    return server;
  }
}
