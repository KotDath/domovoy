import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../settings/domain/model_settings.dart';
import '../domain/agent.dart';

enum PromptRunStatus { idle, streaming, completed, failed }

@immutable
final class PromptState {
  const PromptState({
    this.status = PromptRunStatus.idle,
    this.reasoning = '',
    this.answer = '',
    this.failure,
    this.reasoningExpanded = false,
    this.inputError,
  });

  final PromptRunStatus status;
  final String reasoning;
  final String answer;
  final AgentFailure? failure;
  final bool reasoningExpanded;
  final String? inputError;

  bool get isStreaming => status == PromptRunStatus.streaming;
  bool get hasOutput => reasoning.isNotEmpty || answer.isNotEmpty;

  PromptState copyWith({
    PromptRunStatus? status,
    String? reasoning,
    String? answer,
    AgentFailure? failure,
    bool clearFailure = false,
    bool? reasoningExpanded,
    String? inputError,
    bool clearInputError = false,
  }) {
    return PromptState(
      status: status ?? this.status,
      reasoning: reasoning ?? this.reasoning,
      answer: answer ?? this.answer,
      failure: clearFailure ? null : failure ?? this.failure,
      reasoningExpanded: reasoningExpanded ?? this.reasoningExpanded,
      inputError: clearInputError ? null : inputError ?? this.inputError,
    );
  }
}

final class PromptController extends ChangeNotifier {
  PromptController(
    this._agent, {
    DeepSeekModelSettingsStore? modelSettingsStore,
    ThinkingMode initialThinking = ThinkingMode.enabled,
  }) : _modelSettingsStore = modelSettingsStore,
       _thinking = initialThinking;

  final Agent _agent;
  final DeepSeekModelSettingsStore? _modelSettingsStore;
  StreamSubscription<AgentEvent>? _subscription;
  PromptState _state = const PromptState();
  ThinkingMode _thinking;
  bool _disposed = false;
  int _generation = 0;

  PromptState get state => _state;

  /// Reasoning mode snapshotted for the next request. Defaults to enabled.
  ThinkingMode get thinking => _thinking;

  void setThinkingMode(ThinkingMode mode) {
    if (_thinking == mode) {
      return;
    }
    _thinking = mode;
    _notifyListeners();
  }

  /// Loads the persisted reasoning setting. Missing values and read
  /// failures fall back to [ThinkingMode.enabled].
  Future<void> loadThinking() async {
    final store = _modelSettingsStore;
    if (store == null) {
      return;
    }
    try {
      final settings = await store.read();
      _thinking = settings == null || settings.reasoningEnabled
          ? ThinkingMode.enabled
          : ThinkingMode.disabled;
    } on Object {
      _thinking = ThinkingMode.enabled;
    }
    _notifyListeners();
  }

  bool submit(String rawInput) {
    if (_disposed || _state.isStreaming) {
      return false;
    }

    final normalized = rawInput.trim();
    if (normalized.isEmpty) {
      _setState(_state.copyWith(inputError: 'Введите вопрос или инструкцию.'));
      return false;
    }

    unawaited(_subscription?.cancel());
    final generation = ++_generation;
    final thinking = _thinking;
    _setState(const PromptState(status: PromptRunStatus.streaming));
    _subscription = _agent
        .prompt(AgentInput(normalized, thinking: thinking))
        .listen(
          (event) => _onEvent(generation, event),
          onError: (_) {
            if (generation == _generation) {
              _finishWithFailure(
                const AgentFailure(
                  kind: AgentFailureKind.unknown,
                  message: 'Не удалось получить ответ. Попробуйте ещё раз.',
                ),
              );
            }
          },
          onDone: () {
            if (generation == _generation && _state.isStreaming) {
              _finishWithFailure(
                const AgentFailure(
                  kind: AgentFailureKind.interrupted,
                  message: 'Поток ответа завершился неожиданно.',
                ),
              );
            }
          },
          cancelOnError: false,
        );
    return true;
  }

  void clearInputError() {
    if (_state.inputError != null) {
      _setState(_state.copyWith(clearInputError: true));
    }
  }

  void toggleReasoning() {
    if (_state.reasoning.isEmpty) {
      return;
    }
    _setState(_state.copyWith(reasoningExpanded: !_state.reasoningExpanded));
  }

  void _onEvent(int generation, AgentEvent event) {
    if (generation != _generation || !_state.isStreaming) {
      return;
    }

    switch (event) {
      case AgentReasoningDelta(:final text):
        _setState(
          _state.copyWith(
            reasoning: '${_state.reasoning}$text',
            reasoningExpanded: _state.reasoning.isEmpty
                ? true
                : _state.reasoningExpanded,
          ),
        );
      case AgentAnswerDelta(:final text):
        _setState(_state.copyWith(answer: '${_state.answer}$text'));
      case AgentCompleted():
        _setState(
          _state.copyWith(
            status: PromptRunStatus.completed,
            clearFailure: true,
          ),
        );
        unawaited(_subscription?.cancel());
      case AgentFailed(:final failure):
        _finishWithFailure(failure);
        unawaited(_subscription?.cancel());
    }
  }

  void _finishWithFailure(AgentFailure failure) {
    if (!_state.isStreaming) {
      return;
    }
    _setState(
      _state.copyWith(status: PromptRunStatus.failed, failure: failure),
    );
  }

  void _setState(PromptState value) {
    if (_disposed) {
      return;
    }
    _state = value;
    notifyListeners();
  }

  void _notifyListeners() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
