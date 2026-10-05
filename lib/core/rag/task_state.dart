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
    Iterable<RagTaskFact> retirements = const [],
  }) : facts = List.unmodifiable(facts),
       superseded = List.unmodifiable(superseded),
       retirements = List.unmodifiable(retirements) {
    if (project.isEmpty ||
        session.isEmpty ||
        revision < 0 ||
        this.facts.length > 24 ||
        this.facts.where((f) => f.kind == RagTaskFactKind.goal).length > 1 ||
        this.facts.map((f) => f.id).toSet().length != this.facts.length) {
      throw const FormatException('Invalid task-state scope/revision');
    }
    for (final fact in [
      ...this.facts,
      ...this.superseded,
      ...this.retirements,
    ]) {
      fact.validate();
      if (fact.sourceRevision > revision) {
        throw const FormatException('Task fact is from a future revision');
      }
    }
  }
  final String project, session;
  final int revision;
  final List<RagTaskFact> facts, superseded, retirements;

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
      retirements: ((json['retirements'] as List?) ?? []).map(read),
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
    'retirements': retirements.map((f) => f.toJson()).toList(),
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

void _validateChosenSlot(String id, String quote) {
  if (id == 'constraint.time' &&
      !RegExp(r'^(?:[01]?[0-9]|2[0-3]):[0-5][0-9]$').hasMatch(quote)) {
    throw const FormatException(
      'Chosen time must be an independent HH:MM quote',
    );
  }
  if (id == 'constraint.timezone' &&
      !RegExp(
        r'^(?:UTC|[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+)+)$',
      ).hasMatch(quote)) {
    throw const FormatException(
      'Chosen timezone must be an independent zone quote',
    );
  }
}

final class RagTaskUpdate {
  const RagTaskUpdate(this.id, this.kind, this.quote, {this.retire = false});
  final bool retire;
  final String id, quote;
  final RagTaskFactKind kind;
}

final class RagTaskPatch {
  RagTaskPatch(
    Iterable<RagTaskUpdate> updates, {
    this.ignoredReadOnlyUpdates = 0,
    Iterable<String> ignoredAmbiguousConstraintIds = const [],
  }) : updates = List.unmodifiable(updates),
       ignoredAmbiguousConstraintIds = List.unmodifiable(
         ignoredAmbiguousConstraintIds,
       );
  final List<RagTaskUpdate> updates;
  final int ignoredReadOnlyUpdates;
  final List<String> ignoredAmbiguousConstraintIds;

  factory RagTaskPatch.parse(
    String raw,
    String userInput,
    RagTaskState before, {
    bool automatic = true,
  }) {
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
    final seenUpdates = <String>{};
    final ignoredConstraints = <String>[];
    var ignored = 0;
    final readOnly = automatic && _readOnlyTaskQuestion(userInput);
    for (final row in root['updates'] as List) {
      if (row is! Map ||
          !((row.length == 3 && !row.containsKey('action')) ||
              (row.length == 4 && row['action'] == 'retire')) ||
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
          !seenUpdates.add(id)) {
        throw const FormatException('Task-state quote/identity invalid');
      }
      // Recovery/factual questions can only read state. Record the ignored
      // extractor rows in its audit; do not turn their mentions into values.
      if (readOnly) {
        ignored++;
        continue;
      }
      final retire = row['action'] == 'retire';
      final priorGoal = before.facts
          .where((f) => f.kind == RagTaskFactKind.goal)
          .firstOrNull;
      if (automatic &&
          kind == RagTaskFactKind.goal &&
          priorGoal != null &&
          (retire || quote != priorGoal.quote) &&
          !_explicitGoalChange(userInput, retire: retire)) {
        throw const FormatException(
          'Replacing a stored goal requires explicit goal-change wording',
        );
      }
      if (!retire) _validateChosenSlot(id, quote);
      if (retire && !before.facts.any((f) => f.id == id && f.kind == kind)) {
        throw const FormatException('Retirement requires an existing slot');
      }
      final previous = before.facts.where((f) => f.id == id).firstOrNull;
      if (automatic &&
          _ambiguousCompoundChange(previous, quote, retire, userInput)) {
        ignoredConstraints.add(id);
        continue;
      }
      updates.add(RagTaskUpdate(id, kind, quote, retire: retire));
    }
    final ids = {...before.facts.map((f) => f.id)};
    for (final u in updates) {
      if (u.retire) {
        ids.remove(u.id);
      } else {
        ids.add(u.id);
      }
    }
    if (ids.length > 24) throw const FormatException('Task-state capacity');
    if (ids.where((id) => id.startsWith('goal.')).length > 1) {
      throw const FormatException('Only one active task goal is supported');
    }
    return RagTaskPatch(
      updates,
      ignoredReadOnlyUpdates: ignored,
      ignoredAmbiguousConstraintIds: ignoredConstraints,
    );
  }

