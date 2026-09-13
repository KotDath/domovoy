import 'package:http/http.dart' as http;

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/credentials.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/events.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/json.dart';
import '../../../core/llm/messages.dart';
import '../../../core/llm/provider.dart';
import '../../../core/llm/request.dart';
import '../../../core/llm/usage.dart';
import '../openai_compatible/stream_session.dart';
import 'provider_manifest.dart';

/// Text-chat streaming for the two native API-key protocol families.
/// Tool turns are deliberately unavailable until opaque thinking signatures
/// can be preserved across a provider-specific continuation.
final class NativeStreamingLlmProvider implements LlmProvider {
  NativeStreamingLlmProvider({
    required this.spec,
    required http.Client client,
    required ProviderCredentialResolver credentials,
  }) : _client = client,
       _credentials = credentials {
    if (spec.protocol != ApiKeyProviderProtocol.anthropicMessages &&
        spec.protocol != ApiKeyProviderProtocol.geminiGenerateContent) {
      throw ArgumentError.value(
        spec.protocol,
        'spec',
        'Native protocol required',
      );
    }
  }

  final ApiKeyProviderSpec spec;
  final http.Client _client;
  final ProviderCredentialResolver _credentials;

  @override
  ProviderId get id => ProviderId(spec.id);

  @override
  LlmWireFamily get wireFamily => spec.wireFamily;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    if (request.model.providerId != id || request.context.tools.isNotEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Unsupported native provider request.',
      );
    }
    final anthropic = spec.protocol == ApiKeyProviderProtocol.anthropicMessages;
    final endpoint = anthropic
        ? Uri.parse(spec.endpoint)
        : Uri.parse(
            '${spec.endpoint}/${Uri.encodeComponent(request.model.modelId.value)}:streamGenerateContent?alt=sse',
          );
    final body = anthropic ? _anthropicBody(request) : _geminiBody(request);
    final parser = anthropic ? _AnthropicStream(id) : _GeminiStream(id);
    return runLlmHttpStream(
      providerId: id,
      endpoint: endpoint,
      body: body,
      client: _client,
      credentials: _credentials,
      environmentVariable: spec.environmentVariable,
      authorizationHeaders: (key) => anthropic
          ? <String, String>{
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
            }
          : <String, String>{'x-goog-api-key': key},
      cancellation: cancellation,
      consume: (response, sink, token) => consumeSse(
        response: response,
        sink: sink,
        cancellation: token,
        onMessage: (message, eventSink) async =>
            parser.handle(message.event, message.data, eventSink),
      ),
    );
  }

  Map<String, Object?> _anthropicBody(LlmRequest request) {
    final messages = <Map<String, Object?>>[];
    for (final message in request.context.messages) {
      if (message.role == LlmMessageRole.tool) {
        throwLlm(
          LlmErrorKind.configuration,
          'Native tool history is unavailable.',
        );
      }
      messages.add(<String, Object?>{
        'role': message.role == LlmMessageRole.user ? 'user' : 'assistant',
        'content': _text(message),
      });
    }
    return <String, Object?>{
      'model': request.model.modelId.value,
      'stream': true,
      'max_tokens': request.generation.maxOutputTokens ?? 4096,
      if (request.context.systemPrompt != null)
        'system': request.context.systemPrompt,
      'messages': messages,
    };
  }

  Map<String, Object?> _geminiBody(LlmRequest request) => <String, Object?>{
    if (request.context.systemPrompt != null)
      'systemInstruction': <String, Object?>{
        'parts': <Map<String, String>>[
          <String, String>{'text': request.context.systemPrompt!},
        ],
      },
    'contents': <Map<String, Object?>>[
      for (final message in request.context.messages)
        <String, Object?>{
          'role': message.role == LlmMessageRole.user ? 'user' : 'model',
          'parts': <Map<String, String>>[
            <String, String>{'text': _text(message)},
          ],
        },
    ],
    'generationConfig': <String, Object?>{
      if (request.generation.maxOutputTokens != null)
        'maxOutputTokens': request.generation.maxOutputTokens,
      if (request.generation.temperature != null)
        'temperature': request.generation.temperature,
    },
  };

  static String _text(LlmMessage message) => message.parts
      .whereType<LlmTextPart>()
      .map((part) => part.text)
      .join('\n');
}

abstract class _NativeStream {
  _NativeStream(this.id);
  final ProviderId id;
  LlmUsage? usage;
  void handle(String? event, String data, LlmStreamSink sink);

  Map<String, Object?> payload(String data) => decodeSseJsonObject(data, id);

  void error(Map<String, Object?> value, LlmStreamSink sink) => sink.add(
    LlmFailed(
      providerStreamError(
        id,
        payload: value,
        credentialValue: sink.credentialValue,
      ),
    ),
  );

  void update(LlmUsage next, LlmStreamSink sink) {
    usage = next;
    sink.add(LlmUsageUpdate(next));
  }

  static LlmUsageCounter counter(Object? value) =>
      LlmUsageCounter.fromAliases(<Object?>[value]);
}

