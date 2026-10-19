import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/projects/ids.dart';
import '../../../core/support/support.dart';
import '../../chat/application/chat_workspace_controller.dart';
import '../../chat/application/chat_workspace_state.dart';
import 'support_run_preparer.dart';
import 'support_service.dart';

final class SupportController extends ChangeNotifier {
  SupportController({
    required this.service,
    required this.chat,
    required this.preparer,
    required this.captureSnapshot,
    required this.initialSelection,
  }) {
    _subscription = chat.states.listen((_) => _notify());
    preparer.addListener(_notify);
  }
  final SupportService service;
  final ChatWorkspaceController chat;
  final SupportRunPreparer preparer;
  final SupportSnapshot Function(ModelRef model) captureSnapshot;
  final AgentSessionSelection Function() initialSelection;
  late final StreamSubscription<ChatWorkspaceState> _subscription;
  List<SupportTicket> tickets = [];
  List<Map<String, dynamic>> sources = [];
  SupportTicket? selected;
  bool busy = false;
  bool _disposed = false;
  String? error;
  bool get locked => busy || chat.state.isBusy;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _work(() async {
    await preparer.loadMetadata();
    await service.tickets.owner();
    await chat.initialize();
    await reload();
  });
  Future<void> reload() async {
    tickets = await service.tickets.list();
    final id = selected?.id;
    selected = id == null ? null : tickets.where((t) => t.id == id).firstOrNull;
    if (selected != null) {
      sources = await preparer.traces.list(
        supportRagProject,
        selected!.sessionId.value,
      );
    }
    _notify();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (locked) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } on Object {
      error =
          'Не удалось сохранить или открыть обращение. Обновите список и повторите. Незавершённое создание можно продолжить.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> create(
    String subject,
    String description,
    SupportSnapshot snapshot, {
    ProjectId? projectId,
  }) => _work(() async {
    final selection = initialSelection();
    try {
      final ticket = await service.create(
        subject: subject,
        description: description,
        snapshot: snapshot,
        projectId: projectId,
      );
      await reload();
      await _select(ticket);
      if (chat.state.selectedSession?.selection != selection) {
        final changed = await chat.changeSelection(selection);
        if (!changed.isSuccess) throw StateError('Model selection failed');
      }
    } finally {
      await reload();
    }
  });
  Future<void> select(SupportTicket ticket) =>
      _work(() async => _select(ticket));
  Future<void> _select(SupportTicket ticket) async {
    if (!ticket.ready) throw StateError('Creation incomplete');
    final result = await chat.restoreChat(ticket.sessionId);
    if (!result.isSuccess) throw StateError('Session restore failed');
    selected = ticket;
    sources = await preparer.traces.list(
      supportRagProject,
      ticket.sessionId.value,
    );
  }

  Future<void> recover(SupportTicket ticket) => _work(() async {
    await service.recover(ticket);
    await reload();
  });
  Future<void> setStatus(SupportStatus status) => _work(() async {
    if (selected == null) return;
    await service.changeStatus(selected!, status);
    await reload();
  });
  Future<void> refreshSnapshot() => _work(() async {
    final ticket = selected;
    final model = chat.state.selectedSession?.selection.model;
    if (ticket == null || model == null) return;
    await service.refreshSnapshot(ticket, captureSnapshot(model));
    await reload();
  });
  Future<ChatCommandResult> send(String text) async {
    final ticket = selected;
    if (ticket == null ||
        !ticket.ready ||
        ticket.status == SupportStatus.resolved) {
      return const ChatCommandResult.unchanged();
    }
    final result = await chat.send(text);
    try {
      await reload();
    } on Object {
      error =
          'Диалог завершён, но не удалось загрузить источники. Повторите открытие обращения.';
      _notify();
    }
    return result;
  }

  Future<ChatCommandResult> stop() {
    preparer.scopes.clear();
    return chat.stop();
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    preparer.removeListener(_notify);
    preparer.scopes.clear();
    await _subscription.cancel();
    await chat.dispose();
    preparer.dispose();
    super.dispose();
  }
}
