import 'dart:async';

import '../../prompt/domain/agent.dart';
import '../domain/format_contracts.dart';
import '../domain/format_validators.dart';
import '../domain/repair_input.dart';
import 'comparison_controller.dart';

final class FormatExperimentController extends BaselineControlledController {
  FormatExperimentController(super.agent);

  String basePrompt = 'Придумай короткий рассказ о домовом.';
  ResponseFormatKind formatKind = ResponseFormatKind.json;
  JsonFormatContract jsonContract = JsonFormatContract.demo();
  MarkdownFormatContract markdownContract = MarkdownFormatContract.demo();

  String? promptError;
  String? contractError;

  FormatValidationResult? baselineValidation;
  FormatValidationResult? controlledValidation;
  FormatValidationResult? repairedValidation;

  ExperimentLaneState _repair = const ExperimentLaneState();
  ExperimentLaneState get repairLane => _repair;

  bool _repairAttempted = false;
  bool _repairRunning = false;
  bool get repairAttempted => _repairAttempted;
  bool get isRepairRunning => _repairRunning;
  StreamSubscription<AgentEvent>? _repairSubscription;
  Completer<void>? _repairGate;

  ThinkingMode _lastThinking = ThinkingMode.enabled;
  ThinkingMode get lastThinking => _lastThinking;

  FormatControl? _activeControl;
  JsonFormatContract? _activeJson;
  MarkdownFormatContract? _activeMarkdown;

  bool get repairAvailable =>
      !_repairAttempted &&
      !_repairRunning &&
      !isRunning &&
      controlled.status == ExperimentLaneStatus.completed &&
      controlledValidation != null &&
      !controlledValidation!.valid;

  bool get repairUnnecessary =>
      controlled.status == ExperimentLaneStatus.completed &&
      controlledValidation != null &&
      controlledValidation!.valid;

  String get appliedControlLabel {
    final control = _activeControl;
    if (control == null) {
      return '—';
    }
    if (control.kind == ResponseFormatKind.json) {
      return 'response_format=json_object + контракт JSON';
    }
    return 'контракт Markdown без response_format';
  }

  bool runComparison({
    required String rawPrompt,
    required ThinkingMode thinking,
  }) {
    if (isRunning || _repairRunning) {
      return false;
    }
    final prompt = rawPrompt.trim();
    promptError = prompt.isEmpty ? 'Введите базовый запрос.' : null;
    if (formatKind == ResponseFormatKind.json) {
      contractError = jsonContract.validateContract();
    } else {
      contractError = markdownContract.validateContract();
    }
    if (promptError != null || contractError != null) {
      refresh();
      return false;
    }
    basePrompt = rawPrompt;
    _lastThinking = thinking;
    _activeControl = _currentControl();
    _activeJson = jsonContract;
    _activeMarkdown = markdownContract;
    baselineValidation = null;
    controlledValidation = null;
    repairedValidation = null;
    _repair = const ExperimentLaneState();
    _repairAttempted = false;
    final baselineInput = AgentInput(prompt, thinking: thinking);
    final controlledInput = AgentInput(
      prompt,
      thinking: thinking,
      control: _activeControl,
    );
    runPair(baselineInput, controlledInput);
    return true;
  }

  FormatControl _currentControl() {
    if (formatKind == ResponseFormatKind.json) {
      return FormatControl(
        kind: ResponseFormatKind.json,
        contractText: jsonContract.describe(),
        exampleText: jsonContract.example(),
      );
    }
    return FormatControl(
      kind: ResponseFormatKind.markdown,
      contractText: markdownContract.describe(),
    );
  }

