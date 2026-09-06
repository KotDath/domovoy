import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/data/openai_compatible_chat_agent.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fakes.dart';

void main() {
  group('OpenAiCompatibleChatAgent', () {
    test(
      'sends DeepSeek request and normalizes reasoning and answer',
      () async {
        late RecordedRequest recorded;
        final client = RecordingClient((request) {
          recorded = request;
          return _response(
            'data: {"choices":[{"delta":{"reasoning_content":"think "}}]}\n\n'
            'data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
          );
        });
        final agent = _agent(client, key: 'super-secret');

        final events = await agent.prompt(AgentInput('  hello  ')).toList();

        expect(recorded.method, 'POST');
        expect(
          recorded.url,
          Uri.parse('https://api.deepseek.com/chat/completions'),
        );
        expect(recorded.header('authorization'), 'Bearer super-secret');
        expect(recorded.header('accept'), 'text/event-stream');
        expect(recorded.header('content-type'), 'application/json');
        final body = jsonDecode(recorded.body) as Map<String, dynamic>;
        expect(body, <String, Object?>{
          'model': 'deepseek-v4-flash',
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hello'},
          ],
          'stream': true,
          'thinking': <String, Object?>{'type': 'enabled'},
          'reasoning_effort': 'high',
        });
        expect(events, hasLength(3));
        expect((events[0] as AgentReasoningDelta).text, 'think ');
        expect((events[1] as AgentAnswerDelta).text, 'answer');
        expect(events[2], isA<AgentCompleted>());
      },
    );

    test('repeated calls send only their current prompt', () async {
      final client = RecordingClient((_) => _response('data: [DONE]\n\n'));
      final agent = _agent(client);

      await agent.prompt(AgentInput('first')).drain<void>();
      await agent.prompt(AgentInput('second')).drain<void>();

      final first = jsonDecode(client.requests[0].body) as Map<String, dynamic>;
      final second =
          jsonDecode(client.requests[1].body) as Map<String, dynamic>;
      expect((first['messages'] as List).single['content'], 'first');
      expect((second['messages'] as List).single['content'], 'second');
      expect(second['messages'], hasLength(1));
    });

    test('missing key fails before sending a request', () async {
      final client = RecordingClient((_) => _response('data: [DONE]\n\n'));
      final agent = _agent(client, key: null);

      final events = await agent.prompt(AgentInput('hello')).toList();

      expect(client.requests, isEmpty);
      final failure = (events.single as AgentFailed).failure;
      expect(failure.kind, AgentFailureKind.configuration);
      expect(failure.message, contains('DEEPSEEK_API_KEY'));
    });

    test('HTTP errors are typed and do not expose the key', () async {
      final client = RecordingClient(
        (_) => _response('secret echo', status: 401),
      );
      final agent = _agent(client, key: 'secret echo');

      final events = await agent.prompt(AgentInput('hello')).toList();

      final failure = (events.single as AgentFailed).failure;
      expect(failure.kind, AgentFailureKind.authentication);
      expect(failure.message, isNot(contains('secret echo')));
    });

    test(
      'partial output is followed by interrupted failure without DONE',
      () async {
        final client = RecordingClient(
          (_) => _response(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        );
        final agent = _agent(client);

        final events = await agent.prompt(AgentInput('hello')).toList();

        expect((events.first as AgentAnswerDelta).text, 'partial');
        expect(
          (events.last as AgentFailed).failure.kind,
          AgentFailureKind.interrupted,
        );
      },
    );

    test('malformed JSON becomes protocol failure', () async {
      final agent = _agent(
        RecordingClient((_) => _response('data: not-json\n\n')),
      );

      final events = await agent.prompt(AgentInput('hello')).toList();

      expect(
        (events.single as AgentFailed).failure.kind,
        AgentFailureKind.protocol,
      );
    });

    test('network exception becomes sanitized failure', () async {
      final agent = _agent(
        RecordingClient((_) => throw http.ClientException('secret details')),
      );

      final events = await agent.prompt(AgentInput('hello')).toList();

      final failure = (events.single as AgentFailed).failure;
      expect(failure.kind, AgentFailureKind.network);
      expect(failure.message, isNot(contains('secret details')));
    });
  });
}

OpenAiCompatibleChatAgent _agent(
  RecordingClient client, {
  String? key = 'key',
}) {
  return OpenAiCompatibleChatAgent(
    client: client,
    apiKeyResolver: ApiKeyResolver(
      overrideStore: MemoryApiKeyOverrideStore(key),
      environment: const MapEnvironmentReader({}),
    ),
    profile: ChatCompletionsProviderProfile.deepSeekV4Flash(),
  );
}

http.StreamedResponse _response(String body, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
  );
}

final class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  String? header(String name) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalized) {
        return entry.value;
      }
    }
    return null;
  }
}

final class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);

  final FutureOr<http.StreamedResponse> Function(RecordedRequest request)
  handler;
  final List<RecordedRequest> requests = <RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.decode(await request.finalize().toBytes());
    final recorded = RecordedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers),
      body: body,
    );
    requests.add(recorded);
    return handler(recorded);
  }
}
