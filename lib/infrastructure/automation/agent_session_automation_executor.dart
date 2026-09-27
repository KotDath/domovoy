import 'dart:async';

import '../../core/agents/agents.dart';
import '../../core/automation/automation.dart';
import '../../core/llm/llm.dart';
import '../llm/discovery/provider_manifest.dart';

/// System prompt pinned to every scheduled run.
///
/// It is part of the run snapshot contract: the same text is used regardless
/// of the user prompt, so an unattended run can never be talked into waiting
/// for an approval, creating schedules or leaking secrets.
const automationScheduledSystemPrompt =
    'Ты — агент Domovoy, запущенный по расписанию без человека рядом.\n'
    '- Не задавай вопросов и не жди подтверждений: подтверждения недоступны.\n'
    '- Разрешены только перечисленные инструменты. Создавать новые расписания '
    'и запускать другие задачи запрещено.\n'
    '- Заверши работу одной короткой сводкой: что сделано, что важно, что не '
    'удалось.\n'
    '- Не включай в ответ ключи, токены и другие секреты.';

/// Executes one automation run as a fresh, pinned agent session.
///
/// Every run starts its own transient session with the task snapshot: pinned
/// model, prompt, allowed tools, delivery and limits. The scheduled-task tool
/// grant is registered under the task's stable policy id and denies the
/// intrinsic schedule-creation identities; `interactiveApproval` is false, so
/// an `ask` decision can never wait for a person.
///
/// Availability is checked before any model call: a missing model, a tool that
/// is not registered or cannot be represented, and a missing provider secret
/// all produce a visible `failed` run instead of a silently reduced one.
final class AgentSessionAutomationExecutor implements AutomationRunExecutor {
  AgentSessionAutomationExecutor({
    required this.runtime,
    required this.models,
    required this.tools,
    required this.policies,
    this.credentials,
    Map<String, String>? credentialEnvironmentVariables,
    this.schemaProfile,
    AutomationRunLimits runLimits = const AutomationRunLimits(),
  }) : credentialEnvironmentVariables =
           credentialEnvironmentVariables ??
           <String, String>{
             for (final spec in ApiKeyProviderManifest.entries)
               spec.id: spec.environmentVariable,
           },
       runLimits = runLimits.validate();

  final AgentRuntime runtime;
  final LlmProviderRegistry models;
  final AgentToolRegistry tools;

  /// Policy table of the runtime; B9 passes `runtime.policies`.
  final Map<String, ToolPermissionPolicy> policies;

  /// Optional provider credential resolver used for the pre-flight secret
  /// check. When null, the check is skipped and the provider reports the
  /// missing key itself.
  final ProviderCredentialResolver? credentials;

  /// Provider id to environment variable name, used with [credentials].
  final Map<String, String> credentialEnvironmentVariables;

  /// Optional override of the schema profile used by the availability check;
  /// by default the profile of the model's wire family is used.
  final ToolSchemaProfile? schemaProfile;

  final AutomationRunLimits runLimits;

  @override
  Future<AutomationRunAvailability> availability(AutomationTask task) async {
    if (!models.isModelAvailable(task.model)) {
      return AutomationRunAvailability.unavailable(
        AutomationRunErrorKind.modelUnavailable,
        'Модель ${task.model} больше не доступна в каталоге провайдера; '
        'выберите другую модель в задаче.',
      );
    }
    final LlmResolvedSelection selection;
    try {
      selection = models.resolve(task.model);
    } on Object {
      return AutomationRunAvailability.unavailable(
        AutomationRunErrorKind.modelUnavailable,
        'Модель ${task.model} недоступна для запуска.',
      );
    }
    final profile =
        schemaProfile ??
        ToolSchemaProfile.forWireFamily(selection.model.wireFamily);
    final enabled = <ToolId>[for (final id in task.allowedToolIds) ToolId(id)];
    for (final id in task.allowedToolIds) {
      final tool = tools.lookup(id);
      if (tool == null) {
        return AutomationRunAvailability.unavailable(
          AutomationRunErrorKind.toolUnavailable,
          'Инструмент "$id" не зарегистрирован; задача не запускается с '
          'урезанными правами.',
        );
      }
      final reason = tools.unavailableReason(id);
      if (reason != null) {
        return AutomationRunAvailability.unavailable(
          AutomationRunErrorKind.toolUnavailable,
          'Инструмент "$id" недоступен: $reason',
        );
      }
    }
    final view = tools.view(enabled, profile: profile);
    if (view.descriptors.length != enabled.length) {
      final reason = view.unavailable.isEmpty
          ? 'схема инструмента не представима для выбранной модели'
          : view.unavailable.first.reason;
      return AutomationRunAvailability.unavailable(
        AutomationRunErrorKind.toolUnavailable,
        'Набор инструментов задачи не может быть показан модели: $reason',
      );
    }
    final credentialProblem = await _credentialProblem(task.model);
    if (credentialProblem != null) {
      return AutomationRunAvailability.unavailable(
        AutomationRunErrorKind.secretUnavailable,
        credentialProblem,
      );
    }
    return const AutomationRunAvailability.available();
  }

