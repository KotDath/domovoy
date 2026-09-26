import 'package:mcp_dart/mcp_dart.dart';

import 'briefing_service_io.dart';

CallToolResult _result(Map<String, Object?> value) =>
    CallToolResult.fromStructuredContent(value);

CallToolResult _error(Object error) =>
    CallToolResult(content: [TextContent(text: '$error')], isError: true);

/// Second standalone HTTP MCP server, with persistent background scheduling.
final class BriefingMcpServer {
  BriefingMcpServer({
    required this.service,
    this.host = '127.0.0.1',
    this.port = 8402,
    Set<String>? allowedHosts,
    this.allowedOrigins,
  }) : allowedHosts = allowedHosts ?? {'127.0.0.1', 'localhost'},
       assert(port >= 0);

  final BriefingService service;
  final String host;
  final int port;
  final Set<String> allowedHosts;
  final Set<String>? allowedOrigins;
  StreamableMcpServer? _http;

  int get boundPort => _http?.boundPort ?? port;

  Future<void> start() async {
    if (_http != null) throw StateError('Briefing MCP server already started.');
    await service.start();
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
    await service.stop();
  }

  McpServer createServer() {
    final server = McpServer(
      const Implementation(name: 'domovoy-briefing', version: '1.0.0'),
      options: const McpServerOptions(protocol: McpProtocol.stable),
    );
    server.registerTool(
      'summarize_items',
      description:
          'Make a concise, source-linked digest from archive_search output.',
      inputSchema: JsonSchema.object(
        properties: {'searchResult': JsonSchema.object()},
        required: ['searchResult'],
      ),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async {
        try {
          return _result(
            service.summarize(
              Map<String, Object?>.from(args['searchResult'] as Map),
            ),
          );
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'save_digest',
      description:
          'Persist a digest in the server JSONL store and return its report ID.',
      inputSchema: JsonSchema.object(
        properties: {'digest': JsonSchema.object()},
        required: ['digest'],
      ),
      callback: (args, _) async {
        try {
          return _result(
            await service.save(
              Map<String, Object?>.from(args['digest'] as Map),
            ),
          );
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'schedule_digest',
      description:
          'Schedule an Internet Archive search and digest every intervalSeconds. The server runs it in the background, even when the app is closed.',
      inputSchema: JsonSchema.object(
        properties: {
          'query': JsonSchema.string(),
          'intervalSeconds': JsonSchema.integer(),
          'limit': JsonSchema.integer(),
        },
        required: ['query', 'intervalSeconds'],
      ),
      callback: (args, _) async {
        try {
          return _result(
            await service.schedule(
              args['query'] as String,
              args['intervalSeconds'] as int,
              limit: args['limit'] as int? ?? 5,
            ),
          );
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'run_due_digests',
      description:
          'Run any due scheduled jobs now and return aggregate execution counts.',
      inputSchema: JsonSchema.object(),
      callback: (args, _) async {
        try {
          return _result(await service.runDue());
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'cancel_schedule',
      description: 'Stop a periodic digest and persist the cancellation.',
      inputSchema: JsonSchema.object(
        properties: {'scheduleId': JsonSchema.string()},
        required: ['scheduleId'],
      ),
      callback: (args, _) async {
        try {
          return _result(await service.cancel(args['scheduleId'] as String));
        } on Object catch (error) {
          return _error(error);
        }
      },
    );
    server.registerTool(
      'list_digests',
      description:
          'Return saved digests, latest first, optionally filtered by schedule ID.',
      inputSchema: JsonSchema.object(
        properties: {'scheduleId': JsonSchema.string()},
      ),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async => _result({
        'reports': service.reports(scheduleId: args['scheduleId'] as String?),
      }),
    );
    server.registerTool(
      'list_schedules',
      description: 'Return active background schedules and their run counts.',
      inputSchema: JsonSchema.object(),
      annotations: const ToolAnnotations(readOnlyHint: true),
      callback: (args, _) async => _result({'schedules': service.schedules()}),
    );
    return server;
  }
}
