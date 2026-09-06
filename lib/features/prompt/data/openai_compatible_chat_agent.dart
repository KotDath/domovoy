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
    CredentialResolver? apiKeyResolver,
    required ChatCompletionsProviderProfile profile,
    SseDecoder decoder = const SseDecoder(),
    this.providerLabel = 'DeepSeek',
  }) : _client = client,
       _apiKeyResolver = apiKeyResolver,
       _profile = profile,
       _decoder = decoder;

  final http.Client _client;
  final CredentialResolver? _apiKeyResolver;
  final ChatCompletionsProviderProfile _profile;
  final SseDecoder _decoder;
  final String providerLabel;

  bool get _isDeepSeek => providerLabel == 'DeepSeek';

  @override
  Stream<AgentEvent> prompt(AgentInput input) async* {
    try {
      final headers = <String, String>{
        'Accept': 'text/event-stream',
        'Content-Type': 'application/json',
      };
      final resolver = _apiKeyResolver;
      if (resolver != null) {
        final credential = await resolver.resolve();
        headers['Authorization'] = 'Bearer ${credential.value}';
      }
      final request = http.Request('POST', _profile.endpoint)
        ..headers.addAll(headers)
        ..body = jsonEncode(_profile.requestBody(input));

      final response = await _client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        yield AgentFailed(_failureForHttpStatus(response.statusCode));
        return;
      }

      AgentFinishReason? finishReason;
      AgentTokenUsage? usage;

      await for (final data in _decoder.decode(response.stream)) {
        if (data == '[DONE]') {
          yield AgentCompleted(finishReason: finishReason, usage: usage);
          return;
        }

        final payload = jsonDecode(data);
        if (payload is! Map<String, dynamic>) {
          throw const FormatException('Expected an SSE JSON object.');
        }

        if (payload['error'] != null) {
          yield AgentFailed(
            AgentFailure(
              kind: AgentFailureKind.provider,
              message: _isDeepSeek
                  ? 'DeepSeek сообщил об ошибке во время генерации.'
                  : 'Провайдер сообщил об ошибке во время генерации.',
            ),
          );
          return;
        }

        final parsedUsage = _usageFrom(payload['usage']);
        if (parsedUsage != null) {
          usage = parsedUsage;
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
        final parsedReason = _finishReasonFrom(choice['finish_reason']);
        if (parsedReason != null) {
          finishReason = parsedReason;
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
    } on MissingApiKeyException catch (error) {
      yield AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.configuration,
          message: _missingKeyMessage(error.environmentVariable),
        ),
      );
    } on http.ClientException {
      yield AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.network,
          message: _isDeepSeek
              ? 'Не удалось подключиться к DeepSeek. Проверьте сеть.'
              : 'Не удалось подключиться к провайдеру. Проверьте сеть.',
        ),
      );
    } on TimeoutException {
      yield AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.network,
          message: _isDeepSeek
              ? 'DeepSeek не ответил вовремя. Попробуйте ещё раз.'
              : 'Провайдер не ответил вовремя. Попробуйте ещё раз.',
        ),
      );
    } on FormatException {
      yield AgentFailed(
        AgentFailure(
          kind: AgentFailureKind.protocol,
          message: _isDeepSeek
              ? 'DeepSeek вернул поток в неожиданном формате.'
              : 'Провайдер вернул поток в неожиданном формате.',
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

  static AgentFinishReason? _finishReasonFrom(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      return null;
    }
    return switch (value) {
      'stop' => AgentFinishReason.stop,
      'length' => AgentFinishReason.length,
      'content_filter' => AgentFinishReason.contentFilter,
      'tool_calls' => AgentFinishReason.toolCalls,
      'insufficient_system_resource' =>
        AgentFinishReason.insufficientSystemResource,
      _ => AgentFinishReason.unknown,
    };
  }

  static AgentTokenUsage? _usageFrom(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final prompt = _intField(value, 'prompt_tokens');
    final completion = _intField(value, 'completion_tokens');
    final total = _intField(value, 'total_tokens');
    final cacheHit =
        _intField(value, 'prompt_cache_hit_tokens') ??
        _cachedTokensFromDetails(value);
    final cacheMiss = _intField(value, 'prompt_cache_miss_tokens');
    if (prompt == null &&
        completion == null &&
        total == null &&
        cacheHit == null &&
        cacheMiss == null) {
      return null;
    }
    return AgentTokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      cacheHitPromptTokens: cacheHit,
      cacheMissPromptTokens: cacheMiss,
    );
  }

  static int? _cachedTokensFromDetails(Map<String, dynamic> usage) {
    final details = usage['prompt_tokens_details'];
    if (details is! Map<String, dynamic>) {
      return null;
    }
    return _intField(details, 'cached_tokens');
  }

  static int? _intField(Map<String, dynamic> map, String field) {
    final value = map[field];
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  AgentFailure _failureForHttpStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return AgentFailure(
        kind: AgentFailureKind.authentication,
        message: _isDeepSeek
            ? 'DeepSeek отклонил API-ключ. Проверьте его в настройках.'
            : 'Провайдер отклонил API-ключ. Проверьте его в настройках.',
      );
    }
    if (statusCode == 429) {
      return AgentFailure(
        kind: AgentFailureKind.rateLimit,
        message: _isDeepSeek
            ? 'Лимит запросов DeepSeek исчерпан. Попробуйте позже.'
            : 'Лимит запросов провайдера исчерпан. Попробуйте позже.',
      );
    }
    return AgentFailure(
      kind: AgentFailureKind.provider,
      message: _isDeepSeek
          ? 'DeepSeek вернул ошибку HTTP $statusCode.'
          : 'Провайдер вернул ошибку HTTP $statusCode.',
    );
  }

  String _missingKeyMessage(String? environmentVariable) {
    if (_isDeepSeek) {
      return 'Добавьте API-ключ DeepSeek в настройках или задайте '
          'DEEPSEEK_API_KEY в окружении.';
    }
    final variable = environmentVariable?.trim();
    if (variable == null || variable.isEmpty) {
      return 'Добавьте API-ключ в настройках профиля.';
    }
    return 'Добавьте API-ключ в настройках или задайте $variable в окружении.';
  }
}
