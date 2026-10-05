import 'dart:convert';

import '../llm/cancellation.dart';
import 'models.dart';

enum RagTaskFactKind { goal, constraint, glossary, clarification, openQuestion }

extension RagTaskFactKindWire on RagTaskFactKind {
  String get wireName =>
      this == RagTaskFactKind.openQuestion ? 'open_question' : name;
}

/// A user quotation, never a model-authored paraphrase or a document fact.
final class RagTaskFact {
  const RagTaskFact({
    required this.id,
    required this.kind,
    required this.quote,
    required this.userText,
    required this.submissionId,
    required this.sourceRevision,
    required this.sourceKind,
  });
  final String id, quote, userText, submissionId, sourceKind;
  final RagTaskFactKind kind;
  final int sourceRevision;

  factory RagTaskFact.fromJson(Map<String, dynamic> json) {
    final fact = RagTaskFact(
      id: json['id'] as String,
      kind: RagTaskFactKind.values.singleWhere(
        (k) => k.wireName == json['kind'],
      ),
      quote: json['quote'] as String,
      userText: json['user_text'] as String,
      submissionId: json['submission_id'] as String,
      sourceRevision: json['source_revision'] as int,
      sourceKind: json['source_kind'] as String,
    );
    fact.validate();
    if (json['user_text_sha256'] != ragHash(fact.userText)) {
      throw const FormatException('Task-state source hash mismatch');
    }
    return fact;
  }

  void validate() {
    if (!_validId(id, kind) ||
        quote.trim().isEmpty ||
        quote.length > 1000 ||
        userText.length > 16000 ||
        !userText.contains(quote) ||
        submissionId.isEmpty ||
        sourceRevision < 1 ||
        !{'automatic_user_quote', 'manual_user_edit'}.contains(sourceKind)) {
      throw const FormatException('Invalid task-state provenance');
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wireName,
    'quote': quote,
    'user_text': userText,
    'user_text_sha256': ragHash(userText),
    'submission_id': submissionId,
    'source_revision': sourceRevision,
    'source_kind': sourceKind,
  };
}

final class RagTaskState {
  RagTaskState({
    required this.project,
    required this.session,
    this.revision = 0,
    Iterable<RagTaskFact> facts = const [],
    Iterable<RagTaskFact> superseded = const [],
  }) : facts = List.unmodifiable(facts),
       superseded = List.unmodifiable(superseded) {
    if (project.isEmpty ||
        session.isEmpty ||
        revision < 0 ||
        this.facts.length > 24 ||
        this.facts.map((f) => f.id).toSet().length != this.facts.length) {
      throw const FormatException('Invalid task-state scope/revision');
    }
    for (final fact in [...this.facts, ...this.superseded]) {
      fact.validate();
      if (fact.sourceRevision > revision) {
        throw const FormatException('Task fact is from a future revision');
      }
    }
  }
  final String project, session;
  final int revision;
  final List<RagTaskFact> facts, superseded;

  factory RagTaskState.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['type'] != 'rag_task_state') {
      throw const FormatException('Unknown task-state schema');
    }
    RagTaskFact read(Object? row) =>
        RagTaskFact.fromJson(Map<String, dynamic>.from(row as Map));
    return RagTaskState(
      project: json['project'] as String,
      session: json['session'] as String,
      revision: json['revision'] as int,
      facts: (json['facts'] as List).map(read),
      superseded: (json['superseded'] as List).map(read),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'rag_task_state',
    'version': 1,
    'project': project,
    'session': session,
    'revision': revision,
    'application': 'automatic_validated_user_quotes_not_confirmed_memory',
    'facts': facts.map((f) => f.toJson()).toList(),
    'superseded': superseded.map((f) => f.toJson()).toList(),
  };

  /// Identity binds the exact revision AND owner. Another chat's IDs are invalid.
  String evidenceId(RagTaskFact fact) =>
      'user-state:${ragHash(jsonEncode([project, session, revision, fact.id, fact.submissionId, fact.quote]))}';

  Map<String, Object?> evidenceJson(RagTaskFact fact) => {
    'chunk_id': evidenceId(fact),
    'source_kind': 'user_state',
    'project': project,
    'session': session,
    'state_revision': revision,
    'fact_id': fact.id,
    'kind': fact.kind.wireName,
    'text': fact.quote,
    'submission_id': fact.submissionId,
    'provenance': fact.sourceKind,
  };

