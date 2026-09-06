import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';

enum ReasoningStrategy { direct, stepByStep, generatedPrompt, expertGroup }

enum ReasoningStage {
  direct,
  stepByStep,
  promptBuilder,
  generatedSolver,
  expertGroup,
}

enum ReasoningVerdict { unrated, correct, partial, incorrect }

enum ReasoningLaneStatus { idle, streaming, completed, failed }

const int kReasoningPlannedApiCalls = 5;

String reasoningStrategyLabel(ReasoningStrategy strategy) => switch (strategy) {
  ReasoningStrategy.direct => 'Прямой ответ',
  ReasoningStrategy.stepByStep => 'По шагам',
  ReasoningStrategy.generatedPrompt => 'Сгенерированный промпт',
  ReasoningStrategy.expertGroup => 'Группа экспертов',
};

String reasoningStrategyTransformation(
  ReasoningStrategy strategy,
) => switch (strategy) {
  ReasoningStrategy.direct =>
    'Задача без дополнительной инструкции о способе рассуждения.',
  ReasoningStrategy.stepByStep =>
    'Та же задача плюс явная инструкция решать по шагам и проверить вывод.',
  ReasoningStrategy.generatedPrompt =>
    'Сначала модель пишет самодостаточный промпт-решатель, затем отдельный запрос выполняет его вместе с исходной задачей.',
  ReasoningStrategy.expertGroup =>
    'Аналитик, инженер и критик дают отдельно подписанные решения, затем следует согласующий синтез.',
};

int reasoningStrategyPlannedCalls(ReasoningStrategy strategy) =>
    switch (strategy) {
      ReasoningStrategy.generatedPrompt => 2,
      ReasoningStrategy.direct ||
      ReasoningStrategy.stepByStep ||
      ReasoningStrategy.expertGroup => 1,
    };

String reasoningStrategyCostLabel(ReasoningStrategy strategy) {
  final count = reasoningStrategyPlannedCalls(strategy);
  return count == 1 ? '1 API-вызов' : '$count API-вызова';
}

String reasoningVerdictLabel(ReasoningVerdict verdict) => switch (verdict) {
  ReasoningVerdict.unrated => 'Без оценки',
  ReasoningVerdict.correct => 'Точно',
  ReasoningVerdict.partial => 'Частично',
  ReasoningVerdict.incorrect => 'Неверно',
};

@immutable
final class ReasoningLaneState {
  const ReasoningLaneState({
    this.status = ReasoningLaneStatus.idle,
    this.answer = '',
    this.failure,
    this.finishReason,
    this.usage,
    this.verdict = ReasoningVerdict.unrated,
  });

  final ReasoningLaneStatus status;
  final String answer;
  final AgentFailure? failure;
  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
  final ReasoningVerdict verdict;

  bool get isActive => status == ReasoningLaneStatus.streaming;
  bool get isTerminal =>
      status == ReasoningLaneStatus.completed ||
      status == ReasoningLaneStatus.failed;
  bool get hasOutput => answer.isNotEmpty;

  ReasoningLaneState copyWith({
    ReasoningLaneStatus? status,
    String? answer,
    AgentFailure? failure,
    bool clearFailure = false,
    AgentFinishReason? finishReason,
    bool clearFinishReason = false,
    AgentTokenUsage? usage,
    bool clearUsage = false,
    ReasoningVerdict? verdict,
  }) {
    return ReasoningLaneState(
      status: status ?? this.status,
      answer: answer ?? this.answer,
      failure: clearFailure ? null : failure ?? this.failure,
      finishReason: clearFinishReason
          ? null
          : finishReason ?? this.finishReason,
      usage: clearUsage ? null : usage ?? this.usage,
      verdict: verdict ?? this.verdict,
    );
  }
}

@immutable
final class ReasoningExperimentState {
  const ReasoningExperimentState({
    this.taskSnapshot = '',
    this.isRunning = false,
    this.completedApiCalls = 0,
    this.activeStage,
    this.direct = const ReasoningLaneState(),
    this.stepByStep = const ReasoningLaneState(),
    this.promptBuilder = const ReasoningLaneState(),
    this.generated = const ReasoningLaneState(),
    this.expertGroup = const ReasoningLaneState(),
    this.mostAccurate,
    this.taskError,
  });

  final String taskSnapshot;
  final bool isRunning;
  final int completedApiCalls;
  final ReasoningStage? activeStage;
  final ReasoningLaneState direct;
  final ReasoningLaneState stepByStep;
  final ReasoningLaneState promptBuilder;
  final ReasoningLaneState generated;
  final ReasoningLaneState expertGroup;
  final ReasoningStrategy? mostAccurate;
  final String? taskError;

  String get generatedPrompt => promptBuilder.answer;

  String get costLabel => '$completedApiCalls из $kReasoningPlannedApiCalls';

  ReasoningLaneState laneFor(ReasoningStrategy strategy) => switch (strategy) {
    ReasoningStrategy.direct => direct,
    ReasoningStrategy.stepByStep => stepByStep,
    ReasoningStrategy.generatedPrompt => generated,
    ReasoningStrategy.expertGroup => expertGroup,
  };

  ReasoningLaneStatus get generatedStrategyStatus {
    if (generated.status != ReasoningLaneStatus.idle) {
      return generated.status;
    }
    return promptBuilder.status;
  }

  ReasoningExperimentState copyWith({
    String? taskSnapshot,
    bool? isRunning,
    int? completedApiCalls,
    ReasoningStage? activeStage,
    bool clearActiveStage = false,
    ReasoningLaneState? direct,
    ReasoningLaneState? stepByStep,
    ReasoningLaneState? promptBuilder,
    ReasoningLaneState? generated,
    ReasoningLaneState? expertGroup,
    ReasoningStrategy? mostAccurate,
    bool clearMostAccurate = false,
    String? taskError,
    bool clearTaskError = false,
  }) {
    return ReasoningExperimentState(
      taskSnapshot: taskSnapshot ?? this.taskSnapshot,
      isRunning: isRunning ?? this.isRunning,
      completedApiCalls: completedApiCalls ?? this.completedApiCalls,
      activeStage: clearActiveStage ? null : activeStage ?? this.activeStage,
      direct: direct ?? this.direct,
      stepByStep: stepByStep ?? this.stepByStep,
      promptBuilder: promptBuilder ?? this.promptBuilder,
      generated: generated ?? this.generated,
      expertGroup: expertGroup ?? this.expertGroup,
      mostAccurate: clearMostAccurate
          ? null
          : mostAccurate ?? this.mostAccurate,
      taskError: clearTaskError ? null : taskError ?? this.taskError,
    );
  }
}
