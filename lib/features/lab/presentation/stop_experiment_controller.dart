import '../../prompt/domain/agent.dart';
import 'comparison_controller.dart';

/// Distinctive sentence the stop preset asks the model to emit after the
/// marker. Detected independently from marker presence: the model may emit
/// the sentence without the marker, or the marker may be removed by the
/// provider stop while the sentence never appears.
const stopPostMarkerSentence = 'Продолжение после маркера';

final class StopEvidence {
  const StopEvidence({
    required this.containsMarker,
    required this.containsPostMarkerText,
    required this.containsPostMarkerSentence,
  });

  final bool containsMarker;
  final bool containsPostMarkerText;
  final bool containsPostMarkerSentence;
}

StopEvidence stopEvidenceFor(
  String answer,
  String marker, {
  String postMarkerSentence = stopPostMarkerSentence,
}) {
  final containsSentence =
      postMarkerSentence.isNotEmpty && answer.contains(postMarkerSentence);
  final trimmedMarker = marker.trim();
  if (trimmedMarker.isEmpty || answer.isEmpty) {
    return StopEvidence(
      containsMarker: false,
      containsPostMarkerText: false,
      containsPostMarkerSentence: containsSentence,
    );
  }
  final index = answer.indexOf(trimmedMarker);
  if (index < 0) {
    return StopEvidence(
      containsMarker: false,
      containsPostMarkerText: false,
      containsPostMarkerSentence: containsSentence,
    );
  }
  final after = answer.substring(index + trimmedMarker.length).trim();
  return StopEvidence(
    containsMarker: true,
    containsPostMarkerText: after.isNotEmpty,
    containsPostMarkerSentence: containsSentence,
  );
}

final class StopExperimentController extends BaselineControlledController {
  StopExperimentController(super.agent);

  String basePrompt =
      'Дай короткий совет по дому, затем выведи маркер <END_OF_ANSWER>, '
      'а после него напиши предложение «Продолжение после маркера».';
  String markerText = '<END_OF_ANSWER>';

  String? promptError;
  String? markerError;

  String? activeMarker;
  ThinkingMode lastThinking = ThinkingMode.enabled;

  StopEvidence get baselineEvidence =>
      stopEvidenceFor(baseline.answer, activeMarker ?? markerText);

  StopEvidence get controlledEvidence =>
      stopEvidenceFor(controlled.answer, activeMarker ?? markerText);

  bool runComparison({
    required String rawPrompt,
    required String rawMarker,
    required ThinkingMode thinking,
  }) {
    if (isRunning) {
      return false;
    }
    final prompt = rawPrompt.trim();
    promptError = prompt.isEmpty
        ? 'Введите запрос с инструкцией про маркер.'
        : null;
    final marker = rawMarker.trim();
    markerError = marker.isEmpty ? 'Введите непустой стоп-маркер.' : null;
    if (promptError != null || markerError != null) {
      refresh();
      return false;
    }
    basePrompt = rawPrompt;
    markerText = rawMarker;
    activeMarker = marker;
    lastThinking = thinking;

    final baselineInput = AgentInput(prompt, thinking: thinking);
    final controlledInput = AgentInput(
      prompt,
      thinking: thinking,
      control: StopControl(marker),
    );
    runPair(baselineInput, controlledInput);
    return true;
  }
}
