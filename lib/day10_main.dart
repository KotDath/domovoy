import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/agents/agents.dart';
import 'core/llm/llm.dart';
import 'demos/day10_engine.dart';
import 'demos/day10_live_invoker.dart';
import 'demos/demo_dependencies.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(Day10DemoApp(dependencies: DemoDependencies.diagnostic()));
}

class Day10DemoApp extends StatefulWidget {
  const Day10DemoApp({required this.dependencies, super.key});
  final DemoDependencies dependencies;

  @override
  State<Day10DemoApp> createState() => _Day10DemoAppState();
}

class _Day10DemoAppState extends State<Day10DemoApp> {
  Day10DemoEngine? _engine;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final json = await rootBundle.loadString('assets/day10_scenario.json');
      final engine = Day10DemoEngine(
        prompts: Day10Prompt.parse(json),
        invoker: Day10LiveInvoker(widget.dependencies),
        store: SharedPreferencesDay10Store(),
      );
      await engine.initialize();
      if (mounted) setState(() => _engine = engine);
    } on Object {
      if (mounted) {
        setState(() => _loadError = 'Не удалось загрузить сценарий Day 10.');
      }
    }
  }

  @override
  void dispose() {
    _engine?.dispose();
    unawaited(widget.dependencies.close());
    super.dispose();
  }

  String _dimension(AgentUsageDimensionAggregate metric) {
    if (metric.contributorCount == 0 ||
        metric.completeness == LlmUsageCompleteness.unavailable) {
      return '—';
    }
    return metric.completeness == LlmUsageCompleteness.partial
        ? '${metric.knownSubtotal}+'
        : '${metric.knownSubtotal}';
  }

  Widget _usage(Day10Branch branch) {
    final total = branch.newSpend;
    final cache = total.cacheHitRatio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Новые вызовы API: ${branch.invocations.length}; '
          'ввод ${_dimension(total.requestContext)}, '
          'вывод ${_dimension(total.responseGenerated)}, '
          'всего ${_dimension(total.overall)}',
        ),
        Text(
          'Кэш чтение ${_dimension(total.cacheRead)}, '
          'запись ${_dimension(total.cacheWrite)}, '
          'попадание ${cache == null ? '—' : '${(cache.value * 100).toStringAsFixed(1)}%'}',
        ),
      ],
    );
  }

  Widget _strategyCard(BuildContext appContext, Day10Branch branch) {
    final last = branch.pairs.isEmpty ? null : branch.pairs.last;
    final isFinal = branch.parentId == null && branch.scenarioStep == 14;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              branch.label,
              style: Theme.of(appContext).textTheme.titleMedium,
            ),
            Text(
              'Шаг ${branch.scenarioStep}/14 · полная видимая история: '
              '${branch.pairs.length} пар · следующий запрос получит '
              '${branch.requestPairs.length} пар',
            ),
            if (branch.parentId != null)
              Text(
                'Родитель: ${branch.parentId} · checkpoint: '
                '${branch.checkpointStep} · унаследовано вызовов: '
                '${branch.inheritedInvocationCount}; ниже только новый расход.',
              ),
            if (branch.strategy == Day10Strategy.facts) ...[
              const SizedBox(height: 6),
              const Text('Явно сохранённые факты:'),
              SelectableText(
                branch.facts.isEmpty
                    ? '—'
                    : branch.facts.entries
                          .map((entry) => '${entry.key}: ${entry.value}')
                          .join('\n'),
              ),
            ],
            const SizedBox(height: 8),
            _usage(branch),
            if (last != null) ...[
              const SizedBox(height: 8),
              Text(isFinal ? 'Итоговое ТЗ:' : 'Последний ответ:'),
              SelectableText(last.assistant),
            ],
          ],
        ),
      ),
    );
  }

  Widget _branchControls(BuildContext appContext, Day10DemoEngine engine) {
    final branch = engine.branches[engine.activeBranch]!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ветвление после шага 8',
              style: Theme.of(appContext).textTheme.titleMedium,
            ),
            Text(
              engine.hasCheckpoint
                  ? 'A и B получили копию истории на шаге 8. Переключение '
                        'не передаёт их новые сообщения друг другу.'
                  : 'Checkpoint появится, когда стратегия «Ветвление» '
                        'завершит восьмой шаг.',
            ),
            if (engine.hasCheckpoint) ...[
              DropdownButton<String>(
                key: const ValueKey('day10-branch-select'),
                value: engine.activeBranch,
                items: [
                  for (final key in ['branching', 'a', 'b'])
                    DropdownMenuItem(
                      value: key,
                      child: Text(engine.branches[key]!.label),
                    ),
                ],
                onChanged: engine.busy
                    ? null
                    : (key) {
                        if (key != null) engine.selectBranch(key);
                      },
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final key in ['a', 'b']) ...[
                    FilledButton.tonal(
                      key: ValueKey('day10-add-$key'),
                      onPressed:
                          engine.busy ||
                              engine.branches[key]!.branchExtraStep != 0
                          ? null
                          : () => unawaited(engine.runBranchPrompt(key)),
                      child: Text('Добавить в ${key.toUpperCase()}'),
                    ),
                    OutlinedButton(
                      key: ValueKey('day10-check-$key'),
                      onPressed:
                          engine.busy ||
                              engine.branches[key]!.branchExtraStep != 1
                          ? null
                          : () => unawaited(engine.runBranchCheck(key)),
                      child: Text('Проверить ${key.toUpperCase()}'),
                    ),
                  ],
                  OutlinedButton(
                    key: const ValueKey('day10-branch-next'),
                    onPressed:
                        engine.busy ||
                            (engine.activeBranch != 'a' &&
                                engine.activeBranch != 'b') ||
                            branch.scenarioStep >= 14
                        ? null
                        : () => unawaited(engine.runNextActiveBranch()),
                    child: const Text('Следующий шаг в выбранной ветке'),
                  ),
                ],
              ),
              _strategyCard(appContext, branch),
            ],
          ],
        ),
      ),
    );
  }

  Widget _ledger(Day10DemoEngine engine) {
    final all = [
      for (final key in ['sliding', 'facts', 'branching', 'a', 'b'])
        if (engine.branches.containsKey(key)) engine.branches[key]!,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Стратегия/ветка')),
          DataColumn(label: Text('Вызов')),
          DataColumn(label: Text('Итог')),
          DataColumn(label: Text('Ввод')),
          DataColumn(label: Text('Вывод')),
          DataColumn(label: Text('Кэш')),
          DataColumn(label: Text('Всего')),
        ],
        rows: [
          for (final branch in all)
            for (final row in branch.invocations)
              DataRow(
                cells: [
                  DataCell(Text(branch.label)),
                  DataCell(Text(row.id)),
                  DataCell(Text(row.outcome)),
                  DataCell(
                    Text(row.usage.requestContext?.value.toString() ?? '—'),
                  ),
                  DataCell(
                    Text(row.usage.responseGenerated?.value.toString() ?? '—'),
                  ),
                  DataCell(Text(row.usage.cacheRead?.value.toString() ?? '—')),
                  DataCell(Text(row.usage.overall?.value.toString() ?? '—')),
                ],
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Domovoy · День 10',
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('День 10 · Стратегии контекста')),
      body: _engine == null
          ? Center(child: Text(_loadError ?? 'Загрузка сценария…'))
          : AnimatedBuilder(
              animation: _engine!,
              builder: (context, _) {
                final engine = _engine!;
                return ListView(
                  padding: const EdgeInsets.all(18),
                  children: [
                    const Text(
                      'Одинаковые 14 запросов проходят через настоящий '
                      'DeepSeek и AgentRuntime. Сравнивайте ответы и фактические '
                      'токены API; разница качества зависит от ответов модели.',
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        const Text('Выбранная стратегия:'),
                        DropdownButton<Day10Strategy>(
                          key: const ValueKey('day10-strategy-select'),
                          value: engine.selectedStrategy,
                          items: [
                            for (final strategy in Day10Strategy.values)
                              DropdownMenuItem(
                                value: strategy,
                                child: Text(strategy.label),
                              ),
                          ],
                          onChanged: engine.busy
                              ? null
                              : (strategy) {
                                  if (strategy != null) {
                                    unawaited(engine.selectStrategy(strategy));
                                  }
                                },
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          key: const ValueKey('day10-selected-next'),
                          onPressed:
                              engine.busy ||
                                  engine
                                          .branches[engine
                                              .selectedStrategy
                                              .name]!
                                          .scenarioStep >=
                                      14
                              ? null
                              : () => unawaited(engine.runNextSelected()),
                          child: const Text('Шаг выбранной стратегии'),
                        ),
                        FilledButton(
                          key: const ValueKey('day10-next'),
                          onPressed: engine.busy || engine.comparisonStep >= 14
                              ? null
                              : () => unawaited(engine.runNextComparison()),
                          child: const Text('Следующий шаг'),
                        ),
                        FilledButton.tonal(
                          key: const ValueKey('day10-all'),
                          onPressed: engine.busy || engine.comparisonStep >= 14
                              ? null
                              : () => unawaited(engine.runAll()),
                          child: const Text('Все 14 шагов'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('day10-reset'),
                          onPressed: engine.busy
                              ? null
                              : () => unawaited(engine.reset()),
                          child: const Text('Сбросить'),
                        ),
                      ],
                    ),
                    if (engine.busy) const LinearProgressIndicator(),
                    const SizedBox(height: 10),
                    Text(engine.status, key: const ValueKey('day10-status')),
                    if (engine.error != null)
                      SelectableText(
                        engine.error!,
                        key: const ValueKey('day10-error'),
                      ),
                    const SizedBox(height: 14),
                    for (final strategy in Day10Strategy.values)
                      _strategyCard(context, engine.branches[strategy.name]!),
                    _branchControls(context, engine),
                    ExpansionTile(
                      title: const Text('14 общих запросов'),
                      children: [
                        for (var i = 0; i < engine.prompts.length; i++)
                          ExpansionTile(
                            title: Text('${i + 1}. ${engine.prompts[i].title}'),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(engine.prompts[i].prompt),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const Text(
                      'Восемь контрольных фактов',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SelectableText(
                      'Проект: Север · Бюджет: 150000 · '
                      'Срок: 15 ноября · Уведомления: email · '
                      'Регион данных: Россия · Онлайн-оплата: нет · '
                      'Длительность: 45 минут · Отмена: за 3 часа.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Физический ledger API',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    _ledger(engine),
                    const SizedBox(height: 12),
                    const Text(
                      'Явные факты распознаются только по указанным '
                      'полям вида «Ключ: значение». Их изменение видно до '
                      'вызова модели. Ветки A/B считают лишь новые вызовы.',
                    ),
                  ],
                );
              },
            ),
    ),
  );
}
