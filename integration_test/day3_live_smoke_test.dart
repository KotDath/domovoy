import 'dart:io';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/data/openai_compatible_chat_agent.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/reasoning/domain/four_house_puzzle.dart';
import 'package:domovoy/features/reasoning/domain/reasoning_models.dart';
import 'package:domovoy/features/reasoning/presentation/reasoning_controller.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'live DeepSeek smoke covers all eight Day 3 stages',
    () async {
      final key = Platform.environment['DEEPSEEK_API_KEY']?.trim();
      if (key == null || key.isEmpty) {
        fail('Set DEEPSEEK_API_KEY only for this opt-in live smoke test.');
      }

      final client = http.Client();
      addTearDown(client.close);
      final recording = _RecordingAgent(
        OpenAiCompatibleChatAgent(
          client: client,
          apiKeyResolver: ApiKeyResolver(
            overrideStore: _EmptyOverrideStore(),
            environment: MapEnvironmentReader({'DEEPSEEK_API_KEY': key}),
          ),
          profile: ChatCompletionsProviderProfile.deepSeekV4Flash(),
        ),
      );
      final controller = ReasoningController(recording);
      addTearDown(controller.dispose);

      expect(controller.runComparison(fourHousePresetTask), isTrue);
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (controller.isRunning && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(controller.isRunning, isFalse);
      expect(recording.inputs, hasLength(8));
      for (final input in recording.inputs) {
        expect(input.thinking, ThinkingMode.disabled);
        expect(input.control, isNull);
      }
      expect(controller.completedApiCalls, 8);
      expect(controller.state.direct.status, ReasoningLaneStatus.completed);
      expect(controller.state.direct.answer, isNotEmpty);
      expect(controller.state.stepByStep.status, ReasoningLaneStatus.completed);
      expect(controller.state.stepByStep.answer, isNotEmpty);
      expect(
        controller.state.promptBuilder.status,
        ReasoningLaneStatus.completed,
      );
      expect(controller.state.generatedPrompt, isNotEmpty);
      expect(controller.state.generated.status, ReasoningLaneStatus.completed);
      expect(controller.state.generated.answer, isNotEmpty);
      expect(
        controller.state.expertAnalyst.status,
        ReasoningLaneStatus.completed,
      );
      expect(controller.state.expertAnalyst.answer, isNotEmpty);
      expect(
        controller.state.expertEngineer.status,
        ReasoningLaneStatus.completed,
      );
      expect(controller.state.expertEngineer.answer, isNotEmpty);
      expect(
        controller.state.expertCritic.status,
        ReasoningLaneStatus.completed,
      );
      expect(controller.state.expertCritic.answer, isNotEmpty);
      expect(
        controller.state.expertGroup.status,
        ReasoningLaneStatus.completed,
      );
      expect(controller.state.expertGroup.answer, isNotEmpty);
      expect(fourHouseReference.isUnique, isTrue);

      _report('direct', controller.state.direct);
      _report('stepByStep', controller.state.stepByStep);
      _report('promptBuilder', controller.state.promptBuilder);
      _report('generatedSolver', controller.state.generated);
      _report('expertAnalyst', controller.state.expertAnalyst);
      _report('expertEngineer', controller.state.expertEngineer);
      _report('expertCritic', controller.state.expertCritic);
      _report('expertSynthesis', controller.state.expertGroup);
      // ignore: avoid_print
      print(
        'day3-aggregate: calls=${controller.completedApiCalls}, '
        'generatedPromptChars=${controller.state.generatedPrompt.runes.length}, '
        'referenceUnique=${fourHouseReference.isUnique}, '
        'verdictsUnrated=${ReasoningStrategy.values.every((strategy) => controller.state.laneFor(strategy).verdict == ReasoningVerdict.unrated)}',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

void _report(String label, ReasoningLaneState lane) {
  final usage = lane.usage;
  // ignore: avoid_print
  print(
    '$label: answerChars=${lane.answer.runes.length}, '
    'status=${lane.status.name}, '
    'finish=${agentFinishReasonLabel(lane.finishReason)}, '
    'completionTokens=${usage?.completionTokens ?? '-'}',
  );
}

final class _RecordingAgent implements Agent {
  _RecordingAgent(this._inner);

  final Agent _inner;
  final List<AgentInput> inputs = <AgentInput>[];

  @override
  Stream<AgentEvent> prompt(AgentInput input) {
    inputs.add(input);
    return _inner.prompt(input);
  }
}

final class _EmptyOverrideStore implements ApiKeyOverrideStore {
  @override
  Future<void> delete() async {}

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}
