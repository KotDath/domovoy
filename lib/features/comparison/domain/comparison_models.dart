import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';
import 'chat_model_profile.dart';
import 'structural_checklist.dart';
import 'token_cost.dart';

enum ComparisonLaneStatus { idle, streaming, completed, failed }

enum ComparisonRatingKind { correctness, completeness, practicalUsefulness }

@immutable
final class ComparisonEvaluation {
  const ComparisonEvaluation({
    this.correctness,
    this.completeness,
    this.practicalUsefulness,
    this.note = '',
  });

  final int? correctness;
  final int? completeness;
  final int? practicalUsefulness;
  final String note;

  bool get hasAnyScore =>
      correctness != null ||
      completeness != null ||
      practicalUsefulness != null;

  ComparisonEvaluation copyWith({
    int? correctness,
    bool clearCorrectness = false,
    int? completeness,
    bool clearCompleteness = false,
    int? practicalUsefulness,
    bool clearPracticalUsefulness = false,
    String? note,
  }) {
    return ComparisonEvaluation(
      correctness: clearCorrectness ? null : correctness ?? this.correctness,
      completeness: clearCompleteness
          ? null
          : completeness ?? this.completeness,
      practicalUsefulness: clearPracticalUsefulness
          ? null
          : practicalUsefulness ?? this.practicalUsefulness,
      note: note ?? this.note,
    );
  }
}

@immutable
final class ComparisonLaneState {
  const ComparisonLaneState({
    this.profile,
    this.status = ComparisonLaneStatus.idle,
    this.answer = '',
    this.failure,
    this.finishReason,
    this.usage,
    this.timeToFirstToken,
    this.totalDuration,
    this.cost,
    this.checklist,
    this.evaluation = const ComparisonEvaluation(),
  });

  final ChatModelProfile? profile;
  final ComparisonLaneStatus status;
  final String answer;
  final AgentFailure? failure;
  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
  final Duration? timeToFirstToken;
  final Duration? totalDuration;
  final EstimatedCost? cost;
  final StructuralChecklistEvidence? checklist;
  final ComparisonEvaluation evaluation;

  bool get isActive => status == ComparisonLaneStatus.streaming;
  bool get isTerminal =>
      status == ComparisonLaneStatus.completed ||
      status == ComparisonLaneStatus.failed;
  bool get hasOutput => answer.isNotEmpty;

  ComparisonLaneState copyWith({
    ChatModelProfile? profile,
    bool clearProfile = false,
    ComparisonLaneStatus? status,
    String? answer,
    AgentFailure? failure,
    bool clearFailure = false,
    AgentFinishReason? finishReason,
    bool clearFinishReason = false,
    AgentTokenUsage? usage,
    bool clearUsage = false,
    Duration? timeToFirstToken,
    bool clearTimeToFirstToken = false,
    Duration? totalDuration,
    bool clearTotalDuration = false,
    EstimatedCost? cost,
    bool clearCost = false,
    StructuralChecklistEvidence? checklist,
    bool clearChecklist = false,
    ComparisonEvaluation? evaluation,
  }) {
    return ComparisonLaneState(
      profile: clearProfile ? null : profile ?? this.profile,
      status: status ?? this.status,
      answer: answer ?? this.answer,
      failure: clearFailure ? null : failure ?? this.failure,
      finishReason: clearFinishReason
          ? null
          : finishReason ?? this.finishReason,
      usage: clearUsage ? null : usage ?? this.usage,
      timeToFirstToken: clearTimeToFirstToken
          ? null
          : timeToFirstToken ?? this.timeToFirstToken,
      totalDuration: clearTotalDuration
          ? null
          : totalDuration ?? this.totalDuration,
      cost: clearCost ? null : cost ?? this.cost,
      checklist: clearChecklist ? null : checklist ?? this.checklist,
      evaluation: evaluation ?? this.evaluation,
    );
  }
}

@immutable
final class ComparisonExperimentState {
  ComparisonExperimentState({
    this.promptSnapshot = '',
    List<ChatModelProfile>? profiles,
    this.isRunning = false,
    this.completedApiCalls = 0,
    this.activeLaneIndex,
    List<ComparisonLaneState>? lanes,
    this.promptError,
    this.profileError,
    this.conclusion = '',
    this.loadWarning,
  }) : profiles = List<ChatModelProfile>.unmodifiable(
         profiles ?? kDay5PresetProfiles,
       ),
       lanes = List<ComparisonLaneState>.unmodifiable(
         lanes ??
             List<ComparisonLaneState>.generate(
               kComparisonLaneCount,
               (_) => const ComparisonLaneState(),
             ),
       );

  final String promptSnapshot;
  final List<ChatModelProfile> profiles;
  final bool isRunning;
  final int completedApiCalls;
  final int? activeLaneIndex;
  final List<ComparisonLaneState> lanes;
  final String? promptError;
  final String? profileError;
  final String conclusion;
  final String? loadWarning;

  String get costLabel => '$completedApiCalls из $kComparisonPlannedApiCalls';

  ComparisonLaneState laneAt(int index) => lanes[index];

  ChatModelProfile? fastestLaneProfile() {
    ChatModelProfile? fastest;
    Duration? best;
    var comparable = 0;
    for (final lane in lanes) {
      final duration = lane.totalDuration;
      if (duration == null || lane.profile == null) {
        continue;
      }
      comparable++;
      if (best == null || duration < best) {
        best = duration;
        fastest = lane.profile;
      }
    }
    if (comparable != kComparisonLaneCount) {
      return null;
    }
    return fastest;
  }

  ComparisonExperimentState copyWith({
    String? promptSnapshot,
    List<ChatModelProfile>? profiles,
    bool? isRunning,
    int? completedApiCalls,
    int? activeLaneIndex,
    bool clearActiveLaneIndex = false,
    List<ComparisonLaneState>? lanes,
    String? promptError,
    bool clearPromptError = false,
    String? profileError,
    bool clearProfileError = false,
    String? conclusion,
    String? loadWarning,
    bool clearLoadWarning = false,
  }) {
    return ComparisonExperimentState(
      promptSnapshot: promptSnapshot ?? this.promptSnapshot,
      profiles: profiles ?? this.profiles,
      isRunning: isRunning ?? this.isRunning,
      completedApiCalls: completedApiCalls ?? this.completedApiCalls,
      activeLaneIndex: clearActiveLaneIndex
          ? null
          : activeLaneIndex ?? this.activeLaneIndex,
      lanes: lanes ?? this.lanes,
      promptError: clearPromptError ? null : promptError ?? this.promptError,
      profileError: clearProfileError
          ? null
          : profileError ?? this.profileError,
      conclusion: conclusion ?? this.conclusion,
      loadWarning: clearLoadWarning ? null : loadWarning ?? this.loadWarning,
    );
  }
}

String comparisonRatingLabel(int? score) =>
    score == null ? 'Без оценки' : '$score';

String formatDurationMs(Duration? duration) {
  if (duration == null) {
    return 'недоступно';
  }
  return '${duration.inMilliseconds} мс';
}
