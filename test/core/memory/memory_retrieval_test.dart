import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

MemoryReadRequest _request({
  String query = '',
  int budget = defaultMemoryCharacterBudget,
  int maxLongTerm = defaultMaxLongTermRecords,
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
  final open = CancellationSource().token;

  Future<LayeredMemoryRetrievalService> service({
    List<MemoryEntry> working = const <MemoryEntry>[],
    List<MemoryEntry> longTerm = const <MemoryEntry>[],
    List<MemoryCandidate> candidates = const <MemoryCandidate>[],
  }) async {
    final workingRepo = InMemoryMemoryEntryRepository(
      layer: MemoryLayer.working,
    );
    final longTermRepo = InMemoryMemoryEntryRepository(
      layer: MemoryLayer.longTerm,
    );
    for (final entry in working) {
      await workingRepo.save(entry, expectedRevision: 0, cancellation: open);
    }
    for (final entry in longTerm) {
      await longTermRepo.save(entry, expectedRevision: 0, cancellation: open);
    }
    final candidateRepo = InMemoryMemoryCandidateRepository();
    for (final candidate in candidates) {
      await candidateRepo.save(
        candidate,
        expectedRevision: 0,
        cancellation: open,
      );
    }
    return LayeredMemoryRetrievalService(
      repositories: MemoryRepositories(
        workingRepository: workingRepo,
        longTermRepository: longTermRepo,
        candidateRepository: candidateRepo,
      ),
    );
  }

  group('LayeredMemoryRetrievalService', () {
    test('supplies working before long-term with an exact trace', () async {
      final retrieval = await service(
        working: <MemoryEntry>[workingEntry(id: 'w1')],
        longTerm: <MemoryEntry>[
          longTermEntry(
            id: 'p1',
            kind: MemoryKind.preference,
            content: 'Prefers concise answers.',
          ),
        ],
      );
      final plan = await retrieval.planRead(_request());
      expect(plan.items.map((item) => item.entryId.value), <String>[
        'w1',
        'p1',
      ]);
      expect(plan.items.map((item) => item.reason), <MemoryReadReason>[
        MemoryReadReason.workingPriority,
        MemoryReadReason.confirmedPreference,
      ]);
      expect(plan.truncated, isFalse);
      final trace = plan.contextTrace;
      expect(trace.includedRecords, hasLength(2));
      expect(trace.excludedRecords, isEmpty);
      expect(
        trace.includedRecords.map((record) => record.sourceIds),
        everyElement(isNotEmpty),
      );
      expect(trace.renderedCharacters, plan.renderedCharacters);
    });

    test('never crosses working-memory project boundaries', () async {
      final retrieval = await service(
        working: <MemoryEntry>[
          workingEntry(id: 'current', project: 'project-1'),
          workingEntry(id: 'other', project: 'project-2'),
        ],
      );
      final plan = await retrieval.planRead(_request());
      expect(plan.items.map((item) => item.entryId.value), <String>['current']);
      expect(plan.trace.map((record) => record.entryId.value), <String>[
        'current',
      ]);
    });

    test('ranks long-term facts lexically and traces the rest', () async {
      final retrieval = await service(
        longTerm: <MemoryEntry>[
          longTermEntry(
            id: 'p0',
            kind: MemoryKind.preference,
            content: 'Prefers dark mode.',
          ),
          longTermEntry(
            id: 'f1',
            kind: MemoryKind.fact,
            content: 'Deployment uses kubernetes clusters.',
          ),
          longTermEntry(
            id: 'f2',
            kind: MemoryKind.fact,
            content: 'Design uses figma files.',
          ),
          longTermEntry(
            id: 'f3',
            kind: MemoryKind.fact,
            content: 'Billing uses stripe invoices.',
          ),
        ],
      );
      final plan = await retrieval.planRead(
        _request(query: 'kubernetes deployment', maxLongTerm: 1),
      );
      expect(plan.items.map((item) => item.entryId.value), <String>[
        'p0',
        'f1',
      ]);
      expect(plan.items[1].reason, MemoryReadReason.lexicalMatch);
      final excluded = plan.contextTrace.excludedRecords;
      expect(excluded.map((record) => record.entryId.value).toSet(), <String>{
        'f2',
        'f3',
      });
      expect(
        excluded.every(
          (record) => record.reason == MemoryReadReason.notSelected,
        ),
        isTrue,
      );
    });

    test(
      'does not inject long-term records with a zero lexical score',
      () async {
        final retrieval = await service(
          longTerm: <MemoryEntry>[
            longTermEntry(
              id: 'unrelated',
              kind: MemoryKind.fact,
              content: 'Billing uses stripe invoices.',
            ),
          ],
        );
        final plan = await retrieval.planRead(
          _request(query: 'kubernetes deployment'),
        );
        expect(plan.items, isEmpty);
        expect(plan.trace.single.included, isFalse);
        expect(plan.trace.single.reason, MemoryReadReason.notSelected);
      },
    );

    test('traces disabled layers without including them', () async {
      final retrieval = await service(
        working: <MemoryEntry>[workingEntry()],
        longTerm: <MemoryEntry>[
          longTermEntry(kind: MemoryKind.fact, content: 'A global fact.'),
        ],
      );
      final plan = await retrieval.planRead(
        _request(working: false, longTerm: false),
      );
      expect(plan.items, isEmpty);
      expect(
        plan.contextTrace.records.where(
          (record) => record.reason == MemoryReadReason.layerDisabled,
        ),
        hasLength(2),
      );
      expect(plan.truncated, isFalse);
    });

    test('excludes forgotten entries with provenance in the trace', () async {
      final retrieval = await service(
        working: <MemoryEntry>[
          workingEntry(id: 'gone', status: MemoryEntryStatus.forgotten),
          workingEntry(id: 'live'),
        ],
      );
      final plan = await retrieval.planRead(_request());
      expect(plan.items.map((item) => item.entryId.value), <String>['live']);
      final forgotten = plan.contextTrace.records.singleWhere(
        (record) => record.entryId.value == 'gone',
      );
      expect(forgotten.included, isFalse);
      expect(forgotten.reason, MemoryReadReason.forgotten);
      expect(forgotten.sourceIds, isNotEmpty);
    });

    test('enforces the character budget and reports truncation', () async {
      final entries = <MemoryEntry>[
        for (var index = 0; index < 10; index += 1)
          workingEntry(
            id: 'w$index',
            content: List<String>.generate(20, (word) => 'word$word').join(' '),
          ),
      ];
      final retrieval = await service(working: entries);
      final plan = await retrieval.planRead(_request(budget: 400));
      expect(plan.items, isNotEmpty);
      expect(plan.items.length, lessThan(entries.length));
      expect(plan.truncated, isTrue);
      expect(
        plan.contextTrace.records.where(
          (record) => record.reason == MemoryReadReason.budgetExceeded,
        ),
        isNotEmpty,
      );
      expect(renderMemoryBlock(plan).runes.length, lessThanOrEqualTo(400));
    });

    test('preferences ignore the long-term cap', () async {
      final retrieval = await service(
        longTerm: <MemoryEntry>[
          longTermEntry(
            id: 'p0',
            kind: MemoryKind.preference,
            content: 'Prefers concise answers.',
          ),
          longTermEntry(
            id: 'f0',
            kind: MemoryKind.fact,
            content: 'A global fact.',
          ),
        ],
      );
      final plan = await retrieval.planRead(_request(maxLongTerm: 0));
      expect(plan.items.map((item) => item.entryId.value), <String>['p0']);
      expect(
        plan.contextTrace.excludedRecords.single.reason,
        MemoryReadReason.notSelected,
      );
    });

    test('never returns candidates', () async {
      final retrieval = await service(
        candidates: <MemoryCandidate>[
          createCandidate(content: 'Deployment uses kubernetes clusters.'),
        ],
      );
      final plan = await retrieval.planRead(_request(query: 'kubernetes'));
      expect(plan.items, isEmpty);
      expect(plan.contextTrace.records, isEmpty);
    });

    test('is deterministic across repeated planning', () async {
      final retrieval = await service(
        working: <MemoryEntry>[workingEntry(id: 'w1')],
        longTerm: <MemoryEntry>[
          longTermEntry(
            id: 'f1',
            kind: MemoryKind.fact,
            content: 'Deployment uses kubernetes clusters.',
          ),
        ],
      );
      final first = await retrieval.planRead(_request(query: 'kubernetes'));
      final second = await retrieval.planRead(_request(query: 'kubernetes'));
      expect(first, second);
    });
  });
}
