import '../../prompt/domain/agent.dart';

const String kTemperatureStarterPrompt =
    'Объясни десятилетнему ребёнку, почему небо кажется голубым. '
    'Сохрани научную точность, используй одну запоминающуюся метафору '
    'и уложись в 120 слов.';

const List<double> kTemperaturePresetValues = <double>[0.0, 0.7, 1.2];

const int kTemperatureLaneCount = 3;

const int kTemperaturePlannedApiCalls = 3;

const double kTemperatureMin = 0.0;

const double kTemperatureMax = 2.0;

const int kTemperatureSliderDivisions = 20;

double quantizeTemperature(double value) {
  final clamped = value.clamp(kTemperatureMin, kTemperatureMax);
  return (clamped * 10).round() / 10;
}

String temperatureValueLabel(double value) =>
    quantizeTemperature(value).toStringAsFixed(1);

AgentInput buildTemperatureLaneInput({
  required String prompt,
  required double temperature,
}) {
  return AgentInput(
    prompt,
    thinking: ThinkingMode.disabled,
    temperature: temperature,
  );
}
