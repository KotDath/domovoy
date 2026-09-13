import 'dart:async';

import 'package:flutter/material.dart';

import 'core/agents/agents.dart';
import 'core/llm/llm.dart';
import 'demos/day09_compaction.dart';
import 'demos/day09_comparison.dart';
import 'demos/day09_dependencies.dart';
import 'demos/day09_scenario.dart';
import 'demos/day09_session_pointer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(Day09DemoApp(dependencies: Day09DemoDependencies.production()));
}

class Day09DemoApp extends StatefulWidget {
  const Day09DemoApp({
    required this.dependencies,
    this.steps,
    this.pointerStore,
    super.key,
  });

  final Day09DemoDependencies dependencies;
  final List<Day09ScenarioStep>? steps;
  final Day09PairPointerStore? pointerStore;

  @override
  State<Day09DemoApp> createState() => _Day09DemoAppState();
}

class _Day09DemoAppState extends State<Day09DemoApp> {
  Day09ComparisonController? _controller;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final steps = widget.steps ?? await loadDay09Scenario();
      final controller = Day09ComparisonController(
        dependencies: widget.dependencies,
        pointerStore:
            widget.pointerStore ?? SharedPreferencesDay09PairPointerStore(),
        steps: steps,
      );
      if (!mounted) {
        unawaited(controller.close());
        return;
      }
      setState(() => _controller = controller);
      await controller.initialize();
    } on Object {
      if (mounted) {
        setState(() => _loadError = 'Не удалось загрузить сценарий дня 9.');
      }
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller == null) {
      unawaited(widget.dependencies.close());
    } else {
      unawaited(controller.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Domovoy · День 9',
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('День 9 · Сжатие истории')),
      body: _loadError != null
          ? Center(child: Text(_loadError!))
          : _controller == null
          ? const Center(child: CircularProgressIndicator())
          : AnimatedBuilder(
              animation: _controller!,
              builder: (context, _) => _content(context, _controller!),
            ),
    ),
  );

  Widget _content(BuildContext context, Day09ComparisonController controller) {
    final baseline = controller.baselineSnapshot;
    final summarized = controller.summarizedSnapshot;
    final baselineUsage = baseline == null ? null : Day09UsageView(baseline);
    final summaryUsage = summarized == null ? null : Day09UsageView(summarized);
    final summaryText = controller.savedSummary();
    final tail = controller.rawTail();
    final state = summarized?.compactionState;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Один и тот же сценарий в двух настоящих чатах DeepSeek: '
          'полная история и summary каждые 10 завершённых сообщений. '
          'Последние две пары остаются дословно.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(
              key: const ValueKey('day09-next'),
              onPressed:
                  controller.ready &&
                      !controller.busy &&
                      !controller.needsReset &&
                      controller.completedSteps < controller.steps.length
                  ? () => unawaited(controller.runNext())
                  : null,
              child: const Text('Следующий шаг'),
            ),
            FilledButton.tonal(
              key: const ValueKey('day09-all'),
              onPressed:
                  controller.ready &&
                      !controller.busy &&
                      !controller.needsReset &&
                      controller.completedSteps < controller.steps.length
                  ? () => unawaited(controller.runAll())
                  : null,
              child: Text('Запустить все ${controller.steps.length}'),
            ),
            OutlinedButton(
              key: const ValueKey('day09-reset'),
              onPressed: controller.busy
                  ? null
                  : () => unawaited(controller.reset()),
              child: const Text('Новый сценарий'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (controller.busy) const LinearProgressIndicator(),
        Text(controller.status, key: const ValueKey('day09-status')),
        if (controller.error != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            controller.error!,
            key: const ValueKey('day09-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 18),
        Text(
          'Шаги: ${controller.completedSteps} / ${controller.steps.length}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = <Widget>[
              _answerCard(
                'Без сжатия',
                controller.latestAnswer(baseline),
                baselineUsage?.latestAnswerRequest,
                key: const ValueKey('day09-baseline-answer'),
              ),
              _answerCard(
                'С summary',
                controller.latestAnswer(summarized),
                summaryUsage?.latestAnswerRequest,
                key: const ValueKey('day09-summary-answer'),
              ),
            ];
            if (constraints.maxWidth >= 800) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              );
            }
            return Column(
              children: [cards[0], const SizedBox(height: 12), cards[1]],
            );
          },
        ),
        const SizedBox(height: 20),
        Text(
          'Расход по ответам API',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Ввод включает кэш, вывод включает reasoning. Summary — отдельный физический расход; суммы не основаны на оценщике контекста.',
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Режим')),
              DataColumn(label: Text('Вызовы')),
              DataColumn(label: Text('Ввод')),
              DataColumn(label: Text('Вывод')),
              DataColumn(label: Text('Кэш')),
              DataColumn(label: Text('Попадание')),
              DataColumn(label: Text('Всего')),
            ],
            rows: [
              _usageRow('Без сжатия · ответы', baselineUsage?.assistant),
              _usageRow('С summary · ответы', summaryUsage?.assistant),
              _usageRow('Создание summary', summaryUsage?.summary),
              _usageRow('С summary · всё вместе', summaryUsage?.total),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Последний запрос, ввод: без сжатия ${_metric(baselineUsage?.latestAnswerRequest)}, '
          'с summary ${_metric(summaryUsage?.latestAnswerRequest)}.',
          key: const ValueKey('day09-latest-input'),
        ),
        Text(
          _totalDifference(baselineUsage?.total, summaryUsage?.total),
          key: const ValueKey('day09-total-difference'),
        ),
        const SizedBox(height: 20),
        Text(
          'Сохранённый summary',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          state == null
              ? 'Сжатия ещё не было.'
              : 'Поколение ${state.generation}; обработано сырых сообщений: '
                    '${state.decisionMetadata[Day09MessageCadenceTrigger.rawTotalKey] ?? '—'}; '
                    'оставлено при сжатии: '
                    '${state.decisionMetadata[Day09MessageCadenceTrigger.retainedRawKey] ?? '—'}.',
          key: const ValueKey('day09-summary-state'),
        ),
        SelectableText(
          summaryText.isEmpty ? '—' : summaryText,
          key: const ValueKey('day09-saved-summary'),
        ),
        ExpansionTile(
          title: Text(
            'Дословный хвост после summary: ${tail.length} сообщений',
          ),
          children: [
            for (final (index, message) in tail.indexed)
              ListTile(
                title: Text(
                  '${index + 1}. ${message.role == LlmMessageRole.user ? 'Пользователь' : 'Агент'}',
                ),
                subtitle: SelectableText(message.text),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Сценарий', style: Theme.of(context).textTheme.titleMedium),
        const Text(
          'Раскройте шаг, чтобы увидеть точный одинаковый запрос для обоих режимов.',
        ),
        for (final (index, step) in controller.steps.indexed)
          ExpansionTile(
            key: ValueKey('day09-step-${index + 1}'),
            leading: Icon(
              index < controller.completedSteps
                  ? Icons.check_circle_outline
                  : Icons.radio_button_unchecked,
            ),
            title: Text('${index + 1}. ${step.title}'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(step.prompt),
              ),
            ],
          ),
        const SizedBox(height: 20),
        const Text(
          'Проверьте в итоговых ответах 8 фактов: Север, 150000, 15 ноября, email, Россия, без онлайн-оплаты, 45 минут, отмена за 3 часа. Если провайдер не вспомнил факт, сравнение показывает ответ как есть.',
        ),
      ],
    );
  }

  Widget _answerCard(
    String title,
    String answer,
    LlmUsageMetric? latestInput, {
    Key? key,
  }) => Card(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          Text('Ввод последнего запроса: ${_metric(latestInput)}'),
          const SizedBox(height: 10),
          SelectableText(answer.isEmpty ? 'Ответа пока нет.' : answer),
        ],
      ),
    ),
  );

  DataRow _usageRow(String label, AgentUsageAggregate? usage) => DataRow(
    cells: [
      DataCell(Text(label)),
      DataCell(
        Text(
          usage?.contributorCount == 0 || usage == null
              ? '—'
              : '${usage.contributorCount}',
        ),
      ),
      DataCell(Text(_dimension(usage?.requestContext))),
      DataCell(Text(_dimension(usage?.responseGenerated))),
      DataCell(Text(_dimension(usage?.cacheRead))),
      DataCell(
        Text(
          usage?.cacheHitRatio == null
              ? '—'
              : '${(usage!.cacheHitRatio!.value * 100).toStringAsFixed(1)}%',
        ),
      ),
      DataCell(Text(_dimension(usage?.overall))),
    ],
  );

  String _metric(LlmUsageMetric? metric) => metric?.value.toString() ?? '—';

  String _dimension(AgentUsageDimensionAggregate? dimension) {
    if (dimension == null ||
        dimension.contributorCount == 0 ||
        dimension.completeness == LlmUsageCompleteness.unavailable) {
      return '—';
    }
    return dimension.completeness == LlmUsageCompleteness.partial
        ? '${dimension.knownSubtotal}+'
        : '${dimension.knownSubtotal}';
  }

  String _totalDifference(
    AgentUsageAggregate? baseline,
    AgentUsageAggregate? summary,
  ) {
    final before = baseline?.overall.value;
    final after = summary?.overall.value;
    if (before == null ||
        after == null ||
        baseline?.overall.completeness != LlmUsageCompleteness.complete ||
        summary?.overall.completeness != LlmUsageCompleteness.complete ||
        baseline!.contributorCount == 0 ||
        summary!.contributorCount == 0) {
      return 'Разница общего API-расхода: —';
    }
    final difference = before - after;
    return 'Разница общего API-расхода (без сжатия − с summary): '
        '${difference >= 0 ? '+' : ''}$difference токенов.';
  }
}
