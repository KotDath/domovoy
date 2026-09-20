import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../tasks/application/tasks.dart';
import 'chat_workspace_state.dart';

typedef ChatFallbackSender = Future<ChatCommandResult> Function(String input);

/// Routes explicit task commands without adding them to the chat transcript.
final class ChatTaskCommandRouter extends ChangeNotifier {
  ChatTaskCommandRouter({required this.tasks, required this.fallback});

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
    final value = input.trim();
    final command = value.toLowerCase();
    if (command == '/plan') {
      if (_sessionId == null) return _notAttached();
      _awaitingGoal = true;
      _notice = 'Следующее сообщение станет целью задачи.';
      _notify();
      return const ChatCommandResult.succeeded();
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
      return _map(result, acceptedNotice: 'План подготовлен для утверждения.');
    }
    switch (command) {
      case '/task status':
        final snapshot = tasks.state.snapshot;
        _notice = snapshot == null
            ? 'Активной задачи в этом чате нет.'
            : 'Этап: ${snapshot.phase.name}; действие: '
                  '${snapshot.expectedAction.name}.';
        _notify();
        return const ChatCommandResult.succeeded();
      case '/task pause':
        return _map(
          await tasks.pause(),
          acceptedNotice: 'Задача приостановлена.',
        );
      case '/task resume':
        return _map(await tasks.resume(), acceptedNotice: 'Задача продолжена.');
      case '/task replan':
        return _map(
          await tasks.replan(),
          acceptedNotice: 'Подготовлен новый план.',
        );
      case '/task cancel':
        return _map(await tasks.cancel(), acceptedNotice: 'Задача отменена.');
      default:
        if (command.startsWith('/task')) {
          return _failure(
            'Неизвестная команда. Доступны status, pause, resume, replan, '
            'cancel.',
          );
        }
        return fallback(input);
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

  void _notify() {
    if (!hasListeners) return;
    notifyListeners();
  }
}