  @override
  Future<AutomationRunOutcome> execute(
    AutomationRunRequest request, {
    required AutomationResultCancellation cancellation,
  }) async {
    final task = request.task;
    final enabled = <ToolId>[for (final id in task.allowedToolIds) ToolId(id)];
    policies[task.policyId] = ToolAccessPolicy(
      id: PolicyId(task.policyId),
      grant: ToolAccessGrant.scheduledTask(allowedToolIds: task.allowedToolIds),
    );
    final definition = AgentDefinition(
      id: AgentId(
        'automation-${task.taskId.value}-${request.runId.replaceAll('_', '-')}',
      ),
      name: _sessionName(task),
      systemPrompt: automationScheduledSystemPrompt,
      model: task.model,
      enabledTools: enabled,
      policy: PolicyId(task.policyId),
      interactiveApproval: false,
      generation: LlmGenerationConfig.defaults,
      limits: AgentRunLimits(
        maxModelTurns: runLimits.maxModelTurns,
        maxToolCalls: runLimits.maxToolCalls,
        maxDuration: runLimits.runtimeBudget,
        maxOutputTokensPerTurn: runLimits.maxOutputTokensPerTurn,
      ),
    );
    if (cancellation.isCancelled) {
      return AutomationRunOutcome(
        status: AutomationRunStatus.interrupted,
        error: AutomationRunError(
          kind: AutomationRunErrorKind.interrupted,
          message: 'Запуск отменён до обращения к модели.',
        ),
      );
    }
    final session = await runtime
        .agent(definition)
        .createSession(persistence: SessionPersistence.transient);
    try {
      final run = session.run(request.prompt);
      final cancelSubscription = cancellation.whenCancelled.then((_) async {
        await run.cancel();
      });
      final collector = _RunCollector();
      try {
        await for (final event in run.events) {
          collector.add(event);
        }
      } on Object {
        collector.streamFailed = true;
      } finally {
        unawaited(cancelSubscription);
      }
      if (cancellation.isCancelled) {
        return collector.outcome(
          status: AutomationRunStatus.interrupted,
          error: AutomationRunError(
            kind: AutomationRunErrorKind.interrupted,
            message: 'Запуск прерван до завершения.',
          ),
          limits: runLimits,
        );
      }
      return collector.outcome(limits: runLimits);
    } finally {
      try {
        await session.close();
      } on Object {
        // Closing a transient session is best effort; the run result is
        // already decided.
      }
    }
  }

  Future<String?> _credentialProblem(ModelRef model) async {
    final resolver = credentials;
    if (resolver == null) {
      return null;
    }
    final environmentVariable =
        credentialEnvironmentVariables[model.providerId.value];
    if (environmentVariable == null) {
      return null;
    }
    try {
      await resolver.resolve(
        providerId: model.providerId,
        environmentVariable: environmentVariable,
      );
      return null;
    } on LlmMissingCredentialException {
      return 'Нет API-ключа провайдера ${model.providerId.value}; добавьте его '
          'в настройках перед запуском задачи.';
    } on Object {
      return 'Не удалось прочитать ключ провайдера '
          '${model.providerId.value}.';
    }
  }

  String _sessionName(AutomationTask task) {
    final label = task.name.trim();
    return label.length <= 120 ? label : label.substring(0, 120);
  }
}

final class _RunCollector {
  final StringBuffer _answer = StringBuffer();
  final Map<String, _TracedCall> _calls = <String, _TracedCall>{};
  final Map<String, String> _unavailable = <String, String>{};
  var modelTurns = 0;
  var streamFailed = false;
  AgentRunEvent? terminal;

  void add(AgentRunEvent event) {
    switch (event) {
      case AgentAnswerDelta(:final text):
        _answer.write(text);
      case AgentToolAssembled(:final calls):
        for (final call in calls) {
          _calls.putIfAbsent(call.callId.value, () => _TracedCall(call.name));
        }
      case AgentToolStarted(:final callId, :final name):
        final call = _calls.putIfAbsent(callId.value, () => _TracedCall(name));
        call.started = true;
        call.startedName = name;
      case AgentToolFinished(:final callId, :final success):
        final call = _calls[callId.value];
        if (call != null) {
          call.finished = true;
          call.success = success;
        }
      case AgentPermissionDecision(:final callId, :final permission):
        if (permission == ToolPermission.deny) {
          final call = _calls[callId.value];
          if (call != null) {
            call.denied = true;
          }
        }
      case AgentToolUnavailable(:final toolId, :final reason):
        _unavailable[toolId.value] = reason;
      case AgentUsageUpdated():
        modelTurns += 1;
      case AgentRunCompleted() ||
          AgentRunStopped() ||
          AgentRunFailed() ||
          AgentRunCancelled():
        terminal = event;
      default:
        break;
    }
  }