  String get context => facts.isEmpty
      ? ''
      : 'USER_TASK_STATE_EVIDENCE_JSON\n${jsonEncode({'project': project, 'session': session, 'revision': revision, 'facts': facts.map(evidenceJson).toList()})}\nEND_USER_TASK_STATE_EVIDENCE';

  /// Separate from the current question, inspectable and never indexed as docs.
  String retrievalQuery(String question) => facts.isEmpty
      ? question
      : '$question\nUser task conditions (not document facts):\n${facts.map((f) => '${f.id}: ${f.quote}').join('\n')}';
}

bool _validId(String id, RagTaskFactKind kind) =>
    id.startsWith('${kind.wireName}.') &&
    RegExp(r'^[a-z][a-z0-9_.-]{1,63}$').hasMatch(id);

final class RagTaskUpdate {
  const RagTaskUpdate(this.id, this.kind, this.quote);
  final String id, quote;
  final RagTaskFactKind kind;
}

final class RagTaskPatch {
  RagTaskPatch(Iterable<RagTaskUpdate> updates)
    : updates = List.unmodifiable(updates);
  final List<RagTaskUpdate> updates;

  factory RagTaskPatch.parse(
    String raw,
    String userInput,
    RagTaskState before,
  ) {
    if (raw.length > 16000 || userInput.length > 16000) {
      throw const FormatException('Task-state input too large');
    }
    final root = jsonDecode(raw);
    if (root is! Map ||
        root.length != 1 ||
        root['updates'] is! List ||
        (root['updates'] as List).length > 8) {
      throw const FormatException('Task-state patch schema');
    }
    final updates = <RagTaskUpdate>[];
    for (final row in root['updates'] as List) {
      if (row is! Map ||
          row.length != 3 ||
          row['id'] is! String ||
          row['kind'] is! String ||
          row['quote'] is! String) {
        throw const FormatException('Task-state update schema');
      }
      final kind = RagTaskFactKind.values
          .where((v) => v.wireName == row['kind'])
          .firstOrNull;
      final id = row['id'] as String, quote = row['quote'] as String;
      if (kind == null ||
          !_validId(id, kind) ||
          quote.trim().isEmpty ||
          quote.length > 1000 ||
          !userInput.contains(quote) ||
          updates.any((u) => u.id == id)) {
        throw const FormatException('Task-state quote/identity invalid');
      }
      updates.add(RagTaskUpdate(id, kind, quote));
    }
    final ids = {...before.facts.map((f) => f.id), ...updates.map((u) => u.id)};
    if (ids.length > 24) throw const FormatException('Task-state capacity');
    return RagTaskPatch(updates);
  }

  RagTaskState apply(
    RagTaskState before, {
    required String userText,
    required String submissionId,
    String sourceKind = 'automatic_user_quote',
  }) {
    final active = {for (final fact in before.facts) fact.id: fact};
    final old = before.superseded.toList();
    var changed = false;
    for (final update in updates) {
      if (active[update.id]?.quote == update.quote) continue;
      final previous = active[update.id];
      if (previous != null) old.add(previous);
      active[update.id] = RagTaskFact(
        id: update.id,
        kind: update.kind,
        quote: update.quote,
        userText: userText,
        submissionId: submissionId,
        sourceRevision: before.revision + 1,
        sourceKind: sourceKind,
      );
      changed = true;
    }
    return changed
        ? RagTaskState(
            project: before.project,
            session: before.session,
            revision: before.revision + 1,
            facts: active.values,
            superseded: old,
          )
        : before;
  }
}

abstract interface class RagTaskStateRepository {
  Future<RagTaskState> load(String project, String session);
  Future<void> save(
    RagTaskState state, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

final class RagTaskStateConflict implements Exception {
  const RagTaskStateConflict();
}

final class RagTaskExtraction {
  const RagTaskExtraction(this.patch, this.audit);
  final RagTaskPatch patch;
  final Map<String, Object?> audit;
}

abstract interface class RagTaskExtractor {
  Future<RagTaskExtraction> extract(
    RagTaskState before,
    String userInput,
    CancellationToken cancellation,
  );
}
