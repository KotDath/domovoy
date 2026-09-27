// Minimal legacy MCP peer used by `mcp_stdio_discovery_test.dart`.
//
// It intentionally has no `server/discover` support: the request is answered
// with a JSON-RPC "method not found" error, so a correct client must fall back
// to the legacy `initialize` handshake and still be able to list tools. This
// proves the longer bounded discovery timeout does not weaken the fallback for
// genuinely old peers.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final lines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .asyncMap((line) async => line);
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) {
      continue;
    }
    final id = decoded['id'];
    final method = decoded['method'];
    if (id == null) {
      // Notification (for example notifications/initialized).
      continue;
    }
    final Map<String, Object?> response;
    switch (method) {
      case 'server/discover':
        response = <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found',
          },
        };
      case 'initialize':
        response = <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{'tools': <String, Object?>{}},
            'serverInfo': <String, Object?>{
              'name': 'legacy-stdio-fixture',
              'version': '1.0.0',
            },
          },
        };
      case 'tools/list':
        response = <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'tools': <Object?>[
              <String, Object?>{
                'name': 'legacy_search',
                'description': 'Legacy search tool',
                'inputSchema': <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{
                    'query': <String, Object?>{'type': 'string'},
                  },
                  'required': <String>['query'],
                  'additionalProperties': false,
                },
              },
            ],
          },
        };
      default:
        response = <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found',
          },
        };
    }
    stdout.writeln(jsonEncode(response));
  }
}
