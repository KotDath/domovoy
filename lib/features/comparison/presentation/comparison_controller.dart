import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';
import '../data/profile_agent_factory.dart';
import '../domain/chat_model_profile.dart';
import '../domain/comparison_models.dart';
import '../domain/comparison_prompts.dart';
import '../domain/elapsed_timer.dart';
import '../domain/profile_validation.dart';
import '../domain/structural_checklist.dart';
import '../domain/token_cost.dart';

final class ComparisonController extends ChangeNotifier {
  ComparisonController({
    required ComparisonAgentFactory agentFactory,
    ElapsedClockFactory clockFactory = StopwatchElapsedClock.new,
  }) : _agentFactory = agentFactory,
       _clockFactory = clockFactory;

  final ComparisonAgentFactory _agentFactory;
  final ElapsedClockFactory _clockFactory;

  ComparisonExperimentState _state = ComparisonExperimentState();
  StreamSubscription<AgentEvent>? _subscription;
  Completer<void>? _laneGate;
  bool _disposed = false;
  int _generation = 0;

  ComparisonExperimentState get state => _state;
  bool get isRunning => _state.isRunning;
  int get completedApiCalls => _state.completedApiCalls;
  bool get isControllerDisposed => _disposed;

  void setLoadWarning(String? warning) {
    if (_disposed) {
      return;
    }
    _state = _state.copyWith(
      loadWarning: warning,
      clearLoadWarning: warning == null,
    );
    _notify();
  }

  void setConfiguredProfiles(List<ChatModelProfile> profiles) {
    if (_disposed || _state.isRunning) {
      return;
    }
    _state = _state.copyWith(profiles: profiles, clearProfileError: true);
    _notify();
  }

  bool runComparison({
    required String rawPrompt,
    required List<ChatModelProfile> profiles,
  }) {
    if (_runningLocked) {
      return false;
    }
    final prompt = rawPrompt.trim();
    if (prompt.isEmpty) {
      _state = _state.copyWith(promptError: 'Введите запрос.');
      _notify();
      return false;
    }
    if (profiles.length != kComparisonLaneCount) {
      _state = _state.copyWith(
        clearPromptError: true,
        profileError: 'Сравнение требует ровно три профиля.',
      );
      _notify();
      return false;
    }
    for (final profile in profiles) {
      final error = validateChatModelProfile(profile);
      if (error != null) {
        _state = _state.copyWith(clearPromptError: true, profileError: error);
        _notify();
        return false;
      }
    }
    unawaited(_cancelActiveLane());
    final generation = ++_generation;
    final snapshots = List<ChatModelProfile>.unmodifiable(profiles);
    _state = ComparisonExperimentState(
      promptSnapshot: prompt,
      profiles: snapshots,
      isRunning: true,
      loadWarning: _state.loadWarning,
    );
    _notify();
    unawaited(_runLanes(generation, prompt, snapshots));
    return true;
  }

  void setRating({
    required int laneIndex,
    required ComparisonRatingKind kind,
    required int? value,
  }) {
    if (_disposed) {
      return;
    }
    if (laneIndex < 0 || laneIndex >= _state.lanes.length) {
      return;
    }
    final lane = _state.laneAt(laneIndex);
    if (!lane.isTerminal) {
      return;
    }
    if (value != null && (value < 1 || value > 5)) {
      return;
    }
    final evaluation = switch (kind) {
      ComparisonRatingKind.correctness => lane.evaluation.copyWith(
        correctness: value,
        clearCorrectness: value == null,
      ),
      ComparisonRatingKind.completeness => lane.evaluation.copyWith(
        completeness: value,
        clearCompleteness: value == null,
      ),
      ComparisonRatingKind.practicalUsefulness => lane.evaluation.copyWith(
        practicalUsefulness: value,
        clearPracticalUsefulness: value == null,
      ),
    };
    _state = _replaceLane(laneIndex, lane.copyWith(evaluation: evaluation));
    _notify();
  }

  void setNote({required int laneIndex, required String note}) {
    if (_disposed) {
      return;
    }
    if (laneIndex < 0 || laneIndex >= _state.lanes.length) {
      return;
    }
    final lane = _state.laneAt(laneIndex);
    if (!lane.isTerminal) {
      return;
    }
    _state = _replaceLane(
      laneIndex,
      lane.copyWith(evaluation: lane.evaluation.copyWith(note: note)),
    );
    _notify();
  }

  void setConclusion(String text) {
    if (_disposed) {
      return;
    }
    _state = _state.copyWith(conclusion: text);
    _notify();
  }

  bool get _runningLocked => _state.isRunning || _disposed;

  Future<void> _runLanes(
    int generation,
    String prompt,
    List<ChatModelProfile> profiles,
  ) async {
    for (var index = 0; index < profiles.length; index++) {
      if (_isStale(generation)) {
        return;
      }
      await _runLane(generation, index, profiles[index], prompt);
    }
    if (_isStale(generation)) {
      return;
    }
    _state = _state.copyWith(isRunning: false, clearActiveLaneIndex: true);
    _notify();
  }

