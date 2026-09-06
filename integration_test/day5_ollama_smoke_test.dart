import 'dart:io';

import 'package:characters/characters.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/profile_agent_factory.dart';
import 'package:domovoy/features/comparison/data/profile_credential_resolver.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/comparison_prompts.dart';
import 'package:domovoy/features/comparison/domain/elapsed_timer.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../test/support/fakes.dart';

void main() {
  test(
    'opt-in Linux Ollama smoke for installed qwen3.5:2b',
    () async {
      if (!Platform.isLinux) {
        fail('Ollama smoke is documented for Linux only.');
      }

      final client = http.Client();
      addTearDown(client.close);
      final agent = ProfileChatAgentFactory(
        client: client,
        sharedDeepSeekResolver: ApiKeyResolver(
          overrideStore: MemoryApiKeyOverrideStore(),
          environment: const MapEnvironmentReader({}),
        ),
        profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      ).create(kOllamaQwen35Profile);

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
      // ignore: avoid_print
      print(
        'day5-ollama-aggregate: model=$kOllamaQwen35ModelId, '
        'status=${failure == null ? 'completed' : 'failed'}, '
        'finish=${agentFinishReasonLabel(completedReason)}, '
        'ttftMs=${ttft?.inMilliseconds ?? '-'}, '
        'totalMs=${total.inMilliseconds}, '
        'promptTokens=${completedUsage?.promptTokens ?? '-'}, '
        'completionTokens=${completedUsage?.completionTokens ?? '-'}, '
        'totalTokens=${completedUsage?.totalTokens ?? '-'}, '
        'answerChars=${answer.toString().characters.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
