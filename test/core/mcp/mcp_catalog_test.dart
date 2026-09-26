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

String nameFor(McpConnectionId connectionId, String originalToolName) =>
    McpToolNamePolicy().candidate(
      connectionId: connectionId,
      originalToolName: originalToolName,
    );

/// Deterministic policy double that forces every candidate to one name.
final class FixedNamePolicy extends McpToolNamePolicy {
  FixedNamePolicy();

  @override
  String candidate({
    required McpConnectionId connectionId,
    required String originalToolName,
  }) => 'mcp_fixed__name';
}

void main() {
  group('McpToolNamePolicy', () {
    test('builds a stable readable name from canonical identifiers', () {
      expect(
        nameFor(McpConnectionId('arxiv'), 'search_papers'),
        'mcp_arxiv__search_papers',
      );
    });

    test('does not depend on display aliases or catalog members', () {
      expect(
        nameFor(McpConnectionId('arxiv'), 'search.papers'),
        nameFor(McpConnectionId('arxiv'), 'search.papers'),
      );
    });

    test('hashes names that cannot be encoded canonically', () {
      final name = nameFor(McpConnectionId('remote.git'), 'repo:status');
      expect(name, startsWith('mcp_remote_git__repo_status_'));
      expect(name.length, lessThanOrEqualTo(McpModelToolName.maxLength));
      expect(RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name), isTrue);
      // Separators inside identifiers are excluded from the canonical form.
      final separated = nameFor(McpConnectionId('a__b'), 'c');
      expect(separated, startsWith('mcp_a_b__c_'));
      final trailing = nameFor(McpConnectionId('a_'), 'c');
      expect(trailing, startsWith('mcp_a__c_'));
    });

    test('fits long names into the provider limit with a stable hash', () {
      final connection = McpConnectionId('very-long-connection-id');
      final longTool = 'x' * 120;
      final name = nameFor(connection, longTool);
      expect(name.length, lessThanOrEqualTo(McpModelToolName.maxLength));
      expect(nameFor(connection, longTool), name);
      expect(nameFor(connection, '${longTool}y'), isNot(name));
    });

    test('rejects a too small name budget explicitly', () {
      expect(
        () => McpToolNamePolicy(maxLength: 8),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.configuration,
          ),
        ),
      );
    });
  });

  group('McpCatalogBuilder names', () {
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

    test('colliding sanitized names stay stable when members change', () {
      McpCatalog build(List<String> toolNames) {
        return (McpCatalogBuilder(revision: 1)
              ..addConnection(McpConnectionId('one'), <McpToolDescriptor>[
                for (final name in toolNames) tool('one', name),
              ]))
            .build();
      }

      final both = build(<String>['a.b', 'a:b', 'plain']);
      final namesBoth = <String, String>{
        for (final route in both.routes)
          route.originalToolName: route.modelToolName.value,
      };
      expect(namesBoth.values.toSet().length, 3);
      expect(namesBoth['a.b'], startsWith('mcp_one__a_b_'));
      expect(namesBoth['a:b'], startsWith('mcp_one__a_b_'));
      expect(namesBoth['plain'], 'mcp_one__plain');

      // Removing the other colliding tool must not rename the survivor.
      final single = build(<String>['a.b', 'plain']);
      final namesSingle = <String, String>{
        for (final route in single.routes)
          route.originalToolName: route.modelToolName.value,
      };
      expect(namesSingle['a.b'], namesBoth['a.b']);
      expect(namesSingle['plain'], namesBoth['plain']);

      // Adding a third tool must not rename existing ones either.
      final three = build(<String>['a.b', 'a:b', 'plain', 'a b']);
      final namesThree = <String, String>{
        for (final route in three.routes)
          route.originalToolName: route.modelToolName.value,
      };
      expect(namesThree['a.b'], namesBoth['a.b']);
      expect(namesThree['a:b'], namesBoth['a:b']);
      expect(namesThree['plain'], namesBoth['plain']);
      expect(namesThree['a b'], startsWith('mcp_one__a_b_'));
    });

    test('rejects a final model-name collision explicitly', () {
      final builder = McpCatalogBuilder(policy: FixedNamePolicy(), revision: 1)
        ..addConnection(McpConnectionId('one'), <McpToolDescriptor>[
          tool('one', 'first'),
        ])
        ..addConnection(McpConnectionId('two'), <McpToolDescriptor>[
          tool('two', 'second'),
        ]);
      expect(
        builder.build,
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.configuration,
          ),
        ),
      );
    });
  });

  group('McpCatalog', () {
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

    test('exposes only unmodifiable route lists', () {
      final catalog =
          (McpCatalogBuilder(revision: 1)..addConnection(
                McpConnectionId('arxiv'),
                <McpToolDescriptor>[tool('arxiv', 'search')],
              ))
              .build();
      final routes = catalog.forConnection(McpConnectionId('arxiv'));
      expect(() => routes.add(routes.first), throwsUnsupportedError);
      expect(() => catalog.routes.clear(), throwsUnsupportedError);
    });

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