  AutomationRunOutcome outcome({
    AutomationRunStatus? status,
    AutomationRunError? error,
    required AutomationRunLimits limits,
  }) {
    final trace = <AutomationToolTraceEntry>[
      for (final call in _calls.values)
        if (call.started || call.denied || call.finished)
          AutomationToolTraceEntry(
            name: call.startedName ?? call.name,
            status: call.denied
                ? AutomationToolTraceStatus.denied
                : call.finished && call.success
                ? AutomationToolTraceStatus.succeeded
                : AutomationToolTraceStatus.failed,
            detail: call.denied ? 'Вызов отклонён политикой прав.' : null,
          ),
      for (final entry in _unavailable.entries)
        AutomationToolTraceEntry(
          name: entry.key,
          status: AutomationToolTraceStatus.unavailable,
          detail: entry.value,
        ),
    ];
    final toolCalls = _calls.values.where((call) => call.started).length;
    var resolvedStatus = status ?? _terminalStatus();
    var resolvedError = error ?? _terminalError();
    if (resolvedStatus == AutomationRunStatus.succeeded &&
        _unavailable.isNotEmpty) {
      resolvedStatus = AutomationRunStatus.failed;
      resolvedError = AutomationRunError(
        kind: AutomationRunErrorKind.toolUnavailable,
        message:
            'Задача закреплена за инструментами, которые недоступны: '
            '${_unavailable.keys.take(3).join(', ')}.',
      );
    }
    if (streamFailed && resolvedStatus == AutomationRunStatus.succeeded) {
      resolvedStatus = AutomationRunStatus.failed;
      resolvedError = AutomationRunError(
        kind: AutomationRunErrorKind.agent,
        message: 'Поток событий агента завершился ошибкой.',
      );
    }
    final answer = _answer.toString().trim();
    return AutomationRunOutcome(
      status: resolvedStatus,
      resultText: answer.isEmpty
          ? null
          : _clip(answer, limits.maxResultCharacters),
      error: resolvedError,
      trace: trace,
      modelTurns: modelTurns,
      toolCalls: toolCalls,
    );
  }

  AutomationRunStatus _terminalStatus() {
    final event = terminal;
    return switch (event) {
      AgentRunCompleted() => AutomationRunStatus.succeeded,
      AgentRunStopped() => AutomationRunStatus.failed,
      AgentRunFailed() => AutomationRunStatus.failed,
      AgentRunCancelled() => AutomationRunStatus.interrupted,
      _ => AutomationRunStatus.interrupted,
    };
  }

  AutomationRunError? _terminalError() {
    final event = terminal;
    return switch (event) {
      AgentRunStopped(:final reason) => AutomationRunError(
        kind: _stopReasonKind(reason),
        message: 'Запуск остановлен: ${_stopReasonText(reason)}.',
      ),
      AgentRunFailed(:final error) => AutomationRunError(
        kind: _agentErrorKind(error.kind),
        message: error.message,
      ),
      AgentRunCancelled() => AutomationRunError(
        kind: AutomationRunErrorKind.interrupted,
        message: 'Запуск отменён.',
      ),
      _ => null,
    };
  }
}

final class _TracedCall {
  _TracedCall(this.name);

  final String name;
  String? startedName;
  var started = false;
  var finished = false;
  var success = false;
  var denied = false;
}

AutomationRunErrorKind _stopReasonKind(AgentStopReason reason) {
  return switch (reason) {
    AgentStopReason.modelTurnLimit ||
    AgentStopReason.toolCallLimit ||
    AgentStopReason.durationLimit ||
    AgentStopReason.idleTimeout ||
    AgentStopReason.noProgress ||
    AgentStopReason.inputBudget ||
    AgentStopReason.outputBudget ||
    AgentStopReason.totalBudget => AutomationRunErrorKind.limits,
  };
}

String _stopReasonText(AgentStopReason reason) {
  return switch (reason) {
    AgentStopReason.modelTurnLimit => 'достигнут лимит обращений к модели',
    AgentStopReason.toolCallLimit => 'достигнут лимит вызовов инструментов',
    AgentStopReason.durationLimit => 'достигнут лимит времени',
    AgentStopReason.idleTimeout => 'истёк таймаут ожидания',
    AgentStopReason.noProgress => 'агент перестал продвигаться',
    AgentStopReason.inputBudget => 'исчерпан бюджет входных токенов',
    AgentStopReason.outputBudget => 'исчерпан бюджет выходных токенов',
    AgentStopReason.totalBudget => 'исчерпан общий бюджет токенов',
  };
}

AutomationRunErrorKind _agentErrorKind(AgentErrorKind kind) {
  return switch (kind) {
    AgentErrorKind.provider => AutomationRunErrorKind.provider,
    AgentErrorKind.configuration => AutomationRunErrorKind.unavailable,
    AgentErrorKind.persistence => AutomationRunErrorKind.internal,
    AgentErrorKind.conflict => AutomationRunErrorKind.internal,
    AgentErrorKind.busy => AutomationRunErrorKind.noOverlap,
    AgentErrorKind.cancelled => AutomationRunErrorKind.cancelled,
    _ => AutomationRunErrorKind.agent,
  };
}

String _clip(String value, int max) {
  if (value.length <= max) {
    return value;
  }
  return '${value.substring(0, max - 1)}…';
}
