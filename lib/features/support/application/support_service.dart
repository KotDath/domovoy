import '../../../core/agents/agents.dart';
import '../../../core/projects/ids.dart';
import '../../../core/support/support.dart';

/// Creation is an idempotent, durable intent followed by session publication.
/// A crash at either boundary is recovered with the exact same session ID.
final class SupportService {
  SupportService({
    required this.tickets,
    required this.sessions,
    required this.catalog,
    required this.runtime,
    required this.definition,
  });
  final SupportRepository tickets;
  final AgentSessionRepository sessions;
  final AgentSessionCatalog catalog;
  final AgentRuntime runtime;
  final AgentDefinition definition;

  Future<SupportTicket> create({
    required String subject,
    required String description,
    required SupportSnapshot snapshot,
    ProjectId? projectId,
  }) async {
    if (subject.trim().isEmpty ||
        subject.length > 160 ||
        description.trim().isEmpty ||
        description.length > 6000) {
      throw ArgumentError(
        'Укажите тему (до 160 символов) и описание (до 6000 символов).',
      );
    }
    final id = newSupportId();
    final now = DateTime.now().microsecondsSinceEpoch;
    final ticket = SupportTicket(
      id: id,
      ownerId: await tickets.owner(),
      subject: subject.trim(),
      description: description.trim(),
      sessionId: AgentSessionId('$supportSessionPrefix$id'),
      createdAt: now,
      updatedAt: now,
      snapshot: snapshot,
      projectId: projectId,
    );
    await tickets.save(ticket, expectedRevision: null);
    return recover(ticket);
  }

  Future<SupportTicket> recover(SupportTicket intent) async {
    final current = await tickets.load(intent.id);
    if (current == null) throw StateError('Обращение не сохранено');
    final record = await sessions.load(current.sessionId);
    if (current.ready) {
      if (record == null ||
          record.definition.id != definition.id ||
          record.projectId != current.projectId) {
        throw StateError('Диалог обращения не найден');
      }
      return current;
    }
    if (record == null) {
      final session = await runtime
          .agent(definition)
          .createSession(
            id: current.sessionId,
            persistence: SessionPersistence.repository,
            projectId: current.projectId,
          );
      await session.close();
    } else if (record.definition.id != definition.id ||
        record.projectId != current.projectId) {
      throw StateError('Неверная связь обращения с диалогом');
    }
    final ready = current.update(ready: true);
    await tickets.save(ready, expectedRevision: current.revision);
    return ready;
  }

  Future<void> changeStatus(SupportTicket ticket, SupportStatus status) =>
      tickets.save(
        ticket.update(status: status),
        expectedRevision: ticket.revision,
      );
  Future<void> refreshSnapshot(
    SupportTicket ticket,
    SupportSnapshot snapshot,
  ) => tickets.save(
    ticket.update(snapshot: snapshot),
    expectedRevision: ticket.revision,
  );
}