  Future<bool> repair() {
    if (!repairAvailable) {
      return Future.value(false);
    }
    final control = _activeControl;
    if (control == null) {
      return Future.value(false);
    }
    final validation = controlledValidation;
    if (validation == null || validation.valid) {
      return Future.value(false);
    }
    _repairRunning = true;
    _repairAttempted = true;
    _repair = const ExperimentLaneState(status: ExperimentLaneStatus.streaming);
    refresh();
    final input = buildFormatRepairInput(
      originalTask: basePrompt.trim(),
      control: control,
      invalidAnswer: controlled.answer,
      diagnostics: validation.diagnostics,
      thinking: _lastThinking,
    );
    final gate = Completer<void>();
    _repairGate = gate;
    void finishRepair() {
      _repairRunning = false;
      if (!gate.isCompleted) {
        gate.complete();
      }
    }

    Future<void> cancelRepair() async {
      final subscription = _repairSubscription;
      _repairSubscription = null;
      if (subscription != null) {
        await subscription.cancel();
      }
    }

    _repairSubscription = agent
        .prompt(input)
        .listen(
          (event) {
            if (isControllerDisposed) {
              return;
            }
            switch (event) {
              case AgentReasoningDelta(:final text):
                _repair = _repair.copyWith(
                  reasoning: '${_repair.reasoning}$text',
                  reasoningExpanded: _repair.reasoning.isEmpty
                      ? true
                      : _repair.reasoningExpanded,
                );
                refresh();
              case AgentAnswerDelta(:final text):
                _repair = _repair.copyWith(answer: '${_repair.answer}$text');
                refresh();
              case AgentCompleted(:final finishReason, :final usage):
                _repair = _repair.copyWith(
                  status: ExperimentLaneStatus.completed,
                  clearFailure: true,
                  finishReason: finishReason,
                  usage: usage,
                );
                markRepairCall();
                _validateRepair();
                unawaited(cancelRepair());
                finishRepair();
              case AgentFailed(:final failure):
                _repair = _repair.copyWith(
                  status: ExperimentLaneStatus.failed,
                  failure: failure,
                );
                markRepairCall();
                _validateRepair();
                unawaited(cancelRepair());
                finishRepair();
            }
          },
          onError: (_) {
            if (isControllerDisposed) {
              finishRepair();
              return;
            }
            _repair = _repair.copyWith(
              status: ExperimentLaneStatus.failed,
              failure: const AgentFailure(
                kind: AgentFailureKind.interrupted,
                message: 'Поток ответа завершился неожиданно.',
              ),
            );
            markRepairCall();
            _validateRepair();
            unawaited(cancelRepair());
            finishRepair();
          },
          onDone: () {
            if (isControllerDisposed) {
              finishRepair();
              return;
            }
            if (_repair.status == ExperimentLaneStatus.streaming) {
              _repair = _repair.copyWith(
                status: ExperimentLaneStatus.failed,
                failure: const AgentFailure(
                  kind: AgentFailureKind.interrupted,
                  message: 'Поток ответа завершился неожиданно.',
                ),
              );
              markRepairCall();
              _validateRepair();
            }
            finishRepair();
          },
          cancelOnError: false,
        );
    return gate.future.then((_) => true);
  }

  void _validateRepair() {
    if (_repair.status != ExperimentLaneStatus.completed) {
      repairedValidation = null;
      refresh();
      return;
    }
    repairedValidation = _validateAnswer(_repair.answer);
    refresh();
  }

  @override
  void onLaneTerminal(bool isBaseline, ExperimentLaneState lane) {
    if (lane.status != ExperimentLaneStatus.completed) {
      if (isBaseline) {
        baselineValidation = null;
      } else {
        controlledValidation = null;
      }
      return;
    }
    final result = _validateAnswer(lane.answer);
    if (isBaseline) {
      baselineValidation = result;
    } else {
      controlledValidation = result;
    }
  }

  FormatValidationResult _validateAnswer(String answer) {
    if (_activeControl?.kind == ResponseFormatKind.markdown) {
      final contract = _activeMarkdown ?? markdownContract;
      return validateMarkdownAnswer(answer, contract);
    }
    final contract = _activeJson ?? jsonContract;
    return validateJsonAnswer(answer, contract);
  }

  void toggleRepairReasoning() {
    if (_repair.reasoning.isEmpty) {
      return;
    }
    _repair = _repair.copyWith(reasoningExpanded: !_repair.reasoningExpanded);
    refresh();
  }

  @override
  void dispose() {
    unawaited(_repairSubscription?.cancel());
    _repairSubscription = null;
    final gate = _repairGate;
    _repairGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
    super.dispose();
  }
}
