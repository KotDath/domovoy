import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/capabilities.dart';
import '../../../core/llm/credentials.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/events.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/json.dart';
import '../../../core/llm/messages.dart';
import '../../../core/llm/provider.dart';
import '../../../core/llm/request.dart';
import '../../../core/llm/tools.dart';
import '../../../core/llm/usage.dart';
import 'chat_completions_dialect.dart';
import 'openai_compatible_profile.dart';
import 'stream_session.dart';

final class OpenAiChatCompletionsLlmProvider implements LlmProvider {
  OpenAiChatCompletionsLlmProvider({
    required this.profile,
    required http.Client client,
    required ProviderCredentialResolver credentials,
  }) : _client = client,
       _credentials = credentials;

  final OpenAiCompatibleProfile profile;
  final http.Client _client;
  final ProviderCredentialResolver _credentials;

  @override
  ProviderId get id => profile.id;

  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;

  Map<String, Object?> requestBody(LlmRequest request) {
    final model = profile.requireModel(request.model.modelId);
    validateRequestAgainstModel(request, model);
    if (request.model.providerId != id) {
      throwLlm(
        LlmErrorKind.configuration,
        'Request provider ${request.model.providerId.value} does not match ${id.value}.',
      );
    }
    return buildChatCompletionsBody(
      request: request,
      model: model,
      dialect: profile.dialectFor(model.id),
    );
  }

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    final model = profile.requireModel(request.model.modelId);
    validateRequestAgainstModel(request, model);
    if (request.model.providerId != id) {
      throwLlm(
        LlmErrorKind.configuration,
        'Request provider ${request.model.providerId.value} does not match ${id.value}.',
      );
    }
    final dialect = profile.dialectFor(model.id);
    final body = buildChatCompletionsBody(
      request: request,
      model: model,
      dialect: dialect,
    );
    final session = _ChatCompletionsParseState();
    return runLlmHttpStream(
      providerId: id,
      endpoint: profile.snapshot.endpoint,
      body: body,
      client: _client,
      credentials: _credentials,
      environmentVariable: profile.snapshot.environmentVariable,
      cancellation: cancellation,
      consume: (response, sink, token) {
        return consumeSse(
          response: response,
          sink: sink,
          cancellation: token,
          onMessage: (message, eventSink) async {
            session.handle(message.data, dialect, eventSink, id);
          },
        );
      },
    );
  }
}

final class _ChatCompletionsParseState {
  LlmFinishReason? finishReason;
  LlmUsage? usage;
  final Map<int, ToolCallId> callIdsByIndex = <int, ToolCallId>{};

  void handle(
    String data,
    ChatCompletionsDialect dialect,
    LlmStreamSink sink,
    ProviderId providerId,
  ) {
    if (data == '[DONE]') {
      sink.add(LlmCompleted(finishReason: finishReason, usage: usage));
      return;
    }

    final payload = decodeSseJsonObject(data, providerId);
    if (payload['error'] != null) {
      sink.add(LlmFailed(providerStreamError(providerId)));
      return;
    }

    final parsedUsage = usageFrom(payload['usage']);
    if (parsedUsage != null) {
      usage = parsedUsage;
      sink.add(LlmUsageUpdate(parsedUsage));
    }

    final choices = payload['choices'];
    if (choices == null) {
      return;
    }
    if (choices is! List) {
      throwLlm(LlmErrorKind.protocol, 'Expected choices to be a list.');
    }
    if (choices.isEmpty) {
      return;
    }
    final choice = asJsonObject(choices.first);
    if (choice == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected a choice object.');
    }
    final parsedReason = finishReasonFrom(choice['finish_reason']);
    if (parsedReason != null) {
      finishReason = parsedReason;
    }
    final delta = choice['delta'];
    if (delta == null) {
      return;
    }
    final deltaMap = asJsonObject(delta);
    if (deltaMap == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected a delta object.');
    }

    final reasoning = _textField(deltaMap, dialect.reasoningDeltaField);
    if (reasoning != null && reasoning.isNotEmpty) {
      sink.add(LlmReasoningDelta(reasoning));
    }
    final answer = _textField(deltaMap, dialect.answerDeltaField);
    if (answer != null && answer.isNotEmpty) {
      sink.add(LlmTextDelta(answer));
    }
    _emitToolCallDeltas(deltaMap['tool_calls'], sink);
  }

