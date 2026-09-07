import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';
import '../domain/reasoning_models.dart';
import '../domain/reasoning_prompts.dart';

final class ReasoningController extends ChangeNotifier {
  ReasoningController(this.agent);

  final Agent agent;

  ReasoningExperimentState _state = const ReasoningExperimentState();
  StreamSubscription<AgentEvent>? _subscription;
  Completer<void>? _laneGate;
  bool _disposed = false;
  int _generation = 0;

  ReasoningExperimentState get state => _state;
  bool get isRunning => _state.isRunning;
  int get completedApiCalls => _state.completedApiCalls;
  bool get isControllerDisposed => _disposed;

  bool runComparison(String rawTask) {
    if (_runningLocked) {
      return false;
    }
    final task = rawTask.trim();
    if (task.isEmpty) {
      _state = _state.copyWith(taskError: 'Введите задачу.');
      _notify();
      return false;
    }
    unawaited(_cancelActiveLane());
    final generation = ++_generation;
    _state = ReasoningExperimentState(taskSnapshot: task, isRunning: true);
    _notify();
    unawaited(_runStages(generation, task));
    return true;
  }

  bool get _runningLocked => _state.isRunning || _disposed;

  Future<void> _runStages(int generation, String task) async {
    await _runStage(generation, ReasoningStage.direct, buildDirectInput(task));
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.stepByStep,
      buildStepByStepInput(task),
    );
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.promptBuilder,
      buildPromptBuilderInput(task),
    );
    if (_isStale(generation)) {
      return;
    }
    final generatedPrompt = _state.promptBuilder.answer.trim();
    if (_state.promptBuilder.status == ReasoningLaneStatus.completed &&
        generatedPrompt.isNotEmpty) {
      await _runStage(
        generation,
        ReasoningStage.generatedSolver,
        buildGeneratedSolverInput(
          generatedInstructions: generatedPrompt,
          originalTask: task,
        ),
      );
    } else {
      _skipGeneratedSolver();
    }
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.expertAnalyst,
      buildExpertInput(task, ReasoningExpertRole.analyst),
    );
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.expertEngineer,
      buildExpertInput(task, ReasoningExpertRole.engineer),
    );
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.expertCritic,
      buildExpertInput(task, ReasoningExpertRole.critic),
    );
    if (_isStale(generation)) {
      return;
    }
    await _runStage(
      generation,
      ReasoningStage.expertSynthesis,
      buildExpertSynthesisInput(
        task: task,
        analystEvidence: _expertEvidence(_state.expertAnalyst),
        engineerEvidence: _expertEvidence(_state.expertEngineer),
        criticEvidence: _expertEvidence(_state.expertCritic),
      ),
    );
    if (_isStale(generation)) {
      return;
    }
    _state = _state.copyWith(isRunning: false, clearActiveStage: true);
    _notify();
  }

  Future<void> _runStage(
    int generation,
    ReasoningStage stage,
    AgentInput input,
  ) {
    if (_isStale(generation)) {
      return Future.value();
    }
    _state = _withLane(
      stage,
      const ReasoningLaneState(status: ReasoningLaneStatus.streaming),
    ).copyWith(activeStage: stage);
    _notify();
    return _collectStage(generation, stage, input);
  }

  Future<void> _collectStage(
    int generation,
    ReasoningStage stage,
    AgentInput input,
  ) {
    final gate = Completer<void>();
    _laneGate = gate;
    void finish() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }

    try {
      _subscription = agent
          .prompt(input)
          .listen(
            (event) {
              if (_isStale(generation)) {
                return;
              }
              _applyEvent(stage, event);
              if (_laneOf(stage).isTerminal) {
                unawaited(_cancelActiveLane());
                finish();
              }
            },
            onError: (_) {
              if (_isStale(generation)) {
                finish();
                return;
              }
              _applyInterruption(stage);
              unawaited(_cancelActiveLane());
              finish();
            },
            onDone: () {
              if (_isStale(generation)) {
                finish();
                return;
              }
              if (_laneOf(stage).status == ReasoningLaneStatus.streaming) {
                _applyInterruption(stage);
              }
              finish();
            },
            cancelOnError: false,
          );
    } on Object {
      unawaited(_cancelActiveLane());
      if (!_isStale(generation)) {
        _applyInterruption(stage);
      }
      finish();
    }
    return gate.future;
  }

  void _applyEvent(ReasoningStage stage, AgentEvent event) {
    var lane = _laneOf(stage);
    switch (event) {
      case AgentReasoningDelta():
        return;
      case AgentAnswerDelta(:final text):
        lane = lane.copyWith(answer: '${lane.answer}$text');
      case AgentCompleted(:final finishReason, :final usage):
        lane = lane.copyWith(
          status: ReasoningLaneStatus.completed,
          clearFailure: true,
          finishReason: finishReason,
          usage: usage,
        );
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
      case AgentFailed(:final failure):
        lane = lane.copyWith(
          status: ReasoningLaneStatus.failed,
          failure: failure,
        );
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
    }
    _state = _withLane(stage, lane);
    _notify();
  }

  void _applyInterruption(ReasoningStage stage) {
    var lane = _laneOf(stage);
    if (lane.status != ReasoningLaneStatus.streaming) {
      return;
    }
    lane = lane.copyWith(
      status: ReasoningLaneStatus.failed,
      failure: const AgentFailure(
        kind: AgentFailureKind.interrupted,
        message: 'Поток ответа завершился неожиданно.',
      ),
    );
    _state = _withLane(
      stage,
      lane,
    ).copyWith(completedApiCalls: _state.completedApiCalls + 1);
    _notify();
  }

  void _skipGeneratedSolver() {
    final failure =
        _state.promptBuilder.failure ??
        const AgentFailure(
          kind: AgentFailureKind.unknown,
          message: 'Сгенерированный промпт пуст; этап решателя пропущен.',
        );
    _state = _state.copyWith(
      generated: _state.generated.copyWith(
        status: ReasoningLaneStatus.failed,
        failure: failure,
      ),
    );
    _notify();
  }

  String _expertEvidence(ReasoningLaneState lane) {
    final answer = lane.answer.trim();
    final failure = lane.failure?.message.trim();
    if (answer.isEmpty) {
      return failure == null || failure.isEmpty
          ? '[Ответ недоступен]'
          : '[Ответ недоступен. Ошибка: $failure]';
    }
    if (failure == null || failure.isEmpty) {
      return answer;
    }
    return '$answer\n[Запрос завершился ошибкой: $failure]';
  }

  void setVerdict(ReasoningStrategy strategy, ReasoningVerdict verdict) {
    if (_disposed) {
      return;
    }
    final lane = _state.laneFor(strategy);
    if (!lane.isTerminal) {
      return;
    }
    _state = _replaceStrategyLane(strategy, lane.copyWith(verdict: verdict));
    _notify();
  }

  void setMostAccurate(ReasoningStrategy? strategy) {
    if (_disposed) {
      return;
    }
    if (strategy != null && !_state.laneFor(strategy).isTerminal) {
      return;
    }
    _state = strategy == null
        ? _state.copyWith(clearMostAccurate: true)
        : _state.copyWith(mostAccurate: strategy);
    _notify();
  }

  ReasoningLaneState _laneOf(ReasoningStage stage) => switch (stage) {
    ReasoningStage.direct => _state.direct,
    ReasoningStage.stepByStep => _state.stepByStep,
    ReasoningStage.promptBuilder => _state.promptBuilder,
    ReasoningStage.generatedSolver => _state.generated,
    ReasoningStage.expertAnalyst => _state.expertAnalyst,
    ReasoningStage.expertEngineer => _state.expertEngineer,
    ReasoningStage.expertCritic => _state.expertCritic,
    ReasoningStage.expertSynthesis => _state.expertGroup,
  };

  ReasoningExperimentState _withLane(
    ReasoningStage stage,
    ReasoningLaneState lane,
  ) {
    return switch (stage) {
      ReasoningStage.direct => _state.copyWith(direct: lane),
      ReasoningStage.stepByStep => _state.copyWith(stepByStep: lane),
      ReasoningStage.promptBuilder => _state.copyWith(promptBuilder: lane),
      ReasoningStage.generatedSolver => _state.copyWith(generated: lane),
      ReasoningStage.expertAnalyst => _state.copyWith(expertAnalyst: lane),
      ReasoningStage.expertEngineer => _state.copyWith(expertEngineer: lane),
      ReasoningStage.expertCritic => _state.copyWith(expertCritic: lane),
      ReasoningStage.expertSynthesis => _state.copyWith(expertGroup: lane),
    };
  }

  ReasoningExperimentState _replaceStrategyLane(
    ReasoningStrategy strategy,
    ReasoningLaneState lane,
  ) {
    return switch (strategy) {
      ReasoningStrategy.direct => _state.copyWith(direct: lane),
      ReasoningStrategy.stepByStep => _state.copyWith(stepByStep: lane),
      ReasoningStrategy.generatedPrompt => _state.copyWith(generated: lane),
      ReasoningStrategy.expertGroup => _state.copyWith(expertGroup: lane),
    };
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
