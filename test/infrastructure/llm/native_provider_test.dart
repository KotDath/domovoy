import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/llm/discovery/native_streaming_provider.dart';
import 'package:domovoy/infrastructure/llm/discovery/provider_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Anthropic native SSE preserves inclusive cache and thinking usage', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/messages');
      expect(request.headers['x-api-key'], 'anthropic-test-key');
      expect(request.headers['Authorization'], isNull);
      expect(jsonDecode(request.body)['model'], 'claude-test');
      return http.Response(
        'event: message_start\ndata: {"message":{"usage":{"input_tokens":40,"cache_creation_input_tokens":3,"cache_read_input_tokens":7}}}\n\n'
        'event: content_block_delta\ndata: {"delta":{"type":"text_delta","text":"Hello"}}\n\n'
        'event: message_delta\ndata: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":17,"output_tokens_details":{"thinking_tokens":15}}}\n\n'
        'event: message_stop\ndata: {}\n\n',
        200,
      );
    });
    addTearDown(client.close);
    final provider = NativeStreamingLlmProvider(
      spec: ApiKeyProviderManifest.find('anthropic')!,
      client: client,
      credentials: _credentials('anthropic', 'anthropic-test-key'),
    );
    final events = await provider
        .stream(
          _request('anthropic', 'claude-test'),
          cancellation: CancellationSource().token,
        )
        .toList();
    expect(events.whereType<LlmTextDelta>().single.text, 'Hello');
    final usage = events.last as LlmCompleted;
    expect(usage.usage!.requestContext?.value, 50);
    expect(usage.usage!.responseGenerated?.value, 17);
    expect(usage.usage!.reasoning?.value, 15);
  });

  test('Gemini native SSE uses header auth and reported usage', () async {
    final client = MockClient((request) async {
      expect(
        request.url.path,
        '/v1beta/models/gemini-test:streamGenerateContent',
      );
      expect(request.url.queryParameters['alt'], 'sse');
      expect(request.headers['x-goog-api-key'], 'gemini-test-key');
      expect(request.url.queryParameters.containsKey('key'), isFalse);
      return http.Response(
        'data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":40,"cachedContentTokenCount":10,"candidatesTokenCount":2,"thoughtsTokenCount":3,"totalTokenCount":45}}\n\n',
        200,
      );
    });
    addTearDown(client.close);
    final provider = NativeStreamingLlmProvider(
      spec: ApiKeyProviderManifest.find('google')!,
      client: client,
      credentials: _credentials('google', 'gemini-test-key'),
    );
    final events = await provider
        .stream(
          _request('google', 'gemini-test'),
          cancellation: CancellationSource().token,
        )
        .toList();
    expect(events.whereType<LlmTextDelta>().single.text, 'Hi');
    final usage = (events.last as LlmCompleted).usage!;
    expect(usage.requestContext?.value, 40);
    expect(usage.responseGenerated?.value, 5);
    expect(usage.cacheRead?.value, 10);
    expect(usage.reasoning?.value, 3);
  });
}

ProviderCredentialResolver _credentials(String provider, String key) =>
    DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(<ProviderId, String>{
        ProviderId(provider): key,
      }),
      readEnvironment: (_) => null,
    );

LlmRequest _request(String provider, String model) => LlmRequest(
  model: ModelRef(providerId: ProviderId(provider), modelId: ModelId(model)),
  context: LlmContext(
    messages: <LlmMessage>[
      LlmMessage(
        role: LlmMessageRole.user,
        parts: <LlmContentPart>[LlmTextPart('hello')],
      ),
    ],
  ),
  generation: LlmGenerationConfig(reasoningMode: ReasoningMode.disabled),
);