  void _emitToolCallDeltas(Object? rawCalls, LlmStreamSink sink) {
    if (rawCalls == null) {
      return;
    }
    if (rawCalls is! List) {
      throwLlm(LlmErrorKind.protocol, 'Expected tool_calls to be a list.');
    }
    for (final rawCall in rawCalls) {
      final call = asJsonObject(rawCall);
      if (call == null) {
        throwLlm(LlmErrorKind.protocol, 'Expected a tool call object.');
      }
      final index = readNonNegativeInt(call['index'], field: 'index') ?? 0;
      final idValue = call['id'];
      final function =
          asJsonObject(call['function']) ?? const <String, Object?>{};
      final name = function['name'] is String
          ? function['name'] as String
          : null;
      final arguments = function['arguments'] is String
          ? function['arguments'] as String
          : null;
      final callId = _stableCallId(index, idValue);
      sink.add(
        LlmToolCallDelta(
          callId: callId,
          index: index,
          name: name,
          argumentsFragment: arguments,
        ),
      );
    }
  }

  ToolCallId _stableCallId(int index, Object? idValue) {
    final existing = callIdsByIndex[index];
    if (idValue is String && idValue.trim().isNotEmpty) {
      final incoming = ToolCallId(idValue);
      if (existing != null && existing != incoming) {
        throwLlm(
          LlmErrorKind.protocol,
          'Tool call id for index $index changed during the stream.',
        );
      }
      callIdsByIndex[index] = incoming;
      return incoming;
    }
    if (existing != null) {
      return existing;
    }
    throwLlm(
      LlmErrorKind.protocol,
      'Tool call fragment is missing a stable call id.',
    );
  }

  static String? _textField(Map<String, Object?> delta, String field) {
    final value = delta[field];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throwLlm(LlmErrorKind.protocol, 'Expected $field to be text.');
    }
    return value;
  }
}

Map<String, Object?> buildChatCompletionsBody({
  required LlmRequest request,
  required LlmModel model,
  required ChatCompletionsDialect dialect,
}) {
  final messages = <Map<String, Object?>>[];
  final systemPrompt = request.context.systemPrompt;
  if (systemPrompt != null) {
    messages.add(<String, Object?>{'role': 'system', 'content': systemPrompt});
  }
  for (final message in request.context.messages) {
    messages.addAll(encodeChatCompletionsMessages(message, dialect));
  }

  final body = <String, Object?>{
    'model': model.id.value,
    'messages': messages,
    'stream': true,
    'stream_options': const <String, Object?>{'include_usage': true},
  };
  if (request.context.tools.isNotEmpty) {
    body['tools'] = request.context.tools
        .map(encodeChatCompletionsTool)
        .toList();
  }
  dialect.applyReasoning(body, request.generation);
  if (request.generation.temperature != null) {
    body['temperature'] = request.generation.temperature;
  }
  if (request.generation.maxOutputTokens != null) {
    body[dialect.outputTokenFieldName] = request.generation.maxOutputTokens;
  }
  return body;
}

