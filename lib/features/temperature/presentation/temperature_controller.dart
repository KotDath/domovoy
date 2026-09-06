import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../prompt/domain/agent.dart';
import '../domain/temperature_models.dart';
import '../domain/temperature_prompts.dart';

final class TemperatureController extends ChangeNotifier {
  TemperatureController(this.agent);

  final Agent agent;

  TemperatureExperimentState _state = TemperatureExperimentState();
  StreamSubscription<AgentEvent>? _subscription;
  Completer<void>? _laneGate;
  bool _disposed = false;
  int _generation = 0;

  TemperatureExperimentState get state => _state;
  bool get isRunning => _state.isRunning;
  int get completedApiCalls => _state.completedApiCalls;
  bool get isControllerDisposed => _disposed;

  bool runComparison({
    required String rawPrompt,
    required List<double> temperatures,
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
    if (temperatures.length != kTemperatureLaneCount) {
      _state = _state.copyWith(
        clearPromptError: true,
        temperatureError: 'Сравнение требует ровно три значения температуры.',
      );
      _notify();
      return false;
    }
    final snapshotTemps = [
      for (final value in temperatures) quantizeTemperature(value),
    ];
    if (snapshotTemps.toSet().length != snapshotTemps.length) {
      _state = _state.copyWith(
        clearPromptError: true,
        temperatureError:
            'Значения температуры для сравнения должны различаться.',
      );
      _notify();
      return false;
    }
    unawaited(_cancelActiveLane());
    final generation = ++_generation;
    _state = TemperatureExperimentState(
      promptSnapshot: prompt,
      temperatures: snapshotTemps,
      isRunning: true,
    );
    _notify();
    unawaited(_runLanes(generation, prompt, snapshotTemps));
    return true;
  }

  bool get _runningLocked => _state.isRunning || _disposed;

  Future<void> _runLanes(
    int generation,
    String prompt,
    List<double> temperatures,
  ) async {
    for (var index = 0; index < temperatures.length; index++) {
      if (_isStale(generation)) {
        return;
      }
      await _runLane(
        generation,
        index,
        buildTemperatureLaneInput(
          prompt: prompt,
          temperature: temperatures[index],
        ),
      );
    }
    if (_isStale(generation)) {
      return;
    }
    _state = _state.copyWith(isRunning: false, clearActiveLaneIndex: true);
    _notify();
  }

  Future<void> _runLane(int generation, int index, AgentInput input) {
    if (_isStale(generation)) {
      return Future.value();
    }
    _state = _replaceLane(
      index,
      TemperatureLaneState(
        appliedTemperature: input.temperature,
        status: TemperatureLaneStatus.streaming,
      ),
    ).copyWith(activeLaneIndex: index);
    _notify();
    return _collectLane(generation, index, input);
  }

  Future<void> _collectLane(int generation, int index, AgentInput input) {
    final gate = Completer<void>();
    _laneGate = gate;
    void finish() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }

    var laneOpen = true;
    try {
      _subscription = agent
          .prompt(input)
          .listen(
            (event) {
              if (_isStale(generation) || !laneOpen) {
                return;
              }
              _applyEvent(index, event);
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
              _applyInterruption(index);
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
                  TemperatureLaneStatus.streaming) {
                _applyInterruption(index);
              }
              finish();
            },
            cancelOnError: false,
          );
    } on Object {
      unawaited(_cancelActiveLane());
      if (!_isStale(generation)) {
        _applyInterruption(index);
      }
      finish();
    }
    return gate.future;
  }

  void _applyEvent(int index, AgentEvent event) {
    var lane = _state.laneAt(index);
    if (lane.isTerminal) {
      return;
    }
    switch (event) {
      case AgentReasoningDelta():
        return;
      case AgentAnswerDelta(:final text):
        lane = lane.copyWith(answer: '${lane.answer}$text');
      case AgentCompleted(:final finishReason, :final usage):
        lane = lane.copyWith(
          status: TemperatureLaneStatus.completed,
          clearFailure: true,
          finishReason: finishReason,
          usage: usage,
        );
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
      case AgentFailed(:final failure):
        lane = lane.copyWith(
          status: TemperatureLaneStatus.failed,
          failure: failure,
        );
        _state = _state.copyWith(
          completedApiCalls: _state.completedApiCalls + 1,
        );
    }
    _state = _replaceLane(index, lane);
    _notify();
  }

  void _applyInterruption(int index) {
    var lane = _state.laneAt(index);
    if (lane.status != TemperatureLaneStatus.streaming) {
      return;
    }
    lane = lane.copyWith(
      status: TemperatureLaneStatus.failed,
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

  void setRating({
    required int laneIndex,
    required TemperatureRatingKind kind,
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
      TemperatureRatingKind.accuracy => lane.evaluation.copyWith(
        accuracy: value,
        clearAccuracy: value == null,
      ),
      TemperatureRatingKind.creativity => lane.evaluation.copyWith(
        creativity: value,
        clearCreativity: value == null,
      ),
      TemperatureRatingKind.diversity => lane.evaluation.copyWith(
        diversity: value,
        clearDiversity: value == null,
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

  TemperatureExperimentState _replaceLane(
    int index,
    TemperatureLaneState lane,
  ) {
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
