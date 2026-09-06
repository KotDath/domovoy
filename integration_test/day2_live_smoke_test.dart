import 'dart:io';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/lab/domain/format_contracts.dart';
import 'package:domovoy/features/lab/domain/format_validators.dart';
import 'package:domovoy/features/lab/domain/repair_input.dart';
import 'package:domovoy/features/lab/presentation/stop_experiment_controller.dart';
import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/data/openai_compatible_chat_agent.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'live DeepSeek smoke covers Format, Length, Stop, and optional repair',
    () async {
      final key = Platform.environment['DEEPSEEK_API_KEY']?.trim();
      if (key == null || key.isEmpty) {
        fail('Set DEEPSEEK_API_KEY only for this opt-in live smoke test.');
      }

      final client = http.Client();
      addTearDown(client.close);
      final agent = OpenAiCompatibleChatAgent(
        client: client,
        apiKeyResolver: ApiKeyResolver(
          overrideStore: _EmptyOverrideStore(),
          environment: MapEnvironmentReader({'DEEPSEEK_API_KEY': key}),
        ),
        profile: ChatCompletionsProviderProfile.deepSeekV4Flash(),
      );

      const formatPrompt =
          'Придумай короткое описание домового и три правила для дома.';
      final formatContract = JsonFormatContract.demo();
      final formatControl = FormatControl(
        kind: ResponseFormatKind.json,
        contractText: formatContract.describe(),
        exampleText: formatContract.example(),
      );
      final formatBaseline = await _collect(
        agent,
        AgentInput(formatPrompt, thinking: ThinkingMode.disabled),
      );
      final formatControlled = await _collect(
        agent,
        AgentInput(
          formatPrompt,
          thinking: ThinkingMode.disabled,
          control: formatControl,
        ),
      );
      expect(formatBaseline.answer, isNotEmpty);
      expect(formatControlled.answer, isNotEmpty);
      final formatValidation = validateJsonAnswer(
        formatControlled.answer,
        formatContract,
      );
      _report('format-baseline', formatBaseline);
      _report(
        'format-controlled valid=${formatValidation.valid}',
        formatControlled,
      );

      if (!formatValidation.valid) {
        final repaired = await _collect(
          agent,
          buildFormatRepairInput(
            originalTask: formatPrompt,
            control: formatControl,
            invalidAnswer: formatControlled.answer,
            diagnostics: formatValidation.diagnostics,
            thinking: ThinkingMode.disabled,
          ),
        );
        expect(repaired.answer, isNotEmpty);
        final repairedValidation = validateJsonAnswer(
          repaired.answer,
          formatContract,
        );
        _report('format-repair valid=${repairedValidation.valid}', repaired);
      }

      const lengthPrompt =
          'Объясни простыми словами, зачем проветривать квартиру.';
      final lengthBaseline = await _collect(
        agent,
        AgentInput(lengthPrompt, thinking: ThinkingMode.disabled),
      );
      final lengthControlled = await _collect(
        agent,
        AgentInput(
          lengthPrompt,
          thinking: ThinkingMode.disabled,
          control: LengthControl(maxChars: 160, maxTokens: 96),
        ),
      );
      expect(lengthBaseline.answer, isNotEmpty);
      expect(lengthControlled.answer, isNotEmpty);
      _report('length-baseline', lengthBaseline);
      _report('length-controlled target=160 maxTokens=96', lengthControlled);

      const marker = '<END_OF_ANSWER>';
      const stopPrompt =
          'Дай короткий совет по дому, затем выведи маркер '
          '$marker, а после него напиши предложение '
          '«$stopPostMarkerSentence».';
      final stopBaseline = await _collect(
        agent,
        AgentInput(stopPrompt, thinking: ThinkingMode.disabled),
      );
      final stopControlled = await _collect(
        agent,
        AgentInput(
          stopPrompt,
          thinking: ThinkingMode.disabled,
          control: StopControl(marker),
        ),
      );
      expect(stopBaseline.answer, isNotEmpty);
      expect(stopControlled.answer, isNotEmpty);
      final baselineEvidence = stopEvidenceFor(stopBaseline.answer, marker);
      final controlledEvidence = stopEvidenceFor(stopControlled.answer, marker);
      _report(
        'stop-baseline marker=${baselineEvidence.containsMarker} '
        'postSentence=${baselineEvidence.containsPostMarkerSentence}',
        stopBaseline,
      );
      _report(
        'stop-controlled marker=${controlledEvidence.containsMarker} '
        'postSentence=${controlledEvidence.containsPostMarkerSentence}',
        stopControlled,
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<_LiveResult> _collect(Agent agent, AgentInput input) async {
  final reasoning = StringBuffer();
  final answer = StringBuffer();
  AgentFinishReason? finishReason;
  AgentTokenUsage? usage;
  await for (final event in agent.prompt(input)) {
    switch (event) {
      case AgentReasoningDelta(:final text):
        reasoning.write(text);
      case AgentAnswerDelta(:final text):
        answer.write(text);
      case AgentCompleted(finishReason: final reason, usage: final tokens):
        finishReason = reason;
        usage = tokens;
      case AgentFailed(:final failure):
        fail('Live request failed (${failure.kind.name}): ${failure.message}');
    }
  }
  return _LiveResult(
    reasoning: reasoning.toString(),
    answer: answer.toString(),
    finishReason: finishReason,
    usage: usage,
  );
}

void _report(String label, _LiveResult result) {
  final usage = result.usage;
  // Deliberately report only non-secret aggregate evidence.
  // ignore: avoid_print
  print(
    '$label: answerChars=${result.answer.runes.length}, '
    'reasoningChars=${result.reasoning.runes.length}, '
    'finish=${agentFinishReasonLabel(result.finishReason)}, '
    'completionTokens=${usage?.completionTokens ?? '-'}',
  );
}

final class _LiveResult {
  const _LiveResult({
    required this.reasoning,
    required this.answer,
    required this.finishReason,
    required this.usage,
  });

  final String reasoning;
  final String answer;
  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
}

final class _EmptyOverrideStore implements ApiKeyOverrideStore {
  @override
  Future<void> delete() async {}

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}
