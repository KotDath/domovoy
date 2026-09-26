import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

McpToolDescriptor tool(
  String connectionId,
  String name, {
  String? description,
}) {
  return McpToolDescriptor(
    connectionId: McpConnectionId(connectionId),
    originalName: name,
    description: description ?? 'Tool $name',
    inputSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'query': <String, Object?>{'type': 'string', 'minLength': 1},
      },
      'required': <String>['query'],
    },
  );
}

void main() {
  group('McpToolNamePolicy', () {
    const policy = McpToolNamePolicy();

    test('builds a stable readable name from connection and tool', () {
      expect(
        policy.candidate(
          connectionId: McpConnectionId('arxiv'),
          originalToolName: 'search_papers',
        ),
        'mcp_arxiv__search_papers',
      );
    });

    test('does not depend on display aliases', () {
      final first = policy.candidate(
        connectionId: McpConnectionId('arxiv'),
        originalToolName: 'search.papers',
      );
      final second = policy.candidate(
        connectionId: McpConnectionId('arxiv'),
        originalToolName: 'search.papers',
      );
      expect(first, second);
      expect(first, 'mcp_arxiv__search_papers');
    });

    test('sanitizes unsupported characters and keeps provider-safe names', () {
      final name = policy.candidate(
        connectionId: McpConnectionId('remote.git'),
        originalToolName: 'repo:status',
      );
      expect(RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name), isTrue);
      expect(name, 'mcp_remote_git__repo_status');
    });

    test('fits long names into the provider limit with a stable hash', () {
      final connection = McpConnectionId('very-long-connection-id');
      final longTool = 'x' * 120;
      final name = policy.candidate(
        connectionId: connection,
        originalToolName: longTool,
      );
      expect(name.length, lessThanOrEqualTo(McpModelToolName.maxLength));
      expect(
        policy.candidate(connectionId: connection, originalToolName: longTool),
        name,
      );
      expect(
        policy.candidate(
          connectionId: connection,
          originalToolName: '${longTool}y',
        ),
        isNot(name),
      );
    });

    test('ordinal disambiguation stays within the limit', () {
      const policy = McpToolNamePolicy();
      final base = policy.candidate(
        connectionId: McpConnectionId('arxiv'),
        originalToolName: 'search',
      );
      expect(policy.withOrdinal(base, 1), base);
      expect(policy.withOrdinal(base, 2), '${base}_2');
      final long = 'y' * McpModelToolName.maxLength;
      expect(
        policy.withOrdinal(long, 12).length,
        lessThanOrEqualTo(McpModelToolName.maxLength),
      );
      expect(policy.withOrdinal(long, 12), endsWith('_12'));
    });
  });

  group('McpCatalogBuilder', () {
    test('keeps same-named tools from different servers distinct', () {
      final builder = McpCatalogBuilder(revision: 1);
      for (final server in <String>[
        'arxiv',
        'digest',
        'library',
        'automation',
      ]) {
        builder.addConnection(McpConnectionId(server), <McpToolDescriptor>[
          tool(server, 'search'),
        ]);
      }
      final catalog = builder.build();
      expect(catalog.length, 4);
      final names = catalog.routes
          .map((route) => route.modelToolName.value)
          .toList();
      expect(names.toSet().length, 4);
      expect(catalog.lookup('mcp_arxiv__search')!.originalToolName, 'search');
      expect(catalog.lookup('mcp_arxiv__search')!.connectionId.value, 'arxiv');
    });

    test('disambiguates sanitized collisions deterministically', () {
      final catalog =
          (McpCatalogBuilder(revision: 1)..addConnection(
                McpConnectionId('one'),
                <McpToolDescriptor>[tool('one', 'a.b'), tool('one', 'a:b')],
              ))
              .build();
      final names = catalog.routes
          .map((route) => route.modelToolName.value)
          .toList();
      expect(names.toSet().length, 2);
      expect(names, <String>['mcp_one__a_b', 'mcp_one__a_b_2']);
      final rebuilt =
          (McpCatalogBuilder(revision: 1)..addConnection(
                McpConnectionId('one'),
                <McpToolDescriptor>[tool('one', 'a.b'), tool('one', 'a:b')],
              ))
              .build();
      expect(
        rebuilt.routes.map((route) => route.modelToolName.value).toList(),
        names,
      );
    });

    test(
      'replaces a connection catalog atomically and removes stale routes',
      () {
        final builder = McpCatalogBuilder(revision: 1)
          ..addConnection(McpConnectionId('arxiv'), <McpToolDescriptor>[
            tool('arxiv', 'search'),
            tool('arxiv', 'get'),
          ]);
        expect(
          builder.build().forConnection(McpConnectionId('arxiv')).length,
          2,
        );

        builder.addConnection(McpConnectionId('arxiv'), <McpToolDescriptor>[
          tool('arxiv', 'search'),
        ]);
        final refreshed = builder.build();
        expect(refreshed.lookup('mcp_arxiv__get'), isNull);
        expect(refreshed.lookup('mcp_arxiv__search'), isNotNull);

        builder.removeConnection(McpConnectionId('arxiv'));
        expect(builder.build().isEmpty, isTrue);
      },
    );

    test('preserves the full raw input schema', () {
      final descriptor = McpToolDescriptor(
        connectionId: McpConnectionId('arxiv'),
        originalName: 'search',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'limit': <String, Object?>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 30,
            },
          },
          'required': <String>['limit'],
          'additionalProperties': false,
        },
      );
      final catalog = McpCatalogBuilder(revision: 1)
        ..addConnection(McpConnectionId('arxiv'), <McpToolDescriptor>[
          descriptor,
        ]);
      final schema = catalog
          .build()
          .lookup('mcp_arxiv__search')!
          .descriptor
          .inputSchema;
      expect(schema['additionalProperties'], isFalse);
      expect(
        (schema['properties']! as Map<String, Object?>)['limit'],
        isA<Map<String, Object?>>(),
      );
    });
  });
}