  Future<void> _runLane(
    int generation,
    int index,
    ChatModelProfile profile,
    String prompt,
  ) {
    if (_isStale(generation)) {
      return Future.value();
    }
    _state = _replaceLane(
      index,
      ComparisonLaneState(
        profile: profile,
        status: ComparisonLaneStatus.streaming,
      ),
    ).copyWith(activeLaneIndex: index);
    _notify();
    return _collectLane(
      generation,
      index,
      profile,
      buildComparisonLaneInput(prompt),
    );
  }

  Future<void> _collectLane(
    int generation,
    int index,
    ChatModelProfile profile,
    AgentInput input,
  ) {
    final gate = Completer<void>();
    _laneGate = gate;
    void finish() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }

    var laneOpen = true;
    final clock = _clockFactory();
    try {
      final agent = _agentFactory(profile);
      _subscription = agent
          .prompt(input)
          .listen(
            (event) {
              if (_isStale(generation) || !laneOpen) {
                return;
              }
              _applyEvent(index, event, clock);
              if (_state.laneAt(index).isTerminal) {
                laneOpen = false;
                unawaited(_cancelActiveLane());
                finish();
              }
            },
            onError: (_) {
              if (_isStale(generation) || !laneOpen) {
                finish();
                return;
              }
              laneOpen = false;
              _applyInterruption(index, clock);
              unawaited(_cancelActiveLane());
              finish();
            },
            onDone: () {
              if (_isStale(generation) || !laneOpen) {
                finish();
                return;
              }
              laneOpen = false;
              if (_state.laneAt(index).status ==
                  ComparisonLaneStatus.streaming) {
                _applyInterruption(index, clock);
              }
              finish();
            },
            cancelOnError: false,
          );
    } on Object {
      unawaited(_cancelActiveLane());
      if (!_isStale(generation) && laneOpen) {
        laneOpen = false;
        _applyInterruption(index, clock);
      }
      finish();
    }
    return gate.future;
  }

  void _applyEvent(int index, AgentEvent event, ElapsedClock clock) {
    var lane = _state.laneAt(index);
    if (lane.isTerminal) {
      return;
    }
    switch (event) {
      case AgentReasoningDelta():
        return;
      case AgentAnswerDelta(:final text):
        if (text.isNotEmpty && lane.timeToFirstToken == null) {
          lane = lane.copyWith(timeToFirstToken: clock.elapsed());
        }
        lane = lane.copyWith(answer: '${lane.answer}$text');
      case AgentCompleted(:final finishReason, :final usage):
        lane = _completeLane(
          lane,
          clock: clock,
          finishReason: finishReason,
          usage: usage,
        );
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
      case AgentFailed(:final failure):
        lane = _failLane(lane, clock: clock, failure: failure);
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
    }
    _state = _replaceLane(index, lane);
    _notify();
  }

  void _applyInterruption(int index, ElapsedClock clock) {
    var lane = _state.laneAt(index);
    if (lane.status != ComparisonLaneStatus.streaming) {
      return;
    }
    lane = _failLane(
      lane,
      clock: clock,
      failure: const AgentFailure(
        kind: AgentFailureKind.interrupted,
        message: 'Поток ответа завершился неожиданно.',
      ),
    );
    _state = _replaceLane(
      index,
      lane,
    ).copyWith(completedApiCalls: _state.completedApiCalls + 1);
    _notify();
  }

  ComparisonLaneState _completeLane(
    ComparisonLaneState lane, {
    required ElapsedClock clock,
    required AgentFinishReason? finishReason,
    required AgentTokenUsage? usage,
  }) {
    final checklist = lane.answer.isNotEmpty
        ? evaluateStructuralChecklist(lane.answer)
        : null;
    return lane.copyWith(
      status: ComparisonLaneStatus.completed,
      clearFailure: true,
      finishReason: finishReason,
      usage: usage,
      totalDuration: lane.totalDuration ?? clock.elapsed(),
      cost: estimateProviderCost(pricing: lane.profile?.pricing, usage: usage),
      checklist: checklist,
    );
  }

  ComparisonLaneState _failLane(
    ComparisonLaneState lane, {
    required ElapsedClock clock,
    required AgentFailure failure,
  }) {
    return lane.copyWith(
      status: ComparisonLaneStatus.failed,
      failure: failure,
      totalDuration: lane.totalDuration ?? clock.elapsed(),
      cost: estimateProviderCost(
        pricing: lane.profile?.pricing,
        usage: lane.usage,
      ),
    );
  }

  ComparisonExperimentState _replaceLane(int index, ComparisonLaneState lane) {
    final lanes = [..._state.lanes];
    lanes[index] = lane;
    return _state.copyWith(lanes: lanes);
  }

  bool _isStale(int generation) => _disposed || generation != _generation;

  Future<void> _cancelActiveLane() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_cancelActiveLane());
    final gate = _laneGate;
    _laneGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
    super.dispose();
  }
}
