import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/demos/day10_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStore implements Day10StateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async => value = data;
  @override
  Future<void> clear() async => value = null;
}

final class _Call {
  const _Call(this.branch, this.prompt, this.seed, this.systemPrompt);
  final String branch;
  final String prompt;
  final List<LlmMessage> seed;
  final String systemPrompt;
}

final class _Invoker implements Day10Invoker {
  final calls = <_Call>[];
  bool failNext = false;
  @override
  Future<Day10CallResult> call({
    required Day10Branch branch,
    required String prompt,
    required List<LlmMessage> initialMessages,
    required String systemPrompt,
  }) async {
    calls.add(_Call(branch.label, prompt, initialMessages, systemPrompt));
    if (failNext) {
      failNext = false;
      return Day10CallResult(
        answer: '',
        outcome: 'failed',
        physical: [Day10Physical(LlmUsage(), 'failed')],
        error: 'Provider error',
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
    expect(prompts.first.prompt, contains('Проект: Север'));
    expect(prompts[7].prompt, contains('Бюджет: 150000'));
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
        .where((call) => call.branch == Day10Strategy.sliding.label)
        .elementAt(3);
    expect(fourth.seed.length, 4);
    expect(_seedText(fourth.seed), isNot(contains('Проект: Север')));
    expect(_seedText(fourth.seed), contains('Форма записи'));
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
          .where((call) => call.branch == Day10Strategy.facts.label)
          .elementAt(7);
      expect(eighth.systemPrompt, contains('Бюджет: 150000'));
      expect(eighth.systemPrompt, isNot(contains('120000')));
      expect(engine.branches['facts']!.facts['Проект'], 'Север');
      expect(engine.branches['facts']!.facts['Бюджет'], '150000');
      final restored = Day10DemoEngine(
        prompts: prompts,
        invoker: _Invoker(),
        store: store,
        newId: _ids(),
      );
      await restored.initialize();
      expect(restored.branches['facts']!.facts['Бюджет'], '150000');
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
      expect(engine.branches[strategy.name]!.newSpend.overall.value, 168);
    }
  });
}

String _seedText(List<LlmMessage> messages) => messages
    .expand((message) => message.parts.whereType<LlmTextPart>())
    .map((part) => part.text)
    .join('\n');

String Function() _ids() {
  var next = 0;
  return () => 'test-branch-${++next}';
}
