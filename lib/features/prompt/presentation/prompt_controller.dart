import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/generation.dart';
import '../../settings/domain/model_settings.dart';
import '../domain/prompt_workspace.dart';

enum PromptRunStatus { idle, streaming, completed, failed }

@immutable
final class PromptFailure {
  const PromptFailure({
    required this.message,
    this.isMissingCredential = false,
  });

  final String message;
  final bool isMissingCredential;
}

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
  final PromptFailure? failure;
  final bool reasoningExpanded;
  final String? inputError;

  bool get isStreaming => status == PromptRunStatus.streaming;
  bool get hasOutput => reasoning.isNotEmpty || answer.isNotEmpty;

  PromptState copyWith({
    PromptRunStatus? status,
    String? reasoning,
    String? answer,
    PromptFailure? failure,
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
    this._runtime, {
    required AgentDefinition definition,
    DeepSeekModelSettingsStore? modelSettingsStore,
    ReasoningMode initialThinking = ReasoningMode.enabled,
  }) : _definition = definition,
       _modelSettingsStore = modelSettingsStore,
       _thinking = initialThinking;

  final AgentRuntime _runtime;
  final AgentDefinition _definition;
  final DeepSeekModelSettingsStore? _modelSettingsStore;
  StreamSubscription<AgentRunEvent>? _subscription;
  AgentRun? _run;
  PromptState _state = const PromptState();
  ReasoningMode _thinking;
  bool _disposed = false;
  int _generation = 0;

  PromptState get state => _state;

  /// Reasoning mode snapshotted for the next request. Defaults to enabled.
  ReasoningMode get thinking => _thinking;

  void setThinkingMode(ReasoningMode mode) {
    if (_thinking == mode) {
      return;
    }
    _thinking = mode;
    _notifyListeners();
  }

  /// Loads the persisted reasoning setting. Missing values and read
  /// failures fall back to [ReasoningMode.enabled].
  Future<void> loadThinking() async {
    final store = _modelSettingsStore;
    if (store == null) {
      return;
    }
    try {
      final settings = await store.read();
      _thinking = settings == null || settings.reasoningEnabled
          ? ReasoningMode.enabled
          : ReasoningMode.disabled;
    } on Object {
      _thinking = ReasoningMode.enabled;
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

    final generation = ++_generation;
    final previousRun = _run;
    final previousSubscription = _subscription;
    _run = null;
    _subscription = null;
    unawaited(previousRun?.cancel());
    unawaited(previousSubscription?.cancel());
    final thinking = _thinking;
    _setState(const PromptState(status: PromptRunStatus.streaming));
    try {
      _run = _runtime
          .agent(PromptWorkspace.snapshotReasoning(_definition, thinking))
          .run(normalized);
    } on AgentException catch (error) {
      _finishWithFailure(_failureFrom(error.error));
      return true;
    } on Object {
      _finishWithFailure(_unknownFailure);
      return true;
    }
    _subscription = _run!.events.listen(
      (event) => _onEvent(generation, event),
      onError: (_) {
        if (generation == _generation) {
          _finishWithFailure(_unknownFailure);
        }
      },
      onDone: () {
        if (generation == _generation && _state.isStreaming) {
          _finishWithFailure(_interruptedFailure);
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

  void _onEvent(int generation, AgentRunEvent event) {
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
      case AgentRunCompleted():
      case AgentRunStopped():
        _setState(
          _state.copyWith(
            status: PromptRunStatus.completed,
            clearFailure: true,
          ),
        );
        unawaited(_subscription?.cancel());
      case AgentRunFailed(:final error):
        _finishWithFailure(_failureFrom(error));
        unawaited(_subscription?.cancel());
      case AgentRunCancelled():
        _finishWithFailure(_interruptedFailure);
        unawaited(_subscription?.cancel());
      case AgentRunStarted():
      case AgentInboundMessageConsumed():
      case AgentToolAssembled():
      case AgentPermissionDecision():
      case AgentToolStarted():
      case AgentToolProgress():
      case AgentToolFinished():
      case AgentUsageUpdated():
      case AgentNoProgressWarning():
        break;
    }
  }

  void _finishWithFailure(PromptFailure failure) {
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
    final run = _run;
    final subscription = _subscription;
    _run = null;
    _subscription = null;
    unawaited(run?.cancel());
    unawaited(subscription?.cancel());
    super.dispose();
  }
}

const _interruptedFailure = PromptFailure(
  message: 'Поток ответа завершился неожиданно.',
);

const _unknownFailure = PromptFailure(
  message: 'Не удалось получить ответ. Попробуйте ещё раз.',
);

PromptFailure _failureFrom(AgentError error) {
  return PromptFailure(
    message: error.message,
    isMissingCredential: error.kind == AgentErrorKind.configuration,
  );
}
