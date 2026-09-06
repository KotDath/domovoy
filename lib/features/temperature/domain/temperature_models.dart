import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';
import 'temperature_prompts.dart';

enum TemperatureLaneStatus { idle, streaming, completed, failed }

enum TemperatureRatingKind { accuracy, creativity, diversity }

@immutable
final class TemperatureEvaluation {
  const TemperatureEvaluation({
    this.accuracy,
    this.creativity,
    this.diversity,
    this.note = '',
  });

  final int? accuracy;
  final int? creativity;
  final int? diversity;
  final String note;

  bool get hasAnyScore =>
      accuracy != null || creativity != null || diversity != null;

  TemperatureEvaluation copyWith({
    int? accuracy,
    bool clearAccuracy = false,
    int? creativity,
    bool clearCreativity = false,
    int? diversity,
    bool clearDiversity = false,
    String? note,
  }) {
    return TemperatureEvaluation(
      accuracy: clearAccuracy ? null : accuracy ?? this.accuracy,
      creativity: clearCreativity ? null : creativity ?? this.creativity,
      diversity: clearDiversity ? null : diversity ?? this.diversity,
      note: note ?? this.note,
    );
  }
}

@immutable
final class TemperatureLaneState {
  const TemperatureLaneState({
    this.appliedTemperature,
    this.status = TemperatureLaneStatus.idle,
    this.answer = '',
    this.failure,
    this.finishReason,
    this.usage,
    this.evaluation = const TemperatureEvaluation(),
  });

  final double? appliedTemperature;
  final TemperatureLaneStatus status;
  final String answer;
  final AgentFailure? failure;
  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
  final TemperatureEvaluation evaluation;

  bool get isActive => status == TemperatureLaneStatus.streaming;
  bool get isTerminal =>
      status == TemperatureLaneStatus.completed ||
      status == TemperatureLaneStatus.failed;
  bool get hasOutput => answer.isNotEmpty;

  TemperatureLaneState copyWith({
    double? appliedTemperature,
    bool clearAppliedTemperature = false,
    TemperatureLaneStatus? status,
    String? answer,
    AgentFailure? failure,
    bool clearFailure = false,
    AgentFinishReason? finishReason,
    bool clearFinishReason = false,
    AgentTokenUsage? usage,
    bool clearUsage = false,
    TemperatureEvaluation? evaluation,
  }) {
    return TemperatureLaneState(
      appliedTemperature: clearAppliedTemperature
          ? null
          : appliedTemperature ?? this.appliedTemperature,
      status: status ?? this.status,
      answer: answer ?? this.answer,
      failure: clearFailure ? null : failure ?? this.failure,
      finishReason: clearFinishReason
          ? null
          : finishReason ?? this.finishReason,
      usage: clearUsage ? null : usage ?? this.usage,
      evaluation: evaluation ?? this.evaluation,
    );
  }
}

@immutable
final class TemperatureExperimentState {
  TemperatureExperimentState({
    this.promptSnapshot = '',
    List<double>? temperatures,
    this.isRunning = false,
    this.completedApiCalls = 0,
    this.activeLaneIndex,
    List<TemperatureLaneState>? lanes,
    this.promptError,
    this.temperatureError,
  }) : temperatures = List<double>.unmodifiable(
         temperatures ?? kTemperaturePresetValues,
       ),
       lanes = List<TemperatureLaneState>.unmodifiable(
         lanes ??
             List<TemperatureLaneState>.generate(
               kTemperatureLaneCount,
               (_) => const TemperatureLaneState(),
             ),
       );

  final String promptSnapshot;
  final List<double> temperatures;
  final bool isRunning;
  final int completedApiCalls;
  final int? activeLaneIndex;
  final List<TemperatureLaneState> lanes;
  final String? promptError;
  final String? temperatureError;

  String get costLabel => '$completedApiCalls из $kTemperaturePlannedApiCalls';

  TemperatureLaneState laneAt(int index) => lanes[index];

  TemperatureExperimentState copyWith({
    String? promptSnapshot,
    List<double>? temperatures,
    bool? isRunning,
    int? completedApiCalls,
    int? activeLaneIndex,
    bool clearActiveLaneIndex = false,
    List<TemperatureLaneState>? lanes,
    String? promptError,
    bool clearPromptError = false,
    String? temperatureError,
    bool clearTemperatureError = false,
  }) {
    return TemperatureExperimentState(
      promptSnapshot: promptSnapshot ?? this.promptSnapshot,
      temperatures: temperatures ?? this.temperatures,
      isRunning: isRunning ?? this.isRunning,
      completedApiCalls: completedApiCalls ?? this.completedApiCalls,
      activeLaneIndex: clearActiveLaneIndex
          ? null
          : activeLaneIndex ?? this.activeLaneIndex,
      lanes: lanes ?? this.lanes,
      promptError: clearPromptError ? null : promptError ?? this.promptError,
      temperatureError: clearTemperatureError
          ? null
          : temperatureError ?? this.temperatureError,
    );
  }
}

String temperatureRatingLabel(int? score) =>
    score == null ? 'Без оценки' : '$score';
