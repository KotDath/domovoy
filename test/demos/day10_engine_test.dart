import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/demos/day10_engine.dart';
import 'package:domovoy/demos/day10_live_invoker.dart';
import 'package:domovoy/demos/day10_memory.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStore implements Day10StateStore {
  String? value;
  int writes = 0;
  int? failWriteAt;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async {
    writes++;
    if (writes == failWriteAt) throw StateError('disk unavailable');
    value = data;
  }

  @override
  Future<void> clear() async => value = null;
}

final class _Call {
  const _Call(
    this.branch,
    this.role,
    this.prompt,
    this.seed,
    this.systemPrompt,
  );
  final String branch;
  final String role;
  final String prompt;
  final List<LlmMessage> seed;
  final String systemPrompt;
}

final class _Invoker implements Day10Invoker {
  final calls = <_Call>[];
  bool failNext = false;
  bool invalidMemoryOnce = false;
  bool failMainOnce = false;
  @override
  Future<Day10CallResult> call({
    required Day10Branch branch,
    required String role,
    required String prompt,
    required List<LlmMessage> initialMessages,
    required String systemPrompt,
  }) async {
    calls.add(_Call(branch.label, role, prompt, initialMessages, systemPrompt));
    if (failNext) {
      failNext = false;
      return Day10CallResult(
        answer: '',
        outcome: 'failed',
        physical: [Day10Physical(LlmUsage(), 'failed')],
        error: 'Provider error',
      );
    }
    if (role == 'memory') {
      if (invalidMemoryOnce) {
        invalidMemoryOnce = false;
        return Day10CallResult(
          answer: '{"operations":[{"op":"add"}]}',
          outcome: 'completed',
          physical: [
            Day10Physical(
              LlmUsage(inputTokens: 7, outputTokens: 3, totalTokens: 10),
              'completed',
            ),
          ],
        );
      }
      final payload = jsonDecode(prompt) as Map;
      final currentUser = payload['newUserMessage'] as Map;
      final message = currentUser['text'] as String;
      final source = currentUser['id'] as String;
      final existing = payload['currentFacts'] as List;
      final ops = <Map<String, Object?>>[];
      if (message.contains('Север') && existing.isEmpty) {
        ops.addAll([
          {
            'op': 'add',
            'key': 'Проект',
            'value': 'Север',
            'sourceMessageIds': [source],
          },
          {
            'op': 'add',
            'key': 'Бюджет',
            'value': '120000',
            'sourceMessageIds': [source],
          },
        ]);
      }
      if (message.contains('150000')) {
        final old = existing.cast<Map>().firstWhere(
          (fact) => fact['key'] == 'Бюджет',
        );
        ops.add({
          'op': 'update',
          'id': old['id'],
          'key': 'Бюджет',
          'value': '150000',
          'sourceMessageIds': [source],
        });
      }
      return Day10CallResult(
        answer: jsonEncode({'operations': ops}),
        outcome: 'completed',
        physical: [
          Day10Physical(
            LlmUsage(inputTokens: 7, outputTokens: 3, totalTokens: 10),
            'completed',
          ),
        ],
      );
    }
    if (failMainOnce) {
      failMainOnce = false;
      return Day10CallResult(
        answer: '',
        outcome: 'failed',
        physical: [Day10Physical(LlmUsage(), 'failed')],
        error: 'main failed',
      );
    }
    return Day10CallResult(
      answer: 'Ответ ${calls.length}',
      outcome: 'completed',
      physical: [
        Day10Physical(
          LlmUsage(
            inputTokens: 10,
            outputTokens: 2,
            totalTokens: 12,
            cacheHitTokens: 4,
          ),
          'completed',
        ),
      ],
    );
  }
}

