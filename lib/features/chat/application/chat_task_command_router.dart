import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/tasks/tasks.dart';
import '../../tasks/application/tasks.dart';
import 'chat_workspace_state.dart';

typedef ChatFallbackSender = Future<ChatCommandResult> Function(String input);

/// Routes explicit task commands without adding them to the chat transcript.
final class ChatTaskCommandRouter extends ChangeNotifier {
  ChatTaskCommandRouter({required this.tasks, required this.fallback}) {
    tasks.addListener(_handleTaskStateChanged);
  }

  static const _planPreparedNotice = 'План подготовлен для утверждения.';
  static const _replanPreparedNotice = 'Подготовлен новый план.';
  static const _pausedNotice = 'Задача приостановлена.';
  static const _resumedNotice = 'Задача продолжена.';

  final TaskWorkflowController tasks;
  final ChatFallbackSender fallback;

  String? _sessionId;
  String? _projectId;
  var _awaitingGoal = false;
  String? _notice;
  Future<void> _attachTail = Future<void>.value();

  bool get awaitingGoal => _awaitingGoal;
  String? get notice => _notice;

  Future<void> attach({required String sessionId, String? projectId}) {
    if (_sessionId == sessionId && _projectId == projectId) {
      return _attachTail;
    }
    _sessionId = sessionId;
    _projectId = projectId;
    _awaitingGoal = false;
    _notice = null;
    _notify();
    _attachTail = _attachTail.then((_) async {
      final result = await tasks.initialize(sessionId);
      if (!result.isAccepted) {
        _notice = _failureText(result);
        _notify();
      }
    });
    return _attachTail;
  }

  void detach() {
    if (_sessionId == null) return;
    _sessionId = null;
    _projectId = null;
    _awaitingGoal = false;
    _notice = null;
    _notify();
  }

  Future<ChatCommandResult> send(String input) async {
    await _attachTail;
    final value = input.trim();
    final command = value.toLowerCase();
    if (command == '/plan') {
      if (_sessionId == null) return _notAttached();
      final snapshot = tasks.state.snapshot;
      if (snapshot != null &&
          snapshot.sessionId == _sessionId &&
          !snapshot.cancelled &&
          snapshot.phase != TaskPhase.done) {
        return _failure(
          '[INVALID_TRANSITION] В этом чате уже есть активная задача.',
        );
      }
      _awaitingGoal = true;
      _notice = 'Следующее сообщение станет целью задачи.';
      _notify();
      return const ChatCommandResult.succeeded();
    }
    if (command.startsWith('/task')) {
      return _routeTaskCommand(command);
    }
    if (_awaitingGoal) {
      if (value.isEmpty) return _failure('Введите непустую цель задачи.');
      final sessionId = _sessionId;
      if (sessionId == null) return _notAttached();
      _awaitingGoal = false;
      final result = await tasks.start(
        sessionId: sessionId,
        projectId: _projectId,
        goal: value,
      );
      return _map(result, acceptedNotice: _planPreparedNotice);
    }
    return fallback(input);
  }

  Future<ChatCommandResult> _routeTaskCommand(String command) async {
    switch (command) {
      case '/task status':
        final snapshot = tasks.state.snapshot;
        _notice = snapshot == null
            ? 'Активной задачи в этом чате нет.'
            : 'Этап: ${_phaseLabel(snapshot.phase)}; действие: '
                  '${_actionLabel(snapshot.expectedAction)}.';
        _notify();
        return const ChatCommandResult.succeeded();
      case '/task pause':
        return _map(await tasks.pause(), acceptedNotice: _pausedNotice);
      case '/task resume':
        return _map(await tasks.resume(), acceptedNotice: _resumedNotice);
      case '/task replan':
        return _map(
          await tasks.replan(),
          acceptedNotice: _replanPreparedNotice,
        );
      case '/task cancel':
        return _map(await tasks.cancel(), acceptedNotice: 'Задача отменена.');
      default:
        return _failure(
          'Неизвестная команда. Доступны status, pause, resume, replan, '
          'cancel.',
        );
    }
  }

  ChatCommandResult _map(
    TaskCommandResult result, {
    required String acceptedNotice,
  }) {
    if (result.isAccepted) {
      _notice = acceptedNotice;
      _notify();
      return const ChatCommandResult.succeeded();
    }
    return _failure(_failureText(result));
  }

  ChatCommandResult _notAttached() =>
      _failure('Сначала создайте или выберите чат.');

  ChatCommandResult _failure(String message) {
    _notice = message;
    _notify();
    return ChatCommandResult.failed(
      ChatWorkspaceError(kind: AgentErrorKind.configuration, message: message),
    );
  }

  String _failureText(TaskCommandResult result) {
    final failure = result.failure;
    return failure == null
        ? 'Команда задачи отклонена.'
        : '[${failure.code}] ${failure.message}';
  }

  void _handleTaskStateChanged() {
    final snapshot = tasks.state.snapshot;
    final planNotice =
        _notice == _planPreparedNotice || _notice == _replanPreparedNotice;
    final stalePlanNotice =
        planNotice &&
        (snapshot == null ||
            snapshot.phase != TaskPhase.planning ||
            snapshot.planApproved ||
            snapshot.paused ||
            snapshot.cancelled);
    final stalePausedNotice =
        _notice == _pausedNotice &&
        (snapshot == null || !snapshot.paused || snapshot.cancelled);
    final staleResumedNotice =
        _notice == _resumedNotice &&
        (snapshot == null ||
            snapshot.paused ||
            snapshot.cancelled ||
            snapshot.phase == TaskPhase.done);
    if (!stalePlanNotice && !stalePausedNotice && !staleResumedNotice) return;
    _notice = null;
    _notify();
  }

  @override
  void dispose() {
    tasks.removeListener(_handleTaskStateChanged);
    super.dispose();
  }

  void _notify() {
    if (!hasListeners) return;
    notifyListeners();
  }
}

String _phaseLabel(TaskPhase phase) => switch (phase) {
  TaskPhase.planning => 'планирование',
  TaskPhase.execution => 'выполнение',
  TaskPhase.validation => 'валидация',
  TaskPhase.done => 'готово',
};

String _actionLabel(TaskExpectedAction action) => switch (action) {
  TaskExpectedAction.captureGoal => 'задать цель',
  TaskExpectedAction.preparePlan => 'подготовить план',
  TaskExpectedAction.approvePlan => 'утвердить план',
  TaskExpectedAction.runNode => 'выполнить шаг',
  TaskExpectedAction.verifyNode => 'проверить шаг',
  TaskExpectedAction.repairNode => 'исправить шаг',
  TaskExpectedAction.composeFinal => 'собрать финал',
  TaskExpectedAction.validateFinal => 'проверить финал',
  TaskExpectedAction.resume => 'продолжить задачу',
  TaskExpectedAction.resolveFailure => 'устранить ошибку',
  TaskExpectedAction.none => 'нет',
};
