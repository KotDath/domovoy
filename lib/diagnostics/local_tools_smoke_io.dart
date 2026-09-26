import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../app.dart';
import '../core/llm/credentials.dart';
import '../core/llm/identifiers.dart';

/// Run with `flutter run -d linux -t lib/diagnostics/local_tools_smoke_io.dart`.
/// Uses a scripted LLM response while exercising the real project, runtime,
/// local tools, and chat interface. No network request is sent to an LLM.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    DomovoyApp(
      dependencies: DomovoyDependencies.production(
        httpClient: _SmokeClient(),
        credentialStore: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('deepseek'):
              Platform.environment['DEEPSEEK_API_KEY'] ?? '',
        }),
      ),
    ),
  );
}

final class _SmokeClient extends http.BaseClient {
  var _turn = 0;

  static const _scenario = <(String, Map<String, Object?>)>[
    (
      'write',
      <String, Object?>{'path': 'live-smoke.txt', 'content': 'before edit'},
    ),
    ('read', <String, Object?>{'path': 'live-smoke.txt'}),
    (
      'edit',
      <String, Object?>{
        'path': 'live-smoke.txt',
        'edits': <Map<String, Object?>>[
          <String, Object?>{'oldText': 'before', 'newText': 'after'},
        ],
      },
    ),
    ('bash', <String, Object?>{'command': "printf 'shell-ok'"}),
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'api.deepseek.com' &&
        request.method == 'GET' &&
        request.url.path == '/models') {
      return _response(
        jsonEncode(<String, Object?>{
          'object': 'list',
          'data': <Map<String, Object?>>[
            <String, Object?>{'id': 'deepseek-flash', 'object': 'model'},
          ],
        }),
        contentType: 'application/json',
      );
    }
    if (request.url.host != 'api.deepseek.com' ||
        request.method != 'POST' ||
        request.url.path != '/chat/completions') {
      return _response('{}', statusCode: 503);
    }
    final body = jsonDecode(utf8.decode(await request.finalize().toBytes()));
    if (body is! Map<String, dynamic>) {
      return _response('{}', statusCode: 400);
    }
    final tools = body['tools'];
    if (tools is! List || tools.isEmpty) {
      return _textTurn('{}');
    }
    final messages = body['messages'];
    final toolMessages = messages is List
        ? messages.whereType<Map<String, dynamic>>().where(
            (message) => message['role'] == 'tool',
          )
        : <Map<String, dynamic>>[];
    await File('/tmp/domovoy-local-tools-smoke.jsonl').writeAsString(
      '${jsonEncode(<String, Object?>{'turn': _turn, 'availableTools': tools.whereType<Map<String, dynamic>>().map((tool) => (tool['function'] as Map?)?['name']).toList(), 'lastToolResult': toolMessages.isEmpty ? null : toolMessages.last['content']})}\n',
      mode: FileMode.append,
    );
    if (_turn >= _scenario.length) {
      return _textTurn('Все четыре локальных инструмента вызваны.');
    }
    final (name, arguments) = _scenario[_turn];
    final callId = 'local-smoke-${_turn + 1}';
    _turn += 1;
    return _response(
      'data: ${jsonEncode(<String, Object?>{
        'choices': <Map<String, Object?>>[
          <String, Object?>{
            'delta': <String, Object?>{
              'tool_calls': <Map<String, Object?>>[
                <String, Object?>{
                  'index': 0,
                  'id': callId,
                  'type': 'function',
                  'function': <String, Object?>{'name': name, 'arguments': jsonEncode(arguments)},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      })}\n\ndata: [DONE]\n\n',
      contentType: 'text/event-stream',
    );
  }

  http.StreamedResponse _textTurn(String text) => _response(
    'data: ${jsonEncode(<String, Object?>{
      'choices': <Map<String, Object?>>[
        <String, Object?>{
          'delta': <String, Object?>{'content': text},
          'finish_reason': 'stop',
        },
      ],
    })}\n\ndata: [DONE]\n\n',
    contentType: 'text/event-stream',
  );

  http.StreamedResponse _response(
    String body, {
    int statusCode = 200,
    String contentType = 'text/event-stream',
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: <String, String>{'content-type': contentType},
  );
}
