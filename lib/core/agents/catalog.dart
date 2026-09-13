import '../llm/identifiers.dart';
import '../llm/json.dart';
import 'errors.dart';
import 'ids.dart';
import 'record.dart';
import 'selection.dart';

abstract interface class AgentSessionCatalog {
  Future<AgentSessionCatalogSnapshot> list();
}

final class AgentSessionSummary {
  const AgentSessionSummary({
    required this.id,
    required this.revision,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    required this.model,
    required this.selection,
    this.title,
    required this.messageCount,
  });

  final AgentSessionId id;
  final int revision;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ModelRef model;
  final AgentSessionSelection selection;
  final String? title;
  final int messageCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSessionSummary &&
          other.id == id &&
          other.revision == revision &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.model == model &&
          other.selection == selection &&
          other.title == title &&
          other.messageCount == messageCount;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    createdAtMicros,
    updatedAtMicros,
    model,
    selection,
    title,
    messageCount,
  );
}

final class AgentSessionCatalogIssue {
  const AgentSessionCatalogIssue({required this.reason, this.id});

  final AgentSessionId? id;
  final AgentError reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSessionCatalogIssue &&
          other.id == id &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(id, reason);
}

final class AgentSessionCatalogSnapshot {
  AgentSessionCatalogSnapshot({
    List<AgentSessionSummary> available = const <AgentSessionSummary>[],
    List<AgentSessionCatalogIssue> issues = const <AgentSessionCatalogIssue>[],
  }) : available = List<AgentSessionSummary>.unmodifiable(available),
       issues = List<AgentSessionCatalogIssue>.unmodifiable(issues);

  final List<AgentSessionSummary> available;
  final List<AgentSessionCatalogIssue> issues;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSessionCatalogSnapshot &&
          listEquals(other.available, available) &&
          listEquals(other.issues, issues);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(available), Object.hashAll(issues));
}

AgentSessionSummary summarizeAgentSession(AgentSessionRecord record) {
  return AgentSessionSummary(
    id: record.id,
    revision: record.revision,
    createdAtMicros: record.createdAtMicros,
    updatedAtMicros: record.updatedAtMicros,
    model: record.selection.model,
    selection: record.selection,
    title: record.title,
    messageCount: record.transcript.messages.length,
  );
}

int compareAgentSessionSummaries(
  AgentSessionSummary left,
  AgentSessionSummary right,
) {
  final byUpdated = right.updatedAtMicros.compareTo(left.updatedAtMicros);
  return byUpdated != 0 ? byUpdated : left.id.value.compareTo(right.id.value);
}
