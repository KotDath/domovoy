import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

/// Declarative tool used by the fake MCP servers in tests.
final class FixtureTool {
  const FixtureTool({
    required this.name,
    this.title,
    this.description = '',
    this.inputSchema = const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{},
    },
    this.outputSchema,
    this.handler,
  });

  final String name;
  final String? title;
  final String description;
  final Map<String, Object?> inputSchema;
  final Map<String, Object?>? outputSchema;
  final Future<sdk.CallToolResult> Function(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  )?
  handler;
}

/// High-level MCP server fixture usable with [LocalMcpServerHost].
final class FixtureMcpServerFactory implements LocalMcpServerFactory {
  FixtureMcpServerFactory({
    required String serverId,
    required this.tools,
    String? displayName,
    this.version = '1.0.0',
  }) : serverId = serverId.trim(),
       displayName = (displayName ?? serverId).trim();

  final String serverId;
  final String displayName;
  final String version;
  final List<FixtureTool> tools;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: serverId,
    displayName: displayName,
    version: version,
    registerTools: (server) {
      for (final tool in tools) {
        server.registerTool(
          tool.name,
          title: tool.title,
          description: tool.description,
          inputSchema: sdk.JsonSchema.object(
            properties: _properties(tool.inputSchema),
            required: _required(tool.inputSchema),
          ),
          outputSchema: tool.outputSchema == null
              ? null
              : sdk.JsonSchema.object(
                  properties: _properties(tool.outputSchema!),
                ),
          callback: (args, extra) =>
              tool.handler?.call(args, extra) ??
              sdk.CallToolResult(
                content: <sdk.Content>[
                  sdk.TextContent(text: '${tool.name}:ok'),
                ],
              ),
        );
      }
    },
  );
}

Map<String, sdk.JsonSchema> _properties(Map<String, Object?> schema) {
  final properties = schema['properties'];
  if (properties is! Map) {
    return const <String, sdk.JsonSchema>{};
  }
  return <String, sdk.JsonSchema>{
    for (final entry in properties.entries)
      if (entry.key is String)
        entry.key as String: sdk.JsonSchema.fromJson(entry.value),
  };
}

List<String>? _required(Map<String, Object?> schema) {
  final required = schema['required'];
  if (required is! List) {
    return null;
  }
  return <String>[
    for (final item in required)
      if (item is String) item,
  ];
}

/// Standard tool set used by the four-server isolation tests.
///
/// Tool names deliberately overlap between servers so the test can prove that
/// model-facing names stay unique and routing is per connection.
List<FixtureTool> fixtureToolsFor(String serverId, {bool includeSlow = false}) {
  return <FixtureTool>[
    FixtureTool(
      name: 'search',
      description: 'Search on $serverId',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{'type': 'string'},
        },
        'required': <String>['query'],
      },
      handler: (args, extra) async => sdk.CallToolResult(
        content: <sdk.Content>[
          sdk.TextContent(text: '$serverId:search:${args['query']}'),
        ],
        structuredContent: <String, dynamic>{
          'server': serverId,
          'tool': 'search',
          'query': args['query'],
        },
      ),
    ),
    FixtureTool(
      name: 'echo',
      description: 'Echo on $serverId',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'value': <String, Object?>{'type': 'string'},
        },
      },
      handler: (args, extra) async => sdk.CallToolResult(
        content: <sdk.Content>[sdk.TextContent(text: 'echo:${args['value']}')],
        structuredContent: <String, dynamic>{
          'server': serverId,
          'value': args['value'],
        },
      ),
    ),
    FixtureTool(
      name: 'fail',
      description: 'Domain failure on $serverId',
      handler: (args, extra) async => const sdk.CallToolResult(
        isError: true,
        content: <sdk.Content>[sdk.TextContent(text: 'domain failure')],
      ),
    ),
    if (includeSlow)
      FixtureTool(
        name: 'slow',
        description: 'Slow tool on $serverId',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'milliseconds': <String, Object?>{'type': 'integer'},
          },
        },
        handler: (args, extra) async {
          final milliseconds = (args['milliseconds'] as num?)?.toInt() ?? 100;
          final deadline = DateTime.now().add(
            Duration(milliseconds: milliseconds),
          );
          while (DateTime.now().isBefore(deadline)) {
            if (extra.signal.aborted) {
              return const sdk.CallToolResult(
                isError: true,
                content: <sdk.Content>[sdk.TextContent(text: 'cancelled')],
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return const sdk.CallToolResult(
            content: <sdk.Content>[sdk.TextContent(text: 'done')],
          );
        },
      ),
  ];
}

/// Long tool name used by the collision fixtures: [run] x's plus [suffix].
String mcpLongTool(String suffix, {int run = 74}) => '${'x' * run}$suffix';

String mcpCollisionModelName(String hash) => 'mcp_collision__${'x' * 40}_$hash';

/// Model name shared by the verified colliding fixtures.
final mcpCollidingModelName = mcpCollisionModelName('3bf4e9a2');

/// Real hash-collision pair for connection id `collision`.
///
/// Found by birthday search under the shipped hash: both names truncate to
/// the same readable prefix and hash to `3bf4e9a2`, so `McpCatalogBuilder`
/// must reject the result instead of silently dropping one of them.
final mcpCollidingToolNames = <String>[
  mcpLongTool('1p0n'),
  mcpLongTool('30p0'),
];

/// Reviewer-supplied example. Under the shipped hash only the first name
/// reaches the expected `2eea3eb6` suffix; the second hashes to `37788220`,
/// which is why the regression fixtures use the verified pair above.
final mcpReviewerFirstToolName = mcpLongTool('Qh3zIElgBqy7uT', run: 80);
final mcpReviewerSecondToolName = mcpLongTool('YKcjwv63sdDNOs', run: 80);

/// Minimal `Paper` fixture shared by B3-B5 contract tests.
Paper samplePaper({
  String arxivId = '2501.01234',
  String? version = 'v2',
  String title = 'Example title',
}) {
  return Paper(
    arxivId: arxivId,
    version: version,
    title: title,
    authors: const <String>['A. Researcher'],
    abstractText: 'Original arXiv abstract',
    categories: const <String>['cs.AI'],
    publishedAt: DateTime.utc(2025, 1, 3, 12),
    updatedAt: DateTime.utc(2025, 1, 6, 12),
  );
}

/// Minimal `Digest` fixture whose items reference [papers].
Digest sampleDigest({List<Paper>? papers}) {
  final sources = papers ?? <Paper>[samplePaper()];
  return Digest(
    topic: 'Research topic',
    overview: 'Short synthesis',
    items: <DigestItem>[
      for (final paper in sources)
        DigestItem(
          arxivId: paper.arxivId.value,
          finding: 'Claim grounded in the supplied abstract',
          limitation: 'Only the abstract was reviewed',
        ),
    ],
    generatedAt: DateTime.utc(2025, 1, 6, 12, 5),
  );
}
