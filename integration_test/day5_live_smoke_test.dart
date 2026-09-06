import 'dart:io';

import 'package:characters/characters.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/profile_agent_factory.dart';
import 'package:domovoy/features/comparison/data/profile_credential_resolver.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/comparison_prompts.dart';
import 'package:domovoy/features/comparison/domain/elapsed_timer.dart';
import 'package:domovoy/features/comparison/domain/token_cost.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../test/support/fakes.dart';

void main() {
  test(
    'opt-in DeepSeek smoke covers Flash and Pro model ids',
    () async {
      final key = Platform.environment['DEEPSEEK_API_KEY']?.trim();
      if (key == null || key.isEmpty) {
        fail('Set DEEPSEEK_API_KEY only for this opt-in live smoke test.');
      }

      final client = http.Client();
      addTearDown(client.close);
      final factory = ProfileChatAgentFactory(
        client: client,
        sharedDeepSeekResolver: ApiKeyResolver(
          overrideStore: MemoryApiKeyOverrideStore(),
          environment: MapEnvironmentReader({'DEEPSEEK_API_KEY': key}),
        ),
        profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: MapEnvironmentReader({'DEEPSEEK_API_KEY': key}),
      );

      for (final profile in [kDeepSeekFlashProfile, kDeepSeekProProfile]) {
        await _runProfile(factory.create(profile), profile);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _runProfile(Agent agent, ChatModelProfile profile) async {
  final clock = StopwatchElapsedClock();
  Duration? ttft;
  final answer = StringBuffer();
  AgentFinishReason? completedReason;
  AgentTokenUsage? completedUsage;
  AgentFailure? failure;

  await for (final event in agent.prompt(
    buildComparisonLaneInput(kComparisonStarterPrompt),
  )) {
    switch (event) {
      case AgentAnswerDelta(:final text):
        if (text.isNotEmpty && ttft == null) {
          ttft = clock.elapsed();
        }
        answer.write(text);
      case AgentCompleted(:final finishReason, :final usage):
        completedReason = finishReason;
        completedUsage = usage;
      case AgentFailed(failure: final failed):
        failure = failed;
      case AgentReasoningDelta():
        break;
    }
  }
  final total = clock.elapsed();
  expect(failure, isNull, reason: failure?.message ?? '');
  expect(answer.toString(), isNotEmpty);
  expect(profile.modelId, anyOf(kDeepSeekFlashModelId, kDeepSeekProModelId));
  final cost = estimateProviderCost(
    pricing: profile.pricing,
    usage: completedUsage,
  );
  // ignore: avoid_print
  print(
    'day5-deepseek-aggregate: model=${profile.modelId}, '
    'status=${failure == null ? 'completed' : 'failed'}, '
    'finish=${agentFinishReasonLabel(completedReason)}, '
    'ttftMs=${ttft?.inMilliseconds ?? '-'}, '
    'totalMs=${total.inMilliseconds}, '
    'promptTokens=${completedUsage?.promptTokens ?? '-'}, '
    'completionTokens=${completedUsage?.completionTokens ?? '-'}, '
    'totalTokens=${completedUsage?.totalTokens ?? '-'}, '
    'cacheHit=${completedUsage?.cacheHitPromptTokens ?? '-'}, '
    'cacheMiss=${completedUsage?.cacheMissPromptTokens ?? '-'}, '
    'cost=${formatEstimatedCost(cost)}, '
    'answerChars=${answer.toString().characters.length}',
  );
}