Future<List<Day10Prompt>> _scenario() async => Day10Prompt.parse(
  await rootBundle.loadString('assets/day10_scenario.json'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared scenario has fourteen ordered real prompts', () async {
    final prompts = await _scenario();
    expect(prompts.length, 14);
    expect(prompts.first.prompt, contains('Север'));
    expect(prompts[7].prompt, contains('150000'));
    expect(prompts.last.title, 'Итоговое ТЗ');
  });

  test('sliding request drops older complete pairs', () async {
    final invoker = _Invoker();
    final engine = Day10DemoEngine(
      prompts: await _scenario(),
      invoker: invoker,
      store: _MemoryStore(),
      newId: _ids(),
    );
    await engine.initialize();
    for (var i = 0; i < 4; i++) {
      await engine.runNextComparison();
    }
    final fourth = invoker.calls
        .where(
          (call) =>
              call.branch == Day10Strategy.sliding.label && call.role == 'main',
        )
        .elementAt(3);
    expect(fourth.seed.length, 4);
    expect(_seedText(fourth.seed), isNot(contains('Проект: Север')));
    expect(_seedText(fourth.seed), contains('В форме записи'));
    expect(engine.branches['sliding']!.pairs.length, 4);
  });

  test(
    'facts replace the old budget before dispatch and survive reload',
    () async {
      final store = _MemoryStore();
      final invoker = _Invoker();
      final prompts = await _scenario();
      final engine = Day10DemoEngine(
        prompts: prompts,
        invoker: invoker,
        store: store,
        newId: _ids(),
      );
      await engine.initialize();
      for (var i = 0; i < 8; i++) {
        await engine.runNextComparison();
      }
      final eighth = invoker.calls
          .where(
            (call) =>
                call.branch == Day10Strategy.facts.label && call.role == 'main',
          )
          .elementAt(7);
      expect(eighth.systemPrompt, contains('150000'));
      expect(eighth.systemPrompt, isNot(contains('120000')));
      expect(
        engine.branches['facts']!.facts
            .firstWhere((fact) => fact.key == 'Проект')
            .value,
        'Север',
      );
      expect(
        engine.branches['facts']!.facts
            .firstWhere((fact) => fact.key == 'Бюджет')
            .value,
        '150000',
      );
      final restored = Day10DemoEngine(
        prompts: prompts,
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await restored.initialize();
      expect(
        restored.branches['facts']!.facts
            .firstWhere((fact) => fact.key == 'Бюджет')
            .value,
        '150000',
      );
      expect(restored.comparisonStep, 8);
    },
  );

  test('checkpoint branches isolate continuations and new spend', () async {
    final store = _MemoryStore();
    final invoker = _Invoker();
    final prompts = await _scenario();
    final engine = Day10DemoEngine(
      prompts: prompts,
      invoker: invoker,
      store: store,
      newId: _ids(),
    );
    await engine.initialize();
    for (var i = 0; i < 8; i++) {
      await engine.runNextComparison();
    }
    expect(engine.hasCheckpoint, isTrue);
    final parent = engine.branches['branching']!;
    expect(parent.pairs.length, 8);
    await engine.runBranchPrompt('a');
    await engine.runBranchPrompt('b');
    await engine.runBranchCheck('a');
    await engine.runBranchCheck('b');
    final a = engine.branches['a']!;
    final b = engine.branches['b']!;
    expect(a.parentId, parent.id);
    expect(b.parentId, parent.id);
    expect(a.checkpointStep, 8);
    expect(a.inheritedInvocationCount, 8);
    expect(a.pairs.length, 10);
    expect(b.pairs.length, 10);
    expect(parent.pairs.length, 8);
    expect(a.invocations.length, 2);
    expect(a.newSpend.overall.value, 24);
    expect(b.newSpend.overall.value, 24);
    expect(
      a.invocations
          .map((row) => row.id)
          .toSet()
          .intersection(b.invocations.map((row) => row.id).toSet()),
      isEmpty,
    );
    final aCheck = invoker.calls.lastWhere(
      (call) =>
          call.branch == 'Ветка A' && call.prompt.startsWith('Что добавлено'),
    );
    final bCheck = invoker.calls.lastWhere(
      (call) =>
          call.branch == 'Ветка B' && call.prompt.startsWith('Что добавлено'),
    );
    expect(_seedText(aCheck.seed), contains('лист ожидания'));
    expect(_seedText(aCheck.seed), isNot(contains('семейные записи')));
    expect(_seedText(bCheck.seed), contains('семейные записи'));
    expect(_seedText(bCheck.seed), isNot(contains('лист ожидания')));
    final restored = Day10DemoEngine(
      prompts: prompts,
      invoker: _Invoker(),
      store: store,
      newId: _ids(),
    );
    await restored.initialize();
    expect(restored.branches['a']!.parentId, parent.id);
    expect(restored.branches['a']!.newSpend.overall.value, 24);
    expect(restored.branches['b']!.branchExtraStep, 2);
  });

  test(
    'failed physical attempt with no usage remains unknown and durable',
    () async {
      final store = _MemoryStore();
      final invoker = _Invoker()..failNext = true;
      final prompts = await _scenario();
      final engine = Day10DemoEngine(
        prompts: prompts,
        invoker: invoker,
        store: store,
        newId: _ids(),
      );
      await engine.initialize();
      await engine.runNextComparison();
      expect(engine.comparisonStep, 0);
      final row = engine.branches['sliding']!.invocations.single;
      expect(row.outcome, 'failed');
      expect(row.usage.overall, isNull);
      final restored = Day10DemoEngine(
        prompts: prompts,
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await restored.initialize();
      expect(
        restored.branches['sliding']!.invocations.single.usage.overall,
        isNull,
      );
    },
  );

  test(
    'selected strategy advances alone, forks at step eight, and reloads',
    () async {
      final prompts = await _scenario();
      final store = _MemoryStore();
      final engine = Day10DemoEngine(
        prompts: prompts,
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await engine.initialize();
      await engine.selectStrategy(Day10Strategy.branching);
      for (var i = 0; i < 8; i++) {
        await engine.runNextSelected();
      }
      expect(engine.branches['branching']!.scenarioStep, 8);
      expect(engine.branches['sliding']!.scenarioStep, 0);
      expect(engine.branches['facts']!.scenarioStep, 0);
      expect(engine.hasCheckpoint, isTrue);
      expect(engine.branches['a']!.pairs.length, 8);
      final restored = Day10DemoEngine(
        prompts: prompts,
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await restored.initialize();
      expect(restored.selectedStrategy, Day10Strategy.branching);
      expect(restored.hasCheckpoint, isTrue);
      await restored.runNextComparison();
      expect(restored.branches['sliding']!.scenarioStep, 1);
      expect(restored.branches['facts']!.scenarioStep, 1);
      expect(restored.branches['branching']!.scenarioStep, 8);
      await restored.runAll();
      expect(restored.comparisonStep, 14);
    },
  );

  test('run-all feeds identical fourteen prompts to each strategy', () async {
    final prompts = await _scenario();
    final invoker = _Invoker();
    final engine = Day10DemoEngine(
      prompts: prompts,
      invoker: invoker,
      store: _MemoryStore(),
      newId: _ids(),
    );
    await engine.initialize();
    await engine.runAll();
    expect(engine.comparisonStep, 14);
    for (final strategy in Day10Strategy.values) {
      expect(
        engine.branches[strategy.name]!.pairs.map((pair) => pair.user),
        prompts.map((prompt) => prompt.prompt),
      );
      expect(
        engine.branches[strategy.name]!.newSpend.overall.value,
        strategy == Day10Strategy.facts ? 308 : 168,
      );
    }
  });

  test('memory edits are atomic, sourced, and preserve unchanged facts', () {
    const source = 'user-new';
    const existing = [
      Day10Fact('budget-id', 'Бюджет', '120000', ['user-old']),
      Day10Fact('name-id', 'Проект', 'Север', ['user-old']),
      Day10Fact('report-id', 'Отчёт', 'Тетрадь', ['user-old']),
    ];
    final proposal = Day10Memory.validate(
      jsonEncode({
        'operations': [
          {
            'op': 'update',
            'id': 'budget-id',
            'key': 'Бюджет',
            'value': '150000',
            'sourceMessageIds': [source],
          },
          {
            'op': 'delete',
            'id': 'report-id',
            'sourceMessageIds': [source],
          },
          {
            'op': 'add',
            'key': 'Интерфейс',
            'value': 'русский язык',
            'sourceMessageIds': [source],
          },
        ],
      }),
      current: existing,
      currentUserId: source,
      suppliedIds: {source, 'user-old'},
      newId: () => 'new-fact',
    );
    expect(
      proposal.facts.map((f) => f.id),
      containsAll(['budget-id', 'name-id', 'new-fact']),
    );
    expect(proposal.facts.where((f) => f.id == 'report-id'), isEmpty);
    expect(
      proposal.facts.firstWhere((f) => f.id == 'budget-id').value,
      '150000',
    );
    expect(proposal.facts.firstWhere((f) => f.id == 'name-id').value, 'Север');
    expect(proposal.edits.map((e) => e.operation), ['update', 'delete', 'add']);
    expect(
      () => Day10Memory.validate(
        jsonEncode({
          'operations': [
            {
              'op': 'update',
              'id': 'budget-id',
              'key': 'Бюджет',
              'value': '999999',
              'sourceMessageIds': ['user-old'],
            },
          ],
        }),
        current: existing,
        currentUserId: source,
        suppliedIds: {source, 'user-old'},
        newId: () => 'new',
      ),
      throwsFormatException,
    );
    expect(existing.first.value, '120000');
  });

  test('invalid extraction gets one repair and both attempts count', () async {
    final store = _MemoryStore();
    final invoker = _Invoker()..invalidMemoryOnce = true;
    final engine = Day10DemoEngine(
      prompts: await _scenario(),
      invoker: invoker,
      store: store,
      newId: _ids(),
    );
    await engine.initialize();
    await engine.selectStrategy(Day10Strategy.facts);
    await engine.runNextSelected();
    final branch = engine.branches['facts']!;
    expect(branch.scenarioStep, 1);
    expect(branch.invocations.map((row) => row.role), [
      'memory',
      'memory',
      'main',
    ]);
    expect(branch.spendFor('memory').overall.value, 20);
    final second = invoker.calls.where((call) => call.role == 'memory').last;
    expect(second.prompt, contains('previousInvalidOutput'));
    expect(
      branch.facts.firstWhere((fact) => fact.key == 'Проект').value,
      'Север',
    );
  });

  test(
    'main failure retries the same processed message without memory call',
    () async {
      final store = _MemoryStore();
      final invoker = _Invoker()..failMainOnce = true;
      final prompts = await _scenario();
      final engine = Day10DemoEngine(
        prompts: prompts,
        invoker: invoker,
        store: store,
        newId: _ids(),
      );
      await engine.initialize();
      await engine.selectStrategy(Day10Strategy.facts);
      await engine.runNextSelected();
      expect(engine.branches['facts']!.scenarioStep, 0);
      expect(engine.branches['facts']!.facts, isNotEmpty);
      final restored = Day10DemoEngine(
        prompts: prompts,
        invoker: invoker,
        store: store,
        newId: _ids(),
      );
      await restored.initialize();
      await restored.runNextSelected();
      expect(restored.branches['facts']!.scenarioStep, 1);
      expect(invoker.calls.where((call) => call.role == 'memory').length, 1);
      expect(restored.branches['facts']!.factEdits.length, 2);
    },
  );

  test('memory storage failure rolls back facts and stops main call', () async {
    final store = _MemoryStore()..failWriteAt = 2;
    final invoker = _Invoker();
    final engine = Day10DemoEngine(
      prompts: await _scenario(),
      invoker: invoker,
      store: store,
      newId: _ids(),
    );
    await engine.initialize();
    await engine.selectStrategy(Day10Strategy.facts); // This is write 1.
    store.failWriteAt = store.writes + 2; // Ledger write, then fact commit.
    await engine.runNextSelected();
    expect(engine.branches['facts']!.facts, isEmpty);
    expect(engine.branches['facts']!.factEdits, isEmpty);
    expect(engine.branches['facts']!.scenarioStep, 0);
    expect(invoker.calls.where((call) => call.role == 'main'), isEmpty);
  });

  test('both roles use exactly one non-default model and reasoning config', () {
    final generation = LlmGenerationConfig(
      reasoningMode: ReasoningMode.enabled,
      reasoningEffort: ReasoningEffort.high,
      maxOutputTokens: 1536,
    );
    final config = Day10AgentConfig(
      model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
      generation: generation,
    );
    final branch = Day10Branch(
      id: 'test',
      label: 'Facts',
      strategy: Day10Strategy.facts,
    );
    final main = config.definitionFor(
      branch: branch,
      role: 'main',
      initialMessages: const [],
      systemPrompt: 'answer',
    );
    final memory = config.definitionFor(
      branch: branch,
      role: 'memory',
      initialMessages: const [],
      systemPrompt: 'extract',
    );
    expect(main.model, memory.model);
    expect(main.generation, same(memory.generation));
    expect(memory.generation.reasoningMode, ReasoningMode.enabled);
    expect(memory.generation.reasoningEffort, ReasoningEffort.high);
    expect(main.model, BuiltInLlmCatalog.deepSeekV4ProModel.ref);
  });

  test(
    'version one explicit-parser state resets instead of posing as memory',
    () async {
      final store = _MemoryStore()
        ..value = jsonEncode({
          'version': 1,
          'branches': {},
          'activeBranch': 'facts',
        });
      final engine = Day10DemoEngine(
        prompts: await _scenario(),
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await engine.initialize();
      expect(engine.status, contains('несовместимо'));
      expect(engine.branches['facts']!.facts, isEmpty);
      expect(engine.comparisonStep, 0);
    },
  );
}

String _seedText(List<LlmMessage> messages) => messages
    .expand((message) => message.parts.whereType<LlmTextPart>())
    .map((part) => part.text)
    .join('\n');

String Function() _ids() {
  var next = 0;
  return () => 'test-branch-${++next}';
}
