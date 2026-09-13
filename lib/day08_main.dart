import 'dart:async';

import 'package:flutter/material.dart';

import 'core/agents/agents.dart';
import 'core/llm/llm.dart';
import 'demos/demo_dependencies.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(Day08DemoApp(dependencies: DemoDependencies.diagnostic()));
}

enum _Day08Scenario { short, long, overflow }

final class _Day08Invocation {
  const _Day08Invocation(this.number, this.usage, this.outcome);
  final int number;
  final LlmUsage usage;
  final AgentModelInvocationOutcome outcome;
}

class Day08DemoApp extends StatefulWidget {
  const Day08DemoApp({
    required this.dependencies,
    this.overflowUnitCount = 1100000,
    super.key,
  });

  final DemoDependencies dependencies;
  final int overflowUnitCount;

  @override
  State<Day08DemoApp> createState() => _Day08DemoAppState();
}

class _Day08DemoAppState extends State<Day08DemoApp> {
  bool _busy = false;
  String _status = 'Готово к проверке DeepSeek';
  String _answer = '';
  String? _error;
  List<_Day08Invocation> _invocations = const <_Day08Invocation>[];

  @override
  void dispose() {
    unawaited(widget.dependencies.close());
    super.dispose();
  }

  Future<void> _run(_Day08Scenario scenario) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = switch (scenario) {
        _Day08Scenario.short => 'Короткий запрос выполняется…',
        _Day08Scenario.long => 'Длинный чат выполняется…',
        _Day08Scenario.overflow =>
          'Генерируем большой запрос локально и ждём ответ API…',
      };
      _answer = '';
      _error = null;
      _invocations = const <_Day08Invocation>[];
    });
    AgentSession? session;
    try {
      final stack = widget.dependencies.stack;
      await stack.providerModelCatalog?.initialize();
      final definition = AgentDefinition(
        id: AgentId('day-08-diagnostic'),
        name: 'Day 8 API diagnostic',
        systemPrompt: 'Отвечай кратко и по существу.',
        model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
        generation: LlmGenerationConfig(
          reasoningMode: ReasoningMode.disabled,
          maxOutputTokens: scenario == _Day08Scenario.overflow ? 1 : 128,
        ),
        limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
      );
      session = await stack.runtime.agent(definition).createSession();
      final prompts = switch (scenario) {
        _Day08Scenario.short => <String>['Скажи одним словом: готово.'],
        _Day08Scenario.long => <String>[
          'Запомни: проект называется Север, бюджет 150000 рублей. Ответь кратко.',
          'Контекст проекта: ${List<String>.filled(600, 'план ').join()}. Ответь кратко.',
          'Как называется проект и какой его бюджет? Ответь кратко.',
        ],
        _Day08Scenario.overflow => <String>[
          List<String>.filled(widget.overflowUnitCount, ' x').join(),
        ],
      };
      for (var index = 0; index < prompts.length; index++) {
        if (mounted) {
          setState(() => _status = 'Запрос ${index + 1} из ${prompts.length}…');
        }
        final events = await session.run(prompts[index]).events.toList();
        final accounting = session.snapshot.tokenAccounting;
        final rows = <_Day08Invocation>[
          for (final view in accounting.ledger)
            if (view.entry.operationKind == AgentModelOperationKind.assistant)
              _Day08Invocation(
                view.entry.sequence,
                view.entry.usage,
                view.entry.outcome,
              ),
        ];
        final terminal = events.last;
        if (terminal is AgentRunFailed) {
          if (mounted) {
            setState(() {
              _invocations = rows;
              _error = terminal.error.safeProviderMessage
                  ? terminal.error.message
                  : 'Провайдер не смог завершить запрос.';
              _status = 'Ошибка API · DeepSeek / deepseek-flash';
            });
          }
          break;
        }
        if (terminal is! AgentRunCompleted) {
          if (mounted) {
            setState(() {
              _invocations = rows;
              _status = 'Запрос остановлен';
            });
          }
          break;
        }
        final answer = session.snapshot.transcript.messages.last.parts
            .whereType<LlmTextPart>()
            .map((part) => part.text)
            .join();
        if (mounted) {
          setState(() {
            _invocations = rows;
            _answer = [
              if (_answer.isNotEmpty) _answer,
              '${index + 1}. ${answer.length > 1000 ? answer.substring(0, 1000) : answer}',
            ].join('\n');
            _status = 'Готово · ${rows.length} физических вызовов API';
          });
        }
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'Не удалось запустить диагностический запрос. Проверьте API-ключ и соединение.';
          _status = 'Ошибка запуска';
        });
      }
    } finally {
      await session?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _metric(LlmUsageMetric? metric) => metric?.value.toString() ?? '—';

  String _aggregateValue(AgentUsageDimensionAggregate value) {
    if (value.contributorCount == 0 ||
        value.completeness == LlmUsageCompleteness.unavailable) {
      return '—';
    }
    return value.completeness == LlmUsageCompleteness.partial
        ? '${value.knownSubtotal}+'
        : '${value.knownSubtotal}';
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Domovoy · День 8',
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('День 8 · Контекст и ошибки API')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Три сценария используют настоящий DeepSeek и AgentRuntime. '
              'Значения ниже получены только из ответа API.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  key: const ValueKey('day08-short'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_run(_Day08Scenario.short)),
                  child: const Text('Короткий'),
                ),
                FilledButton(
                  key: const ValueKey('day08-long'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_run(_Day08Scenario.long)),
                  child: const Text('Длинный'),
                ),
                FilledButton(
                  key: const ValueKey('day08-overflow'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_run(_Day08Scenario.overflow)),
                  child: const Text('Переполнение'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            Text(_status, key: const ValueKey('day08-status')),
            if (_answer.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Ответы',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(_answer, key: const ValueKey('day08-answer')),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Сообщение провайдера',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(_error!, key: const ValueKey('day08-error')),
            ],
            const SizedBox(height: 20),
            const Text(
              'Физические вызовы API',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text('Итог')),
                  DataColumn(label: Text('Ввод')),
                  DataColumn(label: Text('Вывод')),
                  DataColumn(label: Text('Кэш')),
                  DataColumn(label: Text('Попадание')),
                  DataColumn(label: Text('Рассуждение')),
                  DataColumn(label: Text('Всего')),
                ],
                rows: [
                  for (final row in _invocations)
                    DataRow(
                      cells: [
                        DataCell(Text('${row.number}')),
                        DataCell(Text(row.outcome.name)),
                        DataCell(Text(_metric(row.usage.requestContext))),
                        DataCell(Text(_metric(row.usage.responseGenerated))),
                        DataCell(Text(_metric(row.usage.cacheRead))),
                        DataCell(
                          Text(
                            row.usage.cacheHitRatio == null
                                ? '—'
                                : '${(row.usage.cacheHitRatio!.value * 100).toStringAsFixed(1)}%',
                          ),
                        ),
                        DataCell(Text(_metric(row.usage.reasoning))),
                        DataCell(Text(_metric(row.usage.overall))),
                      ],
                    ),
                ],
              ),
            ),
            Builder(
              builder: (context) {
                final history = AgentUsageAggregate.fromUsages(
                  _invocations.map((entry) => entry.usage),
                );
                return Text(
                  'История: ввод ${_aggregateValue(history.requestContext)} · '
                  'вывод ${_aggregateValue(history.responseGenerated)} · '
                  'всего ${_aggregateValue(history.overall)}',
                  key: const ValueKey('day08-history'),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
