import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../prompt/domain/agent.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../../settings/domain/model_settings.dart';
import '../../settings/presentation/api_key_settings_dialog.dart';
import '../domain/four_house_puzzle.dart';
import '../domain/reasoning_models.dart';
import 'reasoning_controller.dart';

class ReasoningPage extends StatefulWidget {
  const ReasoningPage({
    required this.agent,
    required this.overrideStore,
    required this.apiKeyResolver,
    required this.modelSettingsStore,
    this.isWeb = kIsWeb,
    super.key,
  });

  final Agent agent;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final bool isWeb;

  @override
  State<ReasoningPage> createState() => _ReasoningPageState();
}

class _ReasoningPageState extends State<ReasoningPage> {
  late final ReasoningController _controller;
  late final TextEditingController _task;

  @override
  void initState() {
    super.initState();
    _controller = ReasoningController(widget.agent)..addListener(_rebuild);
    _task = TextEditingController(text: fourHousePresetTask)
      ..addListener(_rebuild);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_rebuild)
      ..dispose();
    _task
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openSettings() {
    return showApiKeySettingsDialog(
      context: context,
      overrideStore: widget.overrideStore,
      resolver: widget.apiKeyResolver,
      isWeb: widget.isWeb,
      modelSettingsStore: widget.modelSettingsStore,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final running = state.isRunning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Лаборатория · День 3'),
        actions: [
          IconButton(
            key: const ValueKey('open-day3-settings'),
            tooltip: 'Настройки API',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 900;
            return SingleChildScrollView(
              key: ValueKey(
                isWide ? 'wide-reasoning-layout' : 'narrow-reasoning-layout',
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _ReasoningOffBanner(),
                  const SizedBox(height: 12),
                  const _EightCallDisclosure(),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('day3-task'),
                    controller: _task,
                    enabled: !running,
                    minLines: 8,
                    maxLines: 16,
                    decoration: InputDecoration(
                      labelText: 'Общая задача',
                      errorText: state.taskError,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('run-reasoning'),
                    onPressed: running
                        ? null
                        : () => _controller.runComparison(_task.text),
                    icon: running
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(
                      running
                          ? 'Выполнение… (${state.costLabel})'
                          : 'Запустить 4 способа',
                    ),
                  ),
                  if (running || state.completedApiCalls > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Прогресс: ${state.costLabel} API-вызовов',
                      key: const ValueKey('run-progress'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _StrategyGrid(
                    state: state,
                    isWide: isWide,
                    onVerdict: _controller.setVerdict,
                  ),
                  const SizedBox(height: 16),
                  _ReferencePanel(task: _task.text),
                  const SizedBox(height: 16),
                  _SummaryPanel(
                    state: state,
                    onSelectMostAccurate: _controller.setMostAccurate,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReasoningOffBanner extends StatelessWidget {
  const _ReasoningOffBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('reasoning-off-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Нативное рассуждение модели выключено для всех четырёх стратегий, '
        'чтобы сравнивать только качество промптов, а не скрытый thinking-режим.',
      ),
    );
  }
}

class _EightCallDisclosure extends StatelessWidget {
  const _EightCallDisclosure();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Полное сравнение выполняет 8 API-вызовов: прямой ответ, решение по шагам, '
      'генерация и выполнение промпта, три независимых эксперта и отдельный синтез.',
      key: ValueKey('eight-call-cost'),
    );
  }
}

class _StrategyGrid extends StatelessWidget {
  const _StrategyGrid({
    required this.state,
    required this.isWide,
    required this.onVerdict,
  });

  final ReasoningExperimentState state;
  final bool isWide;
  final void Function(ReasoningStrategy, ReasoningVerdict) onVerdict;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final strategy in ReasoningStrategy.values)
        _StrategyCard(
          key: ValueKey('strategy-card-${strategy.name}'),
          strategy: strategy,
          state: state,
          onVerdict: onVerdict,
        ),
    ];
    if (isWide) {
      return Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 12),
              Expanded(child: cards[1]),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cards[2]),
              const SizedBox(width: 12),
              Expanded(child: cards[3]),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          cards[i],
        ],
      ],
    );
  }
}

class _StrategyCard extends StatelessWidget {
  const _StrategyCard({
    required this.strategy,
    required this.state,
    required this.onVerdict,
    super.key,
  });

