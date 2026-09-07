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
  group('OpenAiCompatibleChatAgent baseline', () {
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
        expect(body['model'], 'deepseek-v4-flash');
        expect((body['messages'] as List).single['content'], 'hello');
        expect(body['stream'], isTrue);
        expect(body['stream_options'], {'include_usage': true});
        expect(body['thinking'], {'type': 'enabled'});
        expect(body['reasoning_effort'], 'high');
        expect(events, hasLength(3));
        expect((events[0] as AgentReasoningDelta).text, 'think ');
        expect((events[1] as AgentAnswerDelta).text, 'answer');
        final completed = events[2] as AgentCompleted;
        expect(completed.finishReason, AgentFinishReason.stop);
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

  group('request construction', () {
    test('disabled thinking omits reasoning effort', () async {
      final client = RecordingClient((_) => _response('data: [DONE]\n\n'));
      final agent = _agent(client);

      await agent
          .prompt(AgentInput('hi', thinking: ThinkingMode.disabled))
          .drain<void>();

      final body =
          jsonDecode(client.requests.single.body) as Map<String, dynamic>;
      expect(body['thinking'], {'type': 'disabled'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('prompt requests omit unused sampling fields', () async {
      final client = RecordingClient((_) => _response('data: [DONE]\n\n'));
      final agent = _agent(client);

      await agent.prompt(AgentInput('plain')).drain<void>();

      final body =
          jsonDecode(client.requests.single.body) as Map<String, dynamic>;
      expect(body.containsKey('response_format'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('stop'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('serializes supplied temperatures and never adds top_p', () async {
      final client = RecordingClient((_) => _response('data: [DONE]\n\n'));
      final agent = _agent(client);

      for (final value in const <double>[0.0, 0.7, 1.2, 2.0]) {
        await agent
            .prompt(
              AgentInput(
                'hi',
                thinking: ThinkingMode.disabled,
                temperature: value,
              ),
            )
            .drain<void>();
      }

      expect(client.requests, hasLength(4));
      for (var i = 0; i < 4; i++) {
        final body =
            jsonDecode(client.requests[i].body) as Map<String, dynamic>;
        expect(body['temperature'], <double>[0.0, 0.7, 1.2, 2.0][i]);
        expect(body['thinking'], {'type': 'disabled'});
        expect(body.containsKey('top_p'), isFalse);
        expect(body.containsKey('reasoning_effort'), isFalse);
      }
    });

    test('existing callers omit temperature from the request body', () async {
      final profile = ChatCompletionsProviderProfile.deepSeekV4Flash();
      final omitted = profile.requestBody(AgentInput('hello'));
      expect(omitted.containsKey('temperature'), isFalse);
      expect(omitted.containsKey('top_p'), isFalse);

      final supplied = profile.requestBody(
        AgentInput('hello', thinking: ThinkingMode.disabled, temperature: 0.7),
      );
      expect(supplied['temperature'], 0.7);
      expect(supplied['thinking'], {'type': 'disabled'});
      expect(supplied.containsKey('top_p'), isFalse);
      expect(supplied.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('stream metadata', () {
    test('tolerates usage-only chunks and emits usage on DONE', () async {
      final client = RecordingClient(
        (_) => _response(
          'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}\n\n'
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final events = await _agent(client).prompt(AgentInput('hi')).toList();

      expect(events.whereType<AgentAnswerDelta>(), hasLength(1));
      final completed = events.last as AgentCompleted;
      expect(completed.usage?.promptTokens, 5);
      expect(completed.usage?.completionTokens, 7);
      expect(completed.usage?.totalTokens, 12);
    });

    test('normalizes stop, length, and unknown finish reasons', () async {
      for (final entry in {
        'stop': AgentFinishReason.stop,
        'length': AgentFinishReason.length,
        'content_filter': AgentFinishReason.contentFilter,
        'tool_calls': AgentFinishReason.toolCalls,
        'insufficient_system_resource':
            AgentFinishReason.insufficientSystemResource,
        'server_busy': AgentFinishReason.unknown,
      }.entries) {
        final client = RecordingClient(
          (_) => _response(
            'data: {"choices":[{"delta":{},"finish_reason":"${entry.key}"}]}\n\n'
            'data: [DONE]\n\n',
          ),
        );
        final events = await _agent(client).prompt(AgentInput('hi')).toList();
        expect(
          (events.single as AgentCompleted).finishReason,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('keeps the last finish reason and tolerates malformed metadata', () async {
      final client = RecordingClient(
        (_) => _response(
          'data: {"choices":[{"delta":{"content":"a"},"finish_reason":"stop"}]}\n\n'
          'data: {"choices":[{"delta":{},"finish_reason":42}],"usage":"oops"}\n\n'
          'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final events = await _agent(client).prompt(AgentInput('hi')).toList();

      expect((events.first as AgentAnswerDelta).text, 'a');
      expect(
        (events.last as AgentCompleted).finishReason,
        AgentFinishReason.length,
      );
    });

    test('provider error after partial output stays sanitized', () async {
      const secret = 'top-secret-key';
      final client = RecordingClient(
        (_) => _response(
          'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'
          'data: {"error":{"message":"$secret exploded"}}\n\n',
        ),
      );
      final events = await _agent(
        client,
        key: secret,
      ).prompt(AgentInput('hi')).toList();

      expect((events.first as AgentAnswerDelta).text, 'partial');
      final failure = (events.last as AgentFailed).failure;
      expect(failure.kind, AgentFailureKind.provider);
      expect(failure.message, isNot(contains(secret)));
    });

    test('parses cache-hit and cache-miss prompt counters', () async {
      final client = RecordingClient(
        (_) => _response(
          'data: {"choices":[{"delta":{"content":"hi"}}],'
          '"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,'
          '"prompt_cache_hit_tokens":3,"prompt_cache_miss_tokens":7}}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final completed =
          (await _agent(client).prompt(AgentInput('hi')).toList()).last
              as AgentCompleted;
      expect(completed.usage?.cacheHitPromptTokens, 3);
      expect(completed.usage?.cacheMissPromptTokens, 7);
      expect(completed.usage?.promptTokens, 10);
    });

    test('keeps usage unavailable when the provider omits it', () async {
      final client = RecordingClient(
        (_) => _response(
          'data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final completed =
          (await _agent(client).prompt(AgentInput('hi')).toList()).last
              as AgentCompleted;
      expect(completed.usage, isNull);
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
