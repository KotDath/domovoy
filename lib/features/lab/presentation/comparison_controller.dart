import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';

enum ExperimentLaneStatus { idle, streaming, completed, failed }

@immutable
final class ExperimentLaneState {
  const ExperimentLaneState({
    this.status = ExperimentLaneStatus.idle,
    this.reasoning = '',
    this.answer = '',
    this.failure,
    this.finishReason,
    this.usage,
    this.reasoningExpanded = false,
  });

  final ExperimentLaneStatus status;
  final String reasoning;
  final String answer;
  final AgentFailure? failure;
  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
  final bool reasoningExpanded;

  bool get isActive => status == ExperimentLaneStatus.streaming;
  bool get isTerminal =>
      status == ExperimentLaneStatus.completed ||
      status == ExperimentLaneStatus.failed;
  bool get hasOutput => reasoning.isNotEmpty || answer.isNotEmpty;

  /// Visible character count in grapheme clusters (user-perceived characters).
  int get charCount => answer.characters.length;

  ExperimentLaneState copyWith({
    ExperimentLaneStatus? status,
    String? reasoning,
    String? answer,
    AgentFailure? failure,
    bool clearFailure = false,
    AgentFinishReason? finishReason,
    AgentTokenUsage? usage,
    bool? reasoningExpanded,
  }) {
    return ExperimentLaneState(
      status: status ?? this.status,
      reasoning: reasoning ?? this.reasoning,
      answer: answer ?? this.answer,
      failure: clearFailure ? null : failure ?? this.failure,
      finishReason: finishReason ?? this.finishReason,
      usage: usage ?? this.usage,
      reasoningExpanded: reasoningExpanded ?? this.reasoningExpanded,
    );
  }
}

abstract class BaselineControlledController extends ChangeNotifier {
  BaselineControlledController(this.agent);

  final Agent agent;

  ExperimentLaneState _baseline = const ExperimentLaneState();
  ExperimentLaneState _controlled = const ExperimentLaneState();

  ExperimentLaneState get baseline => _baseline;
  ExperimentLaneState get controlled => _controlled;

  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  int _completedCalls = 0;
  StreamSubscription<AgentEvent>? _subscription;
  Completer<void>? _laneGate;

  bool get isRunning => _running;
  int get completedApiCalls => _completedCalls;

  @protected
  bool get isControllerDisposed => _disposed;

  String get costLabel => '$_completedCalls из 2 API-вызовов';

  void toggleBaselineReasoning() {
    if (_baseline.reasoning.isEmpty) {
      return;
    }
    _baseline = _baseline.copyWith(
      reasoningExpanded: !_baseline.reasoningExpanded,
    );
    _notify();
  }

  void toggleControlledReasoning() {
    if (_controlled.reasoning.isEmpty) {
      return;
    }
    _controlled = _controlled.copyWith(
      reasoningExpanded: !_controlled.reasoningExpanded,
    );
    _notify();
  }

  void refresh() => _notify();

  @protected
  Future<bool> runPair(AgentInput baselineInput, AgentInput controlledInput) {
    if (_running || _disposed) {
      return Future.value(false);
    }
    unawaited(_cancelActiveLane());
    final generation = ++_generation;
    _running = true;
    _completedCalls = 0;
    _baseline = const ExperimentLaneState(
      status: ExperimentLaneStatus.streaming,
    );
    _controlled = const ExperimentLaneState();
    _notify();
    unawaited(
      _runBaselineThenControlled(generation, baselineInput, controlledInput),
    );
    return Future.value(true);
  }

  Future<void> _runBaselineThenControlled(
    int generation,
    AgentInput baselineInput,
    AgentInput controlledInput,
  ) async {
    await _collectLane(generation, baselineInput, isBaseline: true);
    if (_disposed || generation != _generation) {
      return;
    }
    _controlled = const ExperimentLaneState(
      status: ExperimentLaneStatus.streaming,
    );
    _notify();
    await _collectLane(generation, controlledInput, isBaseline: false);
    if (_disposed || generation != _generation) {
      return;
    }
    _running = false;
    _notify();
  }

  Future<void> _collectLane(
    int generation,
    AgentInput input, {
    required bool isBaseline,
  }) {
    final gate = Completer<void>();
    _laneGate = gate;
    void finish() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }

    _subscription = agent
        .prompt(input)
        .listen(
          (event) {
            if (_disposed || generation != _generation) {
              return;
            }
            _applyEvent(isBaseline, event);
            if (_laneOf(isBaseline).isTerminal) {
              unawaited(_cancelActiveLane());
              finish();
            }
          },
          onError: (_) {
            if (_disposed || generation != _generation) {
              finish();
              return;
            }
            _applyInterruption(isBaseline);
            unawaited(_cancelActiveLane());
            finish();
          },
          onDone: () {
            if (_disposed || generation != _generation) {
              finish();
              return;
            }
            if (_laneOf(isBaseline).status == ExperimentLaneStatus.streaming) {
              _applyInterruption(isBaseline);
            }
            finish();
          },
          cancelOnError: false,
        );
    return gate.future;
  }

  ExperimentLaneState _laneOf(bool isBaseline) =>
      isBaseline ? _baseline : _controlled;

  Future<void> _cancelActiveLane() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  void _applyEvent(bool isBaseline, AgentEvent event) {
    var lane = isBaseline ? _baseline : _controlled;
    switch (event) {
      case AgentReasoningDelta(:final text):
        lane = lane.copyWith(
          reasoning: '${lane.reasoning}$text',
          reasoningExpanded: lane.reasoning.isEmpty
              ? true
              : lane.reasoningExpanded,
        );
      case AgentAnswerDelta(:final text):
        lane = lane.copyWith(answer: '${lane.answer}$text');
      case AgentCompleted(:final finishReason, :final usage):
        lane = lane.copyWith(
          status: ExperimentLaneStatus.completed,
          clearFailure: true,
          finishReason: finishReason,
          usage: usage,
        );
        _completedCalls++;
        onLaneTerminal(isBaseline, lane);
      case AgentFailed(:final failure):
        lane = lane.copyWith(
          status: ExperimentLaneStatus.failed,
          failure: failure,
        );
        _completedCalls++;
        onLaneTerminal(isBaseline, lane);
    }
    if (isBaseline) {
      _baseline = lane;
    } else {
      _controlled = lane;
    }
    _notify();
  }

  void _applyInterruption(bool isBaseline) {
    var lane = isBaseline ? _baseline : _controlled;
    if (lane.status != ExperimentLaneStatus.streaming) {
      return;
    }
    lane = lane.copyWith(
      status: ExperimentLaneStatus.failed,
      failure: const AgentFailure(
        kind: AgentFailureKind.interrupted,
        message: 'Поток ответа завершился неожиданно.',
      ),
    );
    _completedCalls++;
    onLaneTerminal(isBaseline, lane);
    if (isBaseline) {
      _baseline = lane;
    } else {
      _controlled = lane;
    }
    _notify();
  }

  @protected
  void onLaneTerminal(bool isBaseline, ExperimentLaneState lane) {}

  @protected
  void setBaseline(ExperimentLaneState value) {
    _baseline = value;
    _notify();
  }

  @protected
  void setControlled(ExperimentLaneState value) {
    _controlled = value;
    _notify();
  }

  @protected
  void markRepairCall() {
    _completedCalls++;
    _notify();
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