  final ReasoningStrategy strategy;
  final ReasoningExperimentState state;
  final void Function(ReasoningStrategy, ReasoningVerdict) onVerdict;

  @override
  Widget build(BuildContext context) {
    final lane = state.laneFor(strategy);
    final status = switch (strategy) {
      ReasoningStrategy.generatedPrompt => state.generatedStrategyStatus,
      ReasoningStrategy.expertGroup => state.expertStrategyStatus,
      ReasoningStrategy.direct || ReasoningStrategy.stepByStep => lane.status,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    reasoningStrategyLabel(strategy),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (status == ReasoningLaneStatus.streaming)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (status == ReasoningLaneStatus.completed)
                  const Icon(Icons.check_circle_outline, size: 20),
                if (status == ReasoningLaneStatus.failed)
                  const Icon(Icons.error_outline, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            Text(reasoningStrategyTransformation(strategy)),
            const SizedBox(height: 4),
            Text('Стоимость: ${reasoningStrategyCostLabel(strategy)}'),
            if (strategy == ReasoningStrategy.generatedPrompt) ...[
              if (state.promptBuilder.status != ReasoningLaneStatus.idle) ...[
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('generated-prompt-evidence'),
                  title: 'Этап 1 · Генерация промпта',
                  lane: state.promptBuilder,
                  emptyStreamingLabel: 'Ожидаем промпт…',
                ),
              ],
              if (state.generated.status != ReasoningLaneStatus.idle) ...[
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('generated-solver-section'),
                  title: 'Этап 2 · Выполнение промпта',
                  lane: state.generated,
                  answerKey: const ValueKey('generated-solver-answer'),
                  emptyStreamingLabel: 'Ожидаем первые токены…',
                ),
              ],
            ] else if (strategy == ReasoningStrategy.expertGroup) ...[
              const SizedBox(height: 8),
              const Text(
                '4 вызова: три эксперта не видят ответы друг друга; синтезатор получает все три результата.',
                key: ValueKey('expert-call-breakdown'),
              ),
              if (state.expertStrategyStatus != ReasoningLaneStatus.idle) ...[
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('expert-analyst-evidence'),
                  title: 'Этап 1 · Аналитик',
                  lane: state.expertAnalyst,
                  answerKey: const ValueKey('expert-analyst-answer'),
                  emptyStreamingLabel: 'Аналитик формирует решение…',
                ),
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('expert-engineer-evidence'),
                  title: 'Этап 2 · Инженер',
                  lane: state.expertEngineer,
                  answerKey: const ValueKey('expert-engineer-answer'),
                  emptyStreamingLabel: 'Инженер проверяет ограничения…',
                ),
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('expert-critic-evidence'),
                  title: 'Этап 3 · Критик',
                  lane: state.expertCritic,
                  answerKey: const ValueKey('expert-critic-answer'),
                  emptyStreamingLabel: 'Критик ищет противоречия…',
                ),
                const SizedBox(height: 8),
                _StagePanel(
                  key: const ValueKey('expert-synthesis-section'),
                  title: 'Этап 4 · Синтез',
                  lane: state.expertGroup,
                  answerKey: const ValueKey('expert-synthesis-answer'),
                  emptyStreamingLabel: 'Синтезатор согласует ответы…',
                ),
              ],
            ] else ...[
              if (lane.answer.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(lane.answer),
              ],
              if (status == ReasoningLaneStatus.streaming && !lane.hasOutput)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Ожидаем первые токены…'),
                ),
              if (lane.failure case final failure?) ...[
                const SizedBox(height: 8),
                Text(failure.message),
              ],
              if (lane.finishReason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Причина завершения: ${agentFinishReasonLabel(lane.finishReason)}',
                  ),
                ),
              if (lane.usage != null && !lane.usage!.isEmpty)
                Text(
                  'Токены: prompt=${lane.usage!.promptTokens ?? '—'}, '
                  'completion=${lane.usage!.completionTokens ?? '—'}, '
                  'total=${lane.usage!.totalTokens ?? '—'}.',
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final verdict in ReasoningVerdict.values)
                  ChoiceChip(
                    key: ValueKey('verdict-${strategy.name}-${verdict.name}'),
                    label: Text(reasoningVerdictLabel(verdict)),
                    selected: lane.verdict == verdict,
                    onSelected: lane.isTerminal
                        ? (_) => onVerdict(strategy, verdict)
                        : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StagePanel extends StatelessWidget {
  const _StagePanel({
    required this.title,
    required this.lane,
    required this.emptyStreamingLabel,
    this.answerKey,
    super.key,
  });

  final String title;
  final ReasoningLaneState lane;
  final String emptyStreamingLabel;
  final Key? answerKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title. ${_laneStatusLabel(lane.status)}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(_laneStatusLabel(lane.status)),
            if (lane.answer.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(lane.answer, key: answerKey),
            ],
            if (lane.status == ReasoningLaneStatus.idle)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Ожидает запуска'),
              ),
            if (lane.status == ReasoningLaneStatus.streaming && !lane.hasOutput)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(emptyStreamingLabel),
              ),
            if (lane.failure case final failure?) ...[
              const SizedBox(height: 6),
              Text(failure.message),
            ],
            if (lane.finishReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Причина завершения: ${agentFinishReasonLabel(lane.finishReason)}',
                ),
              ),
            if (lane.usage != null && !lane.usage!.isEmpty)
              Text(
                'Токены: prompt=${lane.usage!.promptTokens ?? '—'}, '
                'completion=${lane.usage!.completionTokens ?? '—'}, '
                'total=${lane.usage!.totalTokens ?? '—'}.',
              ),
          ],
        ),
      ),
    );
  }
}

