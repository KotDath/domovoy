import 'dart:io';

import 'package:characters/characters.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/data/openai_compatible_chat_agent.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/temperature/domain/temperature_models.dart';
import 'package:domovoy/features/temperature/domain/temperature_prompts.dart';
import 'package:domovoy/features/temperature/presentation/temperature_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'live DeepSeek smoke covers three Day 4 temperature lanes',
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
      final controller = TemperatureController(recording);
      addTearDown(controller.dispose);

      expect(
        controller.runComparison(
          rawPrompt: kTemperatureStarterPrompt,
          temperatures: kTemperaturePresetValues,
        ),
        isTrue,
      );
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (controller.isRunning && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(controller.isRunning, isFalse);
      expect(recording.inputs, hasLength(3));
      expect(
        recording.inputs.map((input) => input.temperature),
        kTemperaturePresetValues,
      );
      for (final input in recording.inputs) {
        expect(input.text, kTemperatureStarterPrompt);
        expect(input.thinking, ThinkingMode.disabled);
        expect(input.control, isNull);
      }
      expect(controller.completedApiCalls, 3);
      for (var index = 0; index < 3; index++) {
        final lane = controller.state.lanes[index];
        expect(lane.status, TemperatureLaneStatus.completed);
        expect(lane.answer, isNotEmpty);
        expect(lane.appliedTemperature, kTemperaturePresetValues[index]);
        _report(
          't=${temperatureValueLabel(kTemperaturePresetValues[index])}',
          lane,
        );
      }

      // ignore: avoid_print
      print(
        'day4-aggregate: calls=${controller.completedApiCalls}, '
        'promptChars=${kTemperatureStarterPrompt.characters.length}, '
        'temps=${kTemperaturePresetValues.map(temperatureValueLabel).join(',')}, '
        'thinking=disabled, top_p=omitted',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

void _report(String label, TemperatureLaneState lane) {
  final usage = lane.usage;
  // ignore: avoid_print
  print(
    '$label: answerChars=${lane.answer.characters.length}, '
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
