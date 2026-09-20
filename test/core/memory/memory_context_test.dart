import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

MemoryReadPlanItem _item(
  String id, {
  MemoryLayer layer = MemoryLayer.working,
  MemoryReadReason reason = MemoryReadReason.workingPriority,
  String content = 'abc',
}) {
  return MemoryReadPlanItem(
    entryId: MemoryEntryId(id),
    revision: 0,
    layer: layer,
    scope: layer == MemoryLayer.working
        ? MemoryScope.project
        : MemoryScope.global,
    kind: layer == MemoryLayer.working
        ? MemoryKind.requirement
        : MemoryKind.fact,
    content: content,
    reason: reason,
  );
}

MemoryTraceRecord _record(
  String id, {
  bool included = true,
  MemoryLayer layer = MemoryLayer.working,
  MemoryReadReason reason = MemoryReadReason.workingPriority,
  List<String> sourceValues = const <String>['s1'],
}) {
  return MemoryTraceRecord(
    entryId: MemoryEntryId(id),
    revision: 0,
    layer: layer,
    scope: layer == MemoryLayer.working
        ? MemoryScope.project
        : MemoryScope.global,
    kind: layer == MemoryLayer.working
        ? MemoryKind.requirement
        : MemoryKind.fact,
    included: included,
    reason: reason,
    sourceIds: sourceValues.map(MemorySourceId.new).toList(),
  );
}

MemoryReadRequest _request({
  String query = '',
  int budget = 50,
  int maxLongTerm = 5,
  bool working = true,
  bool longTerm = true,
}) {
  return MemoryReadRequest(
    projectId: ProjectId('project-1'),
    query: query,
    characterBudget: budget,
    maxLongTermRecords: maxLongTerm,
    includeWorking: working,
    includeLongTerm: longTerm,
  );
}

void main() {
  group('MemoryReadRequest', () {
    test('applies documented defaults', () {
      final request = MemoryReadRequest(projectId: ProjectId('project-1'));
      expect(request.query, '');
      expect(request.characterBudget, defaultMemoryCharacterBudget);
      expect(request.maxLongTermRecords, defaultMaxLongTermRecords);
      expect(request.includeWorking, isTrue);
      expect(request.includeLongTerm, isTrue);
    });

    test('trims the query and validates bounds', () {
      expect(_request(query: '  retrieval rules ').query, 'retrieval rules');
      expect(
        () => _request(budget: 0),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _request(maxLongTerm: -1),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => _request(query: List<String>.filled(600, 'q').join()),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('round-trips through JSON', () {
      final request = _request(query: 'rules', budget: 100, maxLongTerm: 2);
      expect(MemoryReadRequest.fromJson(request.toJson()), request);
    });
  });

  group('MemoryReadPlan', () {
    test('accepts a deterministic, budgeted plan', () {
      final plan = MemoryReadPlan(
        request: _request(budget: 20),
        items: [_item('a'), _item('b')],
        trace: [
          _record('a'),
          _record('b'),
          _record('c', included: false, reason: MemoryReadReason.notSelected),
        ],
      );
      expect(plan.renderedCharacters, 6);
      expect(plan.budgetCharacters, 20);
      expect(plan.truncated, isFalse);
      expect(plan.items, hasLength(2));
      expect(plan.items.first.entryId.value, 'a');
    });

    test('rejects plans that exceed the budget', () {
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 5),
          items: [_item('a'), _item('b')],
          trace: [_record('a'), _record('b')],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('requires deterministic item and trace ordering', () {
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('b'), _item('a')],
          trace: [_record('a'), _record('b')],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a')],
          trace: [
            _record('a', included: false, reason: MemoryReadReason.notSelected),
            _record('a'),
          ],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a'), _item('a')],
          trace: [_record('a')],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('requires an included trace record for every item', () {
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a')],
          trace: [
            _record('a', included: false, reason: MemoryReadReason.notSelected),
          ],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('requires every included trace record to have an exact item', () {
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a')],
          trace: [_record('a'), _record('b')],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a')],
          trace: [_record('a', reason: MemoryReadReason.confirmedPreference)],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('rejects duplicate entry identities even across revisions', () {
      final secondRevision = MemoryReadPlanItem(
        entryId: MemoryEntryId('a'),
        revision: 1,
        layer: MemoryLayer.working,
        scope: MemoryScope.project,
        kind: MemoryKind.requirement,
        content: 'changed',
        reason: MemoryReadReason.workingPriority,
      );
      expect(
        () => MemoryReadPlan(
          request: _request(budget: 20),
          items: [_item('a'), secondRevision],
          trace: [_record('a')],
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('detects truncation from a budget-exceeded record', () {
      final plan = MemoryReadPlan(
        request: _request(budget: 20),
        items: [_item('a')],
        trace: [
          _record('a'),
          _record(
            'b',
            included: false,
            reason: MemoryReadReason.budgetExceeded,
          ),
        ],
      );
      expect(plan.truncated, isTrue);
      expect(plan.contextTrace.truncated, isTrue);
    });

    test('orders working before long-term and derives a context trace', () {
      final plan = MemoryReadPlan(
        request: _request(budget: 40),
        items: [
          _item('w1'),
          _item(
            'l1',
            layer: MemoryLayer.longTerm,
            reason: MemoryReadReason.confirmedPreference,
          ),
        ],
        trace: [
          _record('w1'),
          _record(
            'l1',
            layer: MemoryLayer.longTerm,
            reason: MemoryReadReason.confirmedPreference,
          ),
        ],
      );
      expect(plan.items.map((item) => item.entryId.value), <String>[
        'w1',
        'l1',
      ]);
      final trace = plan.contextTrace;
      expect(trace.renderedCharacters, plan.renderedCharacters);
      expect(trace.budgetCharacters, plan.budgetCharacters);
      expect(trace.includedRecords, hasLength(2));
      expect(trace.excludedRecords, isEmpty);
    });

    test('round-trips through JSON', () {
      final plan = MemoryReadPlan(
        request: _request(budget: 20),
        items: [_item('a')],
        trace: [_record('a')],
      );
      expect(MemoryReadPlan.fromJson(plan.toJson()), plan);
    });
  });

  group('MemoryContextTrace', () {
    test('validates budget and ordering', () {
      expect(
        () => MemoryContextTrace(
          records: [_record('a')],
          renderedCharacters: 5,
          budgetCharacters: 4,
          truncated: false,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryContextTrace(
          records: [
            _record(
              'a',
              included: false,
              reason: MemoryReadReason.budgetExceeded,
            ),
          ],
          renderedCharacters: 0,
          budgetCharacters: 10,
          truncated: false,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryContextTrace(
          records: [
            _record('a', included: false, reason: MemoryReadReason.notSelected),
            _record('a'),
          ],
          renderedCharacters: 3,
          budgetCharacters: 10,
          truncated: false,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryContextTrace(
          records: [_record('a')],
          renderedCharacters: 3,
          budgetCharacters: 0,
          truncated: false,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('round-trips through JSON', () {
      final trace = MemoryContextTrace(
        records: [_record('a')],
        renderedCharacters: 3,
        budgetCharacters: 10,
        truncated: false,
      );
      expect(MemoryContextTrace.fromJson(trace.toJson()), trace);
    });
  });
}