String _laneStatusLabel(ReasoningLaneStatus status) => switch (status) {
  ReasoningLaneStatus.idle => 'Статус: ожидает запуска',
  ReasoningLaneStatus.streaming => 'Статус: выполняется',
  ReasoningLaneStatus.completed => 'Статус: завершено',
  ReasoningLaneStatus.failed => 'Статус: ошибка',
};

class _ReferencePanel extends StatelessWidget {
  const _ReferencePanel({required this.task});

  final String task;

  @override
  Widget build(BuildContext context) {
    final preset = isFourHousePreset(task);
    final grid = fourHouseReference.uniqueGrid;
    return Container(
      key: const ValueKey('reference-panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: preset
          ? Column(
              key: const ValueKey('reference-grid'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Эталон', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(
                  'Дома пронумерованы слева направо. В каждом доме ровно один '
                  'житель, напиток и питомец. Полный перебор допускает ровно одну сетку.',
                ),
                const SizedBox(height: 8),
                for (var house = 1; house <= 4; house++)
                  Text(_houseLine(house, grid)),
              ],
            )
          : const Text(
              'Встроенный эталон неприменим: задача изменена, автоматическая '
              'правильность не утверждается.',
              key: ValueKey('reference-not-applicable'),
            ),
    );
  }

  String _houseLine(int house, FourHouseGrid grid) {
    final index = house - 1;
    return 'Дом $house — ${houseResidentLabel(grid.residents[index])}, '
        '${houseDrinkLabel(grid.drinks[index])}, '
        '${housePetLabel(grid.pets[index])}';
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.state,
    required this.onSelectMostAccurate,
  });

  final ReasoningExperimentState state;
  final ValueChanged<ReasoningStrategy?> onSelectMostAccurate;

  @override
  Widget build(BuildContext context) {
    final hasResults = ReasoningStrategy.values.any(
      (strategy) => state.laneFor(strategy).isTerminal,
    );
    final winner = state.mostAccurate;
    final summary = !hasResults
        ? 'Запустите сравнение, затем отметьте точность каждого ответа.'
        : winner == null
        ? 'Сравните каждый результат с уникальной эталонной сеткой и выберите '
              'самый точный способ. Победитель не назначается автоматически.'
        : 'Самый точный способ по вашей оценке: ${reasoningStrategyLabel(winner)}. '
              'Это прозрачное суждение пользователя, а не оценка модели.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Сравнение', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final strategy in ReasoningStrategy.values)
              ChoiceChip(
                key: ValueKey('most-accurate-${strategy.name}'),
                label: Text(reasoningStrategyLabel(strategy)),
                selected: winner == strategy,
                onSelected: state.laneFor(strategy).isTerminal
                    ? (selected) =>
                          onSelectMostAccurate(selected ? strategy : null)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(summary, key: const ValueKey('comparison-summary')),
        if (hasResults) ...[
          const SizedBox(height: 8),
          for (final strategy in ReasoningStrategy.values)
            Text(
              '${reasoningStrategyLabel(strategy)}: '
              '${reasoningVerdictLabel(state.laneFor(strategy).verdict)}',
            ),
        ],
      ],
    );
  }
}