final class _AnthropicStream extends _NativeStream {
  _AnthropicStream(super.id);
  Map<String, Object?>? _inputUsage;
  Map<String, Object?>? _outputUsage;
  LlmFinishReason? _reason;

  @override
  void handle(String? event, String data, LlmStreamSink sink) {
    final value = payload(data);
    if (event == 'error' || value['type'] == 'error') {
      error(value, sink);
      return;
    }
    final type = event ?? value['type'];
    switch (type) {
      case 'message_start':
        final message = asJsonObject(value['message']);
        _inputUsage = asJsonObject(message?['usage']);
        _emitUsage(sink);
      case 'content_block_delta':
        final delta = asJsonObject(value['delta']);
        if (delta == null) {
          throw const FormatException('Missing Anthropic delta');
        }
        final text = delta['text'];
        if (text is String && text.isNotEmpty) sink.add(LlmTextDelta(text));
        final thinking = delta['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          sink.add(LlmReasoningDelta(thinking));
        }
      case 'message_delta':
        _outputUsage = asJsonObject(value['usage']) ?? _outputUsage;
        final delta = asJsonObject(value['delta']);
        _reason = switch (delta?['stop_reason']) {
          'end_turn' || 'stop_sequence' => LlmFinishReason.stop,
          'max_tokens' => LlmFinishReason.length,
          'tool_use' => LlmFinishReason.toolCalls,
          _ => _reason,
        };
        _emitUsage(sink);
      case 'message_stop':
        sink.add(LlmCompleted(finishReason: _reason, usage: usage));
    }
  }

  void _emitUsage(LlmStreamSink sink) {
    final input = _inputUsage;
    final output = _outputUsage;
    if (input == null && output == null) return;
    final base = input?['input_tokens'];
    final read = input?['cache_read_input_tokens'];
    final write = input?['cache_creation_input_tokens'];
    final reasoningDetails = asJsonObject(output?['output_tokens_details']);
    final knownInput = <Object?>[base, read, write].whereType<int>().toList();
    final inputTotal = knownInput.isEmpty
        ? null
        : knownInput.fold<int>(0, (a, b) => a + b);
    final outputTotal = output?['output_tokens'];
    update(
      normalizeLlmUsage(
        input: _NativeStream.counter(base),
        cacheRead: _NativeStream.counter(read),
        cacheWrite: _NativeStream.counter(write),
        reportedInputTotal: _NativeStream.counter(inputTotal),
        reportedOutputTotal: _NativeStream.counter(outputTotal),
        reasoning: _NativeStream.counter(reasoningDetails?['thinking_tokens']),
        semantics: const LlmUsageNormalizationSemantics(
          outputIncludesReasoning: true,
        ),
      ),
      sink,
    );
  }
}

final class _GeminiStream extends _NativeStream {
  _GeminiStream(super.id);
  LlmFinishReason? _reason;

  @override
  void handle(String? event, String data, LlmStreamSink sink) {
    final value = payload(data);
    if (value['error'] != null) {
      error(value, sink);
      return;
    }
    final candidates = value['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final candidate = asJsonObject(candidates.first);
      final content = asJsonObject(candidate?['content']);
      final parts = content?['parts'];
      if (parts is List) {
        for (final part in parts) {
          final map = asJsonObject(part);
          final text = map?['text'];
          if (text is String && text.isNotEmpty) {
            sink.add(
              map?['thought'] == true
                  ? LlmReasoningDelta(text)
                  : LlmTextDelta(text),
            );
          }
        }
      }
      _reason = switch (candidate?['finishReason']) {
        'STOP' => LlmFinishReason.stop,
        'MAX_TOKENS' => LlmFinishReason.length,
        'SAFETY' => LlmFinishReason.contentFilter,
        _ => _reason,
      };
    }
    final rawUsage = asJsonObject(value['usageMetadata']);
    if (rawUsage != null) {
      final candidateTokens = rawUsage['candidatesTokenCount'];
      final thoughtTokens = rawUsage['thoughtsTokenCount'];
      final outputTotal = candidateTokens is int && thoughtTokens is int
          ? candidateTokens + thoughtTokens
          : candidateTokens;
      update(
        normalizeLlmUsage(
          reportedInputTotal: _NativeStream.counter(
            rawUsage['promptTokenCount'],
          ),
          cacheRead: _NativeStream.counter(rawUsage['cachedContentTokenCount']),
          output: _NativeStream.counter(candidateTokens),
          reasoning: _NativeStream.counter(thoughtTokens),
          reportedOutputTotal: _NativeStream.counter(outputTotal),
          reportedOverall: _NativeStream.counter(rawUsage['totalTokenCount']),
          semantics: const LlmUsageNormalizationSemantics(
            inputIncludesCacheRead: true,
          ),
        ),
        sink,
      );
    }
    if (_reason != null) {
      sink.add(LlmCompleted(finishReason: _reason, usage: usage));
    }
  }
}
