import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../settings/domain/api_key_credentials.dart';
import '../domain/agent.dart';
import 'chat_completions_provider_profile.dart';
import 'sse_decoder.dart';

final class OpenAiCompatibleChatAgent implements Agent {
  OpenAiCompatibleChatAgent({
    required http.Client client,
    required ApiKeyResolver apiKeyResolver,
    required ChatCompletionsProviderProfile profile,
    SseDecoder decoder = const SseDecoder(),
  }) : _client = client,
       _apiKeyResolver = apiKeyResolver,
       _profile = profile,
       _decoder = decoder;

  final http.Client _client;
  final ApiKeyResolver _apiKeyResolver;
  final ChatCompletionsProviderProfile _profile;
  final SseDecoder _decoder;

  @override
  Stream<AgentEvent> prompt(AgentInput input) async* {
    try {
      final credential = await _apiKeyResolver.resolve();
      final request = http.Request('POST', _profile.endpoint)
        ..headers.addAll(<String, String>{
          'Authorization': 'Bearer ${credential.value}',
          'Accept': 'text/event-stream',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(_profile.requestBody(input));

      final response = await _client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        yield AgentFailed(_failureForHttpStatus(response.statusCode));
        return;
      }

      await for (final data in _decoder.decode(response.stream)) {
        if (data == '[DONE]') {
          yield const AgentCompleted();
          return;
        }

        final payload = jsonDecode(data);
        if (payload is! Map<String, dynamic>) {
          throw const FormatException('Expected an SSE JSON object.');
        }

        if (payload['error'] != null) {
          yield const AgentFailed(
            AgentFailure(
              kind: AgentFailureKind.provider,
              message: 'DeepSeek сообщил об ошибке во время генерации.',
            ),
          );
          return;
        }

        final choices = payload['choices'];
        if (choices == null) {
          continue;
        }
        if (choices is! List) {
          throw const FormatException('Expected choices to be a list.');
        }
        if (choices.isEmpty) {
          continue;
        }

        final choice = choices.first;
        if (choice is! Map<String, dynamic>) {
          throw const FormatException('Expected a choice object.');
        }
        final delta = choice['delta'];
        if (delta == null) {
          continue;
        }
        if (delta is! Map<String, dynamic>) {
          throw const FormatException('Expected a delta object.');
        }

        final reasoning = _textField(delta, _profile.reasoningDeltaField);
        if (reasoning != null && reasoning.isNotEmpty) {
          yield AgentReasoningDelta(reasoning);
        }

        final answer = _textField(delta, _profile.answerDeltaField);
        if (answer != null && answer.isNotEmpty) {
          yield AgentAnswerDelta(answer);
        }
      }

      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.interrupted,
          message: 'Соединение прервалось до завершения ответа.',
        ),
      );
    } on MissingApiKeyException {
      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.configuration,
          message:
              'Добавьте API-ключ DeepSeek в настройках или задайте '
              'DEEPSEEK_API_KEY в окружении.',
        ),
      );
    } on http.ClientException {
      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.network,
          message: 'Не удалось подключиться к DeepSeek. Проверьте сеть.',
        ),
      );
    } on TimeoutException {
      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.network,
          message: 'DeepSeek не ответил вовремя. Попробуйте ещё раз.',
        ),
      );
    } on FormatException {
      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.protocol,
          message: 'DeepSeek вернул поток в неожиданном формате.',
        ),
      );
    } on Object {
      yield const AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.unknown,
          message: 'Не удалось получить ответ. Попробуйте ещё раз.',
        ),
      );
    }
  }

  static String? _textField(Map<String, dynamic> delta, String field) {
    final value = delta[field];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('Expected $field to be text.');
    }
    return value;
  }

  static AgentFailure _failureForHttpStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return const AgentFailure(
        kind: AgentFailureKind.authentication,
        message: 'DeepSeek отклонил API-ключ. Проверьте его в настройках.',
      );
    }
    if (statusCode == 429) {
      return const AgentFailure(
        kind: AgentFailureKind.rateLimit,
        message: 'Лимит запросов DeepSeek исчерпан. Попробуйте позже.',
      );
    }
    return AgentFailure(
      kind: AgentFailureKind.provider,
      message: 'DeepSeek вернул ошибку HTTP $statusCode.',
    );
  }
}