List<Map<String, Object?>> encodeChatCompletionsMessages(
  LlmMessage message,
  ChatCompletionsDialect dialect,
) {
  switch (message.role) {
    case LlmMessageRole.user:
      return <Map<String, Object?>>[
        <String, Object?>{
          'role': 'user',
          'content': message.parts
              .whereType<LlmTextPart>()
              .map((part) => part.text)
              .join(),
        },
      ];
    case LlmMessageRole.assistant:
      final textBuffer = StringBuffer();
      final reasoningBuffer = StringBuffer();
      final toolCalls = <Map<String, Object?>>[];
      for (final part in message.parts) {
        switch (part) {
          case LlmTextPart(:final text):
            textBuffer.write(text);
          case LlmReasoningPart(:final text):
            reasoningBuffer.write(text);
          case LlmToolCallPart():
            toolCalls.add(<String, Object?>{
              'id': part.callId.value,
              'type': 'function',
              'function': <String, Object?>{
                'name': part.name,
                'arguments': part.arguments,
              },
            });
          case LlmToolResultPart():
            throwLlm(
              LlmErrorKind.configuration,
              'Assistant messages cannot contain tool results.',
            );
        }
      }
      final encoded = <String, Object?>{
        'role': 'assistant',
        'content': textBuffer.isEmpty ? null : textBuffer.toString(),
      };
      if (dialect.includeReasoningContentInHistory &&
          reasoningBuffer.isNotEmpty) {
        encoded['reasoning_content'] = reasoningBuffer.toString();
      }
      if (toolCalls.isNotEmpty) {
        encoded['tool_calls'] = toolCalls;
      }
      return <Map<String, Object?>>[encoded];
    case LlmMessageRole.tool:
      return message.parts
          .whereType<LlmToolResultPart>()
          .map((part) {
            return <String, Object?>{
              'role': 'tool',
              'tool_call_id': part.callId.value,
              'content': part.content,
            };
          })
          .toList(growable: false);
  }
}

Map<String, Object?> encodeChatCompletionsTool(LlmToolDescriptor tool) {
  final function = <String, Object?>{
    'name': tool.name,
    'parameters': jsonDecode(jsonEncode(tool.parameters)),
  };
  if (tool.description != null) {
    function['description'] = tool.description;
  }
  return <String, Object?>{'type': 'function', 'function': function};
}

LlmFinishReason? finishReasonFrom(Object? value) {
  if (value is! String) {
    return null;
  }
  return LlmFinishReason.fromWireName(value);
}

LlmUsage? usageFrom(Object? value) {
  if (value == null) {
    return null;
  }
  final map = asJsonObject(value);
  if (map == null) {
    throwLlm(LlmErrorKind.protocol, 'Expected a usage object.');
  }
  final input =
      readNonNegativeInt(map['prompt_tokens'], field: 'prompt_tokens') ??
      readNonNegativeInt(map['input_tokens'], field: 'input_tokens');
  final output =
      readNonNegativeInt(
        map['completion_tokens'],
        field: 'completion_tokens',
      ) ??
      readNonNegativeInt(map['output_tokens'], field: 'output_tokens');
  final total = readNonNegativeInt(map['total_tokens'], field: 'total_tokens');
  final cacheHit =
      readNonNegativeInt(
        map['prompt_cache_hit_tokens'],
        field: 'prompt_cache_hit_tokens',
      ) ??
      readNonNegativeInt(map['cached_tokens'], field: 'cached_tokens') ??
      _cachedTokensFromDetails(map);
  final cacheMiss = readNonNegativeInt(
    map['prompt_cache_miss_tokens'],
    field: 'prompt_cache_miss_tokens',
  );
  if (input == null &&
      output == null &&
      total == null &&
      cacheHit == null &&
      cacheMiss == null) {
    return null;
  }
  return LlmUsage(
    inputTokens: input,
    outputTokens: output,
    totalTokens: total,
    cacheHitTokens: cacheHit,
    cacheMissTokens: cacheMiss,
  );
}

int? _cachedTokensFromDetails(Map<String, Object?> usage) {
  final rawDetails = usage['prompt_tokens_details'];
  if (rawDetails == null) {
    return null;
  }
  final details = asJsonObject(rawDetails);
  if (details == null) {
    throwLlm(LlmErrorKind.protocol, 'Expected prompt_tokens_details object.');
  }
  return readNonNegativeInt(details['cached_tokens'], field: 'cached_tokens');
}
