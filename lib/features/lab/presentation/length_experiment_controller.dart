import '../../prompt/domain/agent.dart';
import 'comparison_controller.dart';

class LengthLimits {
  static const int minChars = 1;
  static const int maxChars = 20000;
  static const int minTokens = 1;
  static const int maxTokens = 16384;
  static const int reasoningBudgetWarningTokens = 500;
}

final class LengthExperimentController extends BaselineControlledController {
  LengthExperimentController(super.agent);

  String basePrompt = 'Объясни, что такое домовой, коротко и понятно.';
  String maxCharsText = '300';
  String maxTokensText = '300';

  String? promptError;
  String? maxCharsError;
  String? maxTokensError;

  int? activeMaxChars;
  int? activeMaxTokens;
  ThinkingMode lastThinking = ThinkingMode.enabled;

  bool get showsReasoningBudgetWarning =>
      lastThinking == ThinkingMode.enabled &&
      (activeMaxTokens ?? int.tryParse(maxTokensText.trim()) ?? 0) <
          LengthLimits.reasoningBudgetWarningTokens &&
      controlled.status != ExperimentLaneStatus.idle;

  bool runComparison({
    required String rawPrompt,
    required String rawMaxChars,
    required String rawMaxTokens,
    required ThinkingMode thinking,
  }) {
    if (isRunning) {
      return false;
    }
    final prompt = rawPrompt.trim();
    promptError = prompt.isEmpty ? 'Введите базовый запрос.' : null;

    final chars = int.tryParse(rawMaxChars.trim());
    if (chars == null) {
      maxCharsError = 'Введите число символов.';
    } else if (chars < LengthLimits.minChars || chars > LengthLimits.maxChars) {
      maxCharsError =
          'Цель должна быть от ${LengthLimits.minChars} '
          'до ${LengthLimits.maxChars} символов.';
    } else {
      maxCharsError = null;
    }

    final tokens = int.tryParse(rawMaxTokens.trim());
    if (tokens == null) {
      maxTokensError = 'Введите число токенов.';
    } else if (tokens < LengthLimits.minTokens ||
        tokens > LengthLimits.maxTokens) {
      maxTokensError =
          'Лимит должен быть от ${LengthLimits.minTokens} '
          'до ${LengthLimits.maxTokens} токенов.';
    } else {
      maxTokensError = null;
    }

    if (promptError != null ||
        maxCharsError != null ||
        maxTokensError != null) {
      refresh();
      return false;
    }

    basePrompt = rawPrompt;
    maxCharsText = rawMaxChars;
    maxTokensText = rawMaxTokens;
    activeMaxChars = chars;
    activeMaxTokens = tokens;
    lastThinking = thinking;

    final baselineInput = AgentInput(prompt, thinking: thinking);
    final controlledInput = AgentInput(
      prompt,
      thinking: thinking,
      control: LengthControl(maxChars: chars!, maxTokens: tokens!),
    );
    runPair(baselineInput, controlledInput);
    return true;
  }

  bool get baselineTruncated =>
      baseline.status == ExperimentLaneStatus.completed &&
      baseline.finishReason == AgentFinishReason.length;

  bool get controlledTruncated =>
      controlled.status == ExperimentLaneStatus.completed &&
      controlled.finishReason == AgentFinishReason.length;
}