  RagTaskState apply(
    RagTaskState before, {
    required String userText,
    required String submissionId,
    String sourceKind = 'automatic_user_quote',
  }) {
    if (sourceKind == 'automatic_user_quote' &&
        _readOnlyTaskQuestion(userText)) {
      return before;
    }
    final active = {for (final fact in before.facts) fact.id: fact};
    final old = before.superseded.toList();
    final retired = before.retirements.toList();
    var changed = false;
    for (final update in updates) {
      if (!update.retire && active[update.id]?.quote == update.quote) continue;
      final previous = active[update.id];
      if (sourceKind == 'automatic_user_quote' &&
          _ambiguousCompoundChange(
            previous,
            update.quote,
            update.retire,
            userText,
          )) {
        throw const FormatException(
          'Replacing a compound constraint requires explicit full replacement',
        );
      }
      if (sourceKind == 'automatic_user_quote' &&
          previous?.kind == RagTaskFactKind.goal &&
          !_explicitGoalChange(userText, retire: update.retire)) {
        throw const FormatException(
          'Replacing a stored goal requires explicit goal-change wording',
        );
      }
      if (previous != null) old.add(previous);
      if (!update.retire) _validateChosenSlot(update.id, update.quote);
      final nextFact = RagTaskFact(
        id: update.id,
        kind: update.kind,
        quote: update.quote,
        userText: userText,
        submissionId: submissionId,
        sourceRevision: before.revision + 1,
        sourceKind: sourceKind,
      );
      nextFact.validate();
      if (update.retire) {
        active.remove(update.id);
        retired.add(nextFact);
      } else {
        active[update.id] = nextFact;
      }
      changed = true;
    }
    return changed
        ? RagTaskState(
            project: before.project,
            session: before.session,
            revision: before.revision + 1,
            facts: active.values,
            superseded: old,
            retirements: retired,
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

/// Conservative automatic goal lifecycle: factual diversions must never replace
/// the task goal. Other wording can be handled by explicit manual editing.
bool _explicitGoalChange(String input, {required bool retire}) {
  final pattern = retire
      ? r'^\s*(?:(?:remove|retire|forget) (?:our|my|the) goal\b|(?:сними|удали|забудь) (?:нашу |мою )?цель(?:\s|[:—-]|$))'
      : r'^\s*(?:(?:our|my) new goal is\b|(?:change|replace|set|update) (?:our|my|the) goal (?:to|with)\b|(?:наша |моя )?новая цель\s*[:—-]|(?:измени|поменяй|замени) (?:нашу |мою )?цель(?:\s|[:—-]|$))';
  return RegExp(pattern, caseSensitive: false, multiLine: true).hasMatch(input);
}

/// Recognizable requests to read/recover/explain existing conditions are never
/// permission to replace them. Explicit change statements should be separate.
bool _readOnlyTaskQuestion(String input) => RegExp(
  r'^\s*(?:return\b|after\s+(?:restart(?:ing)?|reopening)\b|recover\b|remind\b|what\b|how\b|why\b|when\b|where\b|which\b|(?:(?:brief|another)\s+)?diversion\b|unrelated(?:\s+documentation)?\s+question\b|new(?:\s+(?:source|paper))?\s+question\b|(?:вернись|вспомни|восстанови|напомни|как|почему|когда|где|какие|что)(?:\s|[:?]|$)|после\s+перезапуска)',
  caseSensitive: false,
).hasMatch(input);

/// A bounded lexical policy, not semantic entailment. A goal change or partial
/// reassertion must not silently replace a conjunction/list of restrictions.
/// Explicit whole-scope/constraint changes and manual editing are available.
bool _ambiguousCompoundChange(
  RagTaskFact? previous,
  String quote,
  bool retire,
  String userInput,
) {
  if (previous == null ||
      previous.kind != RagTaskFactKind.constraint ||
      (!retire && previous.quote == quote) ||
      !RegExp(
        r'(?:^|[\s,])(?:and|or|but|и|или|но)(?:[\s,]|$)|[;,\n]',
        caseSensitive: false,
      ).hasMatch(previous.quote)) {
    return false;
  }
  final verbs = retire ? 'remove|retire|forget' : 'replace|change|set|update';
  final russianVerbs = retire
      ? 'удали|сними|забудь'
      : 'замени|измени|поменяй|обнови|задай';
  final id = RegExp.escape(previous.id);
  return !RegExp(
    '^\\s*(?:(?:$verbs)\\s+(?:(?:our|my|the)\\s+)?(?:(?:whole|entire|full|all)\\s+)?(?:scope|constraints?|restrictions?|conditions?|$id)(?:\\s|[:—-]|\$)|(?:$russianVerbs)\\s+(?:(?:наши|мои|все|весь|полностью)\\s+)?(?:условия|ограничения|рамки|$id)(?:\\s|[:—-]|\$))',
    caseSensitive: false,
  ).hasMatch(userInput);
}
