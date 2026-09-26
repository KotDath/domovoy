import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transport configuration', () {
    test('stdio round-trips and keeps secret references only', () {
      final config = McpStdioTransportConfig(
        command: 'dart',
        args: const <String>['run', 'server.dart'],
        workingDirectory: '/tmp/servers',
        environment: const <String, String>{'NODE_ENV': 'production'},
        secretEnvironment: <String, McpSecretReference>{
          'API_TOKEN': McpSecretReference.stdioEnvironment(
            McpConnectionId('remote'),
            'API_TOKEN',
          ),
        },
      );
      final decoded = McpTransportConfig.fromJson(config.toJson());
      expect(decoded, isA<McpStdioTransportConfig>());
      final stdio = decoded as McpStdioTransportConfig;
      expect(stdio.command, 'dart');
      expect(stdio.args, <String>['run', 'server.dart']);
      expect(stdio.workingDirectory, '/tmp/servers');
      expect(stdio.environment, <String, String>{'NODE_ENV': 'production'});
      expect(
        stdio.secretEnvironment['API_TOKEN']!.storeKey,
        'mcp.remote.env.API_TOKEN',
      );
      final encoded = jsonEncode(config.toJson());
      expect(encoded, contains('secure_storage'));
      expect(encoded, isNot(contains('token-value')));
    });

    test('rejects a variable configured both explicitly and as a secret', () {
      expect(
        () => McpStdioTransportConfig(
          command: 'dart',
          environment: const <String, String>{'API_TOKEN': 'cleartext'},
          secretEnvironment: const <String, McpSecretReference>{
            'API_TOKEN': McpSecretReference('mcp.remote.env.API_TOKEN'),
          },
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.configuration,
          ),
        ),
      );
    });

    test('rejects control characters in commands and arguments', () {
      expect(
        () => McpStdioTransportConfig(command: 'dart\nrm -rf /'),
        throwsA(isA<McpException>()),
      );
      expect(
        () => McpStdioTransportConfig(
          command: 'dart',
          args: const <String>['bad\narg'],
        ),
        throwsA(isA<McpException>()),
      );
    });

    test('plain http is allowed only for loopback endpoints', () {
      final loopback = McpHttpTransportConfig(url: 'http://127.0.0.1:4711/mcp');
      expect(loopback.isLoopback, isTrue);
      expect(
        McpHttpTransportConfig(url: 'http://localhost:3000/mcp').isLoopback,
        isTrue,
      );
      expect(
        McpHttpTransportConfig(url: 'https://mcp.example.com/mcp').isLoopback,
        isFalse,
      );
      expect(
        () => McpHttpTransportConfig(url: 'http://mcp.example.com/mcp'),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.configuration,
          ),
        ),
      );
      expect(
        () => McpHttpTransportConfig(
          url: 'https://user:secret@mcp.example.com/mcp',
        ),
        throwsA(isA<McpException>()),
      );
      expect(
        () => McpHttpTransportConfig(url: 'https://mcp.example.com/mcp#frag'),
        throwsA(isA<McpException>()),
      );
    });

    test('unknown transport kinds fail with an explicit unsupported error', () {
      expect(
        () => McpTransportConfig.fromJson(<String, Object?>{'kind': 'carrier'}),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.unsupported,
          ),
        ),
      );
    });
  });

  group('connection configuration', () {
    test('encodes schemaVersion, transport and revision without secrets', () {
      final config = McpConnectionConfig(
        connectionId: McpConnectionId('remote'),
        alias: 'Remote',
        transport: McpHttpTransportConfig(
          url: 'https://mcp.example.com/mcp',
          bearerSecret: McpSecretReference.bearer(McpConnectionId('remote')),
        ),
      );
      final json = config.toJson();
      expect(json, <String, Object?>{
        'schemaVersion': 1,
        'connectionId': 'remote',
        'alias': 'Remote',
        'transport': <String, Object?>{
          'kind': 'streamable_http',
          'url': 'https://mcp.example.com/mcp',
          'bearerSecret': <String, Object?>{
            'kind': 'secure_storage',
            'key': 'mcp.remote.bearer',
          },
        },
        'enabled': true,
        'revision': 0,
      });
      expect(jsonEncode(json), isNot(contains('super-secret-token')));
      expect(McpConnectionConfig.fromJson(json), config);
    });

    test('rejects unknown schema versions', () {
      final json = Map<String, Object?>.from(
        McpConnectionConfig(
          connectionId: McpConnectionId('remote'),
          alias: 'Remote',
          transport: McpHttpTransportConfig(url: 'https://mcp.example.com/mcp'),
        ).toJson(),
      );
      json['schemaVersion'] = 2;
      expect(
        () => McpConnectionConfig.fromJson(json),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.unsupported,
          ),
        ),
      );
    });

    test('in-memory repository enforces revisions', () async {
      final repository = InMemoryMcpConnectionRepository();
      final token = CancellationSource().token;
      final config = McpConnectionConfig(
        connectionId: McpConnectionId('arxiv'),
        alias: 'arXiv',
        transport: McpInProcessStreamTransportConfig(serverId: 'arxiv'),
      );
      await repository.save(config, expectedRevision: 0, cancellation: token);
      expect((await repository.load(McpConnectionId('arxiv')))!, config);

      final updated = config.copyWith(alias: 'arXiv 2', revision: 1);
      await repository.save(updated, expectedRevision: 0, cancellation: token);
      expect(
        (await repository.load(McpConnectionId('arxiv')))!.alias,
        'arXiv 2',
      );

      await expectLater(
        repository.save(
          config.copyWith(alias: 'stale', revision: 1),
          expectedRevision: 0,
          cancellation: token,
        ),
        throwsA(isA<McpException>()),
      );

      await repository.delete(
        McpConnectionId('arxiv'),
        expectedRevision: 1,
        cancellation: token,
      );
      expect(await repository.load(McpConnectionId('arxiv')), isNull);
    });
  });

  group('errors', () {
    test('round-trips through JSON', () {
      final error = McpError(
        kind: McpErrorKind.toolNotFound,
        message: 'missing',
      );
      expect(McpError.fromJson(error.toJson()), error);
    });

    test('sanitizes secrets, stack traces and multiline text', () {
      expect(
        sanitizeMcpText('Bearer abc123', fallback: 'fallback'),
        'fallback',
      );
      expect(sanitizeMcpText('sk-secret', fallback: 'fallback'), 'fallback');
      expect(sanitizeMcpText('line1\nline2', fallback: 'fallback'), 'fallback');
      expect(
        sanitizeMcpText('trace\n#0 foo.dart', fallback: 'fallback'),
        'fallback',
      );
      expect(
        sanitizeMcpText('plain message', fallback: 'fallback'),
        'plain message',
      );
      expect(sanitizeMcpText('   ', fallback: 'fallback'), 'fallback');
      expect(sanitizeMcpText(null, fallback: 'fallback'), 'fallback');
    });
  });
}
