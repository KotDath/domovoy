import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/profile_agent_factory.dart';
import 'package:domovoy/features/comparison/data/profile_credential_resolver.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/comparison_prompts.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fakes.dart';

void main() {
  test(
    'custom unauthenticated OpenAI-compatible profile uses loopback SSE',
    () async {
      String? authorization;
      late Map<String, dynamic> payload;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final subscription = server.listen((request) async {
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        payload =
            jsonDecode(await utf8.decodeStream(request))
                as Map<String, dynamic>;
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"ok"}}],'
          '"usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}\n\n'
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        );
        await request.response.close();
      });
      addTearDown(subscription.cancel);

      const prompt = 'exact sparse-set prompt';
      final profile = ChatModelProfile(
        id: 'custom-loopback',
        label: 'Custom loopback',
        tier: ComparisonTier.weak,
        endpoint: Uri.parse(
          'http://127.0.0.1:${server.port}/v1/chat/completions',
        ),
        modelId: 'custom-model',
        dialect: ChatRequestDialect.generic,
        authentication: ProfileAuthenticationMode.none,
        sourceUrl: Uri.parse('https://example.com/model'),
      );
      final client = http.Client();
      addTearDown(client.close);
      final agent = ProfileChatAgentFactory(
        client: client,
        sharedDeepSeekResolver: ApiKeyResolver(
          overrideStore: MemoryApiKeyOverrideStore('should-not-be-used'),
          environment: const MapEnvironmentReader({
            deepSeekApiKeyEnvironmentVariable: 'also-unused',
          }),
        ),
        profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      ).create(profile);

      final events = await agent
          .prompt(buildComparisonLaneInput(prompt))
          .toList();

      expect(authorization, isNull);
      expect(payload['model'], 'custom-model');
      expect((payload['messages'] as List).single['content'], prompt);
      expect(payload.containsKey('thinking'), isFalse);
      expect(events.whereType<AgentAnswerDelta>().single.text, 'ok');
      final completed = events.last as AgentCompleted;
      expect(completed.usage?.promptTokens, 8);
      expect(completed.usage?.completionTokens, 2);
      expect(completed.usage?.totalTokens, 10);
      expect(completed.finishReason, AgentFinishReason.stop);
    },
  );
}
