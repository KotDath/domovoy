import 'package:mcp_dart/mcp_dart.dart';

/// Reproducible Day 16/19/20 flow through two independent HTTP MCP servers.
Future<Map<String, Object?>> runMcpDemoFlow({
  required Uri archiveEndpoint,
  required Uri briefingEndpoint,
  required String query,
}) async {
  Future<McpClient> connect(Uri endpoint) async {
    final client = McpClient(
      const Implementation(name: 'domovoy-demo', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    await client.connect(StreamableHttpClientTransport(endpoint));
    return client;
  }

  Map<String, Object?> value(CallToolResult result) {
    if (result.isError || result.structuredContent == null) {
      throw StateError('MCP tool call failed.');
    }
    return Map<String, Object?>.from(result.structuredContent!);
  }

  final archive = await connect(archiveEndpoint);
  McpClient? briefing;
  try {
    briefing = await connect(briefingEndpoint);
    final archiveTools = (await archive.listTools()).tools
        .map((tool) => tool.name)
        .toList();
    final briefingTools = (await briefing.listTools()).tools
        .map((tool) => tool.name)
        .toList();
    final search = value(
      await archive.callTool(
        CallToolRequest(
          name: 'archive_search',
          arguments: {'query': query, 'limit': 3},
        ),
      ),
    );
    final items = search['items'] as List;
    final first = items.isEmpty
        ? null
        : Map<String, Object?>.from(items.first as Map);
    final detail = first == null
        ? null
        : value(
            await archive.callTool(
              CallToolRequest(
                name: 'archive_item',
                arguments: {'identifier': first['identifier']},
              ),
            ),
          );
    final task = first == null
        ? null
        : value(
            await archive.callTool(
              CallToolRequest(
                name: 'task_create',
                arguments: {
                  'title': 'Review ${first['title']}',
                  'details':
                      'Use the item metadata in an implementation brief.',
                  'itemIdentifier': first['identifier'],
                },
              ),
            ),
          );
    final digest = value(
      await briefing.callTool(
        CallToolRequest(
          name: 'summarize_items',
          arguments: {'searchResult': search},
        ),
      ),
    );
    final saved = value(
      await briefing.callTool(
        CallToolRequest(name: 'save_digest', arguments: {'digest': digest}),
      ),
    );
    final completedTask = task == null
        ? null
        : value(
            await archive.callTool(
              CallToolRequest(
                name: 'task_complete',
                arguments: {'taskId': task['id']},
              ),
            ),
          );
    final listed = value(
      await briefing.callTool(
        const CallToolRequest(name: 'list_digests', arguments: {}),
      ),
    );
    return {
      'archiveTools': archiveTools,
      'briefingTools': briefingTools,
      'search': search,
      'detail': detail,
      'task': task,
      'digest': digest,
      'saved': saved,
      'completedTask': completedTask,
      'listed': listed,
      'order': [
        'archive_search',
        if (detail != null) 'archive_item',
        if (task != null) 'task_create',
        'summarize_items',
        'save_digest',
        if (completedTask != null) 'task_complete',
        'list_digests',
      ],
    };
  } finally {
    await briefing?.close();
    await archive.close();
  }
}
