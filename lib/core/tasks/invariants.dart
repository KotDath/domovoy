enum TaskInvariantScope { project, task }

enum TaskInvariantCategory {
  architecture,
  technicalDecision,
  stack,
  businessRule,
  custom,
}

enum TaskInvariantChecker {
  requiredTerms,
  forbiddenTerms,
  maximumCharacters,
  semantic,
}

final class TaskInvariantRule {
  TaskInvariantRule({
    required this.id,
    required this.scope,
    required this.category,
    required this.description,
    required this.checker,
    List<String> terms = const <String>[],
    this.maximumCharacters,
    this.active = true,
    this.revision = 1,
  }) : terms = List<String>.unmodifiable(terms) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (description.trim().isEmpty) {
      throw ArgumentError.value(description, 'description');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if ((checker == TaskInvariantChecker.requiredTerms ||
            checker == TaskInvariantChecker.forbiddenTerms) &&
        this.terms.isEmpty) {
      throw ArgumentError('Term-based invariant requires at least one term.');
    }
    if (checker == TaskInvariantChecker.maximumCharacters &&
        (maximumCharacters == null || maximumCharacters! < 1)) {
      throw ArgumentError(
        'Maximum-character invariant requires a positive limit.',
      );
    }
  }

  final String id;
  final TaskInvariantScope scope;
  final TaskInvariantCategory category;
  final String description;
  final TaskInvariantChecker checker;
  final List<String> terms;
  final int? maximumCharacters;
  final bool active;
  final int revision;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'scope': scope.name,
    'category': category.name,
    'description': description,
    'checker': checker.name,
    'terms': terms,
    'maximumCharacters': maximumCharacters,
    'active': active,
    'revision': revision,
  };

  factory TaskInvariantRule.fromJson(Map<String, Object?> json) {
    return TaskInvariantRule(
      id: json['id']! as String,
      scope: TaskInvariantScope.values.byName(json['scope']! as String),
      category: TaskInvariantCategory.values.byName(
        json['category']! as String,
      ),
      description: json['description']! as String,
      checker: TaskInvariantChecker.values.byName(json['checker']! as String),
      terms: (json['terms']! as List<Object?>).cast<String>(),
      maximumCharacters: json['maximumCharacters'] as int?,
      active: json['active']! as bool,
      revision: json['revision']! as int,
    );
  }
}

final class TaskInvariantViolation {
  const TaskInvariantViolation({required this.ruleId, required this.reason});

  final String ruleId;
  final String reason;
}

final class TaskInvariantCheck {
  TaskInvariantCheck({
    List<TaskInvariantViolation> violations = const <TaskInvariantViolation>[],
    List<TaskInvariantRule> semanticRules = const <TaskInvariantRule>[],
  }) : violations = List<TaskInvariantViolation>.unmodifiable(violations),
       semanticRules = List<TaskInvariantRule>.unmodifiable(semanticRules);

  final List<TaskInvariantViolation> violations;
  final List<TaskInvariantRule> semanticRules;

  bool get isAllowed => violations.isEmpty;
}

final class DeterministicTaskInvariantChecker {
  const DeterministicTaskInvariantChecker();

  TaskInvariantCheck check(
    String candidate,
    Iterable<TaskInvariantRule> rules,
  ) {
    final normalized = candidate.toLowerCase();
    final violations = <TaskInvariantViolation>[];
    final semantic = <TaskInvariantRule>[];
    for (final rule in rules.where((rule) => rule.active)) {
      switch (rule.checker) {
        case TaskInvariantChecker.requiredTerms:
          final missing = rule.terms
              .where((term) => !normalized.contains(term.toLowerCase()))
              .toList(growable: false);
          if (missing.isNotEmpty) {
            violations.add(
              TaskInvariantViolation(
                ruleId: rule.id,
                reason:
                    'Отсутствуют обязательные элементы: ${missing.join(', ')}.',
              ),
            );
          }
        case TaskInvariantChecker.forbiddenTerms:
          final found = rule.terms
              .where((term) => normalized.contains(term.toLowerCase()))
              .toList(growable: false);
          if (found.isNotEmpty) {
            violations.add(
              TaskInvariantViolation(
                ruleId: rule.id,
                reason: 'Обнаружены запрещённые элементы: ${found.join(', ')}.',
              ),
            );
          }
        case TaskInvariantChecker.maximumCharacters:
          if (candidate.length > rule.maximumCharacters!) {
            violations.add(
              TaskInvariantViolation(
                ruleId: rule.id,
                reason:
                    'Длина ${candidate.length} превышает лимит '
                    '${rule.maximumCharacters}.',
              ),
            );
          }
        case TaskInvariantChecker.semantic:
          semantic.add(rule);
      }
    }
    return TaskInvariantCheck(violations: violations, semanticRules: semantic);
  }
}
