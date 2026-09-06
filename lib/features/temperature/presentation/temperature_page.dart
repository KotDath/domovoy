import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../prompt/domain/agent.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../../settings/domain/model_settings.dart';
import '../../settings/presentation/api_key_settings_dialog.dart';
import '../domain/temperature_metrics.dart';
import '../domain/temperature_models.dart';
import '../domain/temperature_prompts.dart';
import 'temperature_controller.dart';

class TemperaturePage extends StatefulWidget {
  const TemperaturePage({
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
  State<TemperaturePage> createState() => _TemperaturePageState();
}

class _TemperaturePageState extends State<TemperaturePage> {
  late final TemperatureController _controller;
  late final TextEditingController _prompt;
  late final List<TextEditingController> _notes;
  late List<double> _temperatures;
  int _ratingEpoch = 0;

  @override
  void initState() {
    super.initState();
    _controller = TemperatureController(widget.agent)..addListener(_rebuild);
    _prompt = TextEditingController(text: kTemperatureStarterPrompt)
      ..addListener(_rebuild);
    _notes = List<TextEditingController>.generate(
      kTemperatureLaneCount,
      (_) => TextEditingController(),
    );
    _temperatures = List<double>.from(kTemperaturePresetValues);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_rebuild)
      ..dispose();
    _prompt
      ..removeListener(_rebuild)
      ..dispose();
    for (final note in _notes) {
      note.dispose();
    }
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

  void _resetTemperatures() {
    setState(() {
      _temperatures = List<double>.from(kTemperaturePresetValues);
    });
  }

  void _run() {
    final started = _controller.runComparison(
      rawPrompt: _prompt.text,
      temperatures: _temperatures,
    );
    if (started) {
      setState(() {
        _ratingEpoch++;
        for (final note in _notes) {
          note.clear();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final running = state.isRunning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Лаборатория · День 4'),
        actions: [
          IconButton(
            key: const ValueKey('open-day4-settings'),
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
                isWide
                    ? 'wide-temperature-layout'
                    : 'narrow-temperature-layout',
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _GuidancePanel(),
                  const SizedBox(height: 12),
                  const _ThreeCallDisclosure(),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('day4-prompt'),
                    controller: _prompt,
                    enabled: !running,
                    minLines: 4,
                    maxLines: 10,
                    decoration: InputDecoration(
                      labelText: 'Общий запрос',
                      errorText: state.promptError,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _TemperatureControls(
                    values: _temperatures,
                    enabled: !running,
                    errorText: state.temperatureError,
                    onChanged: (index, value) {
                      setState(() {
                        _temperatures[index] = value;
                      });
                    },
                    onReset: running ? null : _resetTemperatures,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('run-temperature'),
                    onPressed: running ? null : _run,
                    icon: running
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(
                      running
                          ? 'Выполнение… (${state.costLabel})'
                          : 'Запустить сравнение',
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
                  _ResultGrid(
                    state: state,
                    configuredTemperatures: _temperatures,
                    isWide: isWide,
                    notes: _notes,
                    ratingEpoch: _ratingEpoch,
                    onRating: _controller.setRating,
                    onNote: (index, note) =>
                        _controller.setNote(laneIndex: index, note: note),
                  ),
                  const SizedBox(height: 16),
                  _PairwisePanel(state: state),
                  const SizedBox(height: 16),
                  _SummaryPanel(state: state),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GuidancePanel extends StatelessWidget {
  const _GuidancePanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('temperature-guidance'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Температура — единственная переменная выборки: нативное '
            'thinking выключено, top_p не задаётся.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'DeepSeek принимает temperature от 0.0 до 2.0 (по умолчанию 1). '
            'В thinking-режиме температура не действует, поэтому он выключен. '
            'Документация рекомендует менять либо temperature, либо top_p, '
            'но не оба параметра сразу — top_p намеренно не изменяется.',
            key: const ValueKey('provider-constraints'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Официальные примеры DeepSeek: код и математика — 0.0; анализ '
            'данных — 1.0; общение и перевод — 1.3; творческое письмо и '
            'поэзия — 1.5.',
            key: ValueKey('official-recommendations'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Выводы упражнения: 0.7 — промежуточное сбалансированное значение, '
            'а 1.2 — более вариативная настройка по направлению документации. '
            'Это не точные рекомендации провайдера.',
            key: ValueKey('exercise-inferences'),
          ),
          const SizedBox(height: 8),
          Text(
            'Нижние значения лучше для сфокусированной детерминированной '
            'работы, промежуточные балансируют фокус и вариативность, '
            'высокие лучше для мозгового штурма и творческих отличий. '
            'Точные числа эксперимента остаются свидетельством запуска.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _ThreeCallDisclosure extends StatelessWidget {
  const _ThreeCallDisclosure();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Сравнение выполняет 3 API-вызова: по одному независимому запросу '
      'на каждую температуру без истории диалога.',
      key: ValueKey('three-call-cost'),
    );
  }
}

class _TemperatureControls extends StatelessWidget {
  const _TemperatureControls({
    required this.values,
    required this.enabled,
    required this.onChanged,
    required this.onReset,
    this.errorText,
  });

  final List<double> values;
  final bool enabled;
  final String? errorText;
  final void Function(int index, double value) onChanged;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < values.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          Text(
            'Дорожка ${index + 1}: ${temperatureValueLabel(values[index])}',
            key: ValueKey('temperature-value-$index'),
          ),
          Slider(
            key: ValueKey('temperature-slider-$index'),
            min: kTemperatureMin,
            max: kTemperatureMax,
            divisions: kTemperatureSliderDivisions,
            value: values[index],
            label: temperatureValueLabel(values[index]),
            onChanged: enabled
                ? (value) => onChanged(index, quantizeTemperature(value))
                : null,
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('reset-temperatures'),
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Сбросить 0.0 / 0.7 / 1.2'),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              errorText!,
              key: const ValueKey('temperature-distinct-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.state,
    required this.configuredTemperatures,
    required this.isWide,
    required this.notes,
    required this.ratingEpoch,
    required this.onRating,
    required this.onNote,
  });

  final TemperatureExperimentState state;
  final List<double> configuredTemperatures;
  final bool isWide;
  final List<TextEditingController> notes;
  final int ratingEpoch;
  final void Function({
    required int laneIndex,
    required TemperatureRatingKind kind,
    required int? value,
  })
  onRating;
  final void Function(int index, String note) onNote;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (var index = 0; index < kTemperatureLaneCount; index++)
        _TemperatureCard(
          key: ValueKey('temperature-card-$index'),
          index: index,
          lane: state.laneAt(index),
          configuredTemperature: configuredTemperatures[index],
          note: notes[index],
          ratingEpoch: ratingEpoch,
          onRating: onRating,
          onNote: onNote,
        ),
    ];
    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: cards[i]),
          ],
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

class _TemperatureCard extends StatelessWidget {
  const _TemperatureCard({
    required this.index,
    required this.lane,
    required this.configuredTemperature,
    required this.note,
    required this.ratingEpoch,
    required this.onRating,
    required this.onNote,
    super.key,
  });

  final int index;
  final TemperatureLaneState lane;
  final double configuredTemperature;
  final TextEditingController note;
  final int ratingEpoch;
  final void Function({
    required int laneIndex,
    required TemperatureRatingKind kind,
    required int? value,
  })
  onRating;
  final void Function(int index, String note) onNote;

  @override
  Widget build(BuildContext context) {
    final applied = lane.appliedTemperature ?? configuredTemperature;
    final ratio =
        lane.status == TemperatureLaneStatus.completed && lane.hasOutput
        ? uniqueWordRatio(lane.answer)
        : null;
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
                    't=${temperatureValueLabel(applied)}',
                    key: ValueKey('applied-temperature-$index'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (lane.status == TemperatureLaneStatus.streaming)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (lane.status == TemperatureLaneStatus.completed)
                  const Icon(Icons.check_circle_outline, size: 20),
                if (lane.status == TemperatureLaneStatus.failed)
                  const Icon(Icons.error_outline, size: 20),
              ],
            ),
            if (lane.answer.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                lane.answer,
                key: ValueKey('temperature-answer-$index'),
              ),
            ],
            if (lane.status == TemperatureLaneStatus.streaming &&
                !lane.hasOutput)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Ожидаем первые токены…'),
              ),
            if (lane.failure case final failure?) ...[
              const SizedBox(height: 8),
              Text(failure.message, key: ValueKey('temperature-error-$index')),
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
            if (lane.hasOutput) ...[
              const SizedBox(height: 8),
              Text(
                'Символов: ${unicodeCharacterCount(lane.answer)}',
                key: ValueKey('character-count-$index'),
              ),
            ],
            if (lane.status == TemperatureLaneStatus.completed &&
                lane.hasOutput) ...[
              const SizedBox(height: 4),
              Text(
                ratio == null
                    ? 'Лексическое разнообразие (эвристика уникальных слов): недоступно'
                    : 'Лексическое разнообразие (эвристика уникальных слов): '
                          '${formatLexicalRatio(ratio)}',
                key: ValueKey('lexical-diversity-$index'),
              ),
            ],
            const SizedBox(height: 8),
            _RatingDropdown(
              laneIndex: index,
              kind: TemperatureRatingKind.accuracy,
              label: 'Точность',
              value: lane.evaluation.accuracy,
              enabled: lane.isTerminal,
              ratingEpoch: ratingEpoch,
              onRating: onRating,
            ),
            _RatingDropdown(
              laneIndex: index,
              kind: TemperatureRatingKind.creativity,
              label: 'Креативность',
              value: lane.evaluation.creativity,
              enabled: lane.isTerminal,
              ratingEpoch: ratingEpoch,
              onRating: onRating,
            ),
            _RatingDropdown(
              laneIndex: index,
              kind: TemperatureRatingKind.diversity,
              label: 'Разнообразие',
              value: lane.evaluation.diversity,
              enabled: lane.isTerminal,
              ratingEpoch: ratingEpoch,
              onRating: onRating,
            ),
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('note-$index'),
              controller: note,
              enabled: lane.isTerminal,
              minLines: 2,
              maxLines: 4,
              onChanged: (value) => onNote(index, value),
              decoration: const InputDecoration(
                labelText: 'Практическая заметка',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingDropdown extends StatelessWidget {
  const _RatingDropdown({
    required this.laneIndex,
    required this.kind,
    required this.label,
    required this.value,
    required this.enabled,
    required this.ratingEpoch,
    required this.onRating,
  });

  final int laneIndex;
  final TemperatureRatingKind kind;
  final String label;
  final int? value;
  final bool enabled;
  final int ratingEpoch;
  final void Function({
    required int laneIndex,
    required TemperatureRatingKind kind,
    required int? value,
  })
  onRating;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: KeyedSubtree(
        key: ValueKey('rating-reset-${kind.name}-$laneIndex-$ratingEpoch'),
        child: DropdownButtonFormField<int?>(
          key: ValueKey('rating-${kind.name}-$laneIndex'),
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Без оценки'),
            ),
            for (var score = 1; score <= 5; score++)
              DropdownMenuItem<int?>(value: score, child: Text('$score')),
          ],
          onChanged: enabled
              ? (selected) =>
                    onRating(laneIndex: laneIndex, kind: kind, value: selected)
              : null,
        ),
      ),
    );
  }
}

class _PairwisePanel extends StatelessWidget {
  const _PairwisePanel({required this.state});

  final TemperatureExperimentState state;

  @override
  Widget build(BuildContext context) {
    final pairs = <Widget>[];
    for (var i = 0; i < kTemperatureLaneCount; i++) {
      for (var j = i + 1; j < kTemperatureLaneCount; j++) {
        final left = state.laneAt(i);
        final right = state.laneAt(j);
        if (left.status != TemperatureLaneStatus.completed ||
            right.status != TemperatureLaneStatus.completed ||
            !left.hasOutput ||
            !right.hasOutput) {
          continue;
        }
        final similarity = pairwiseJaccardSimilarity(left.answer, right.answer);
        final leftLabel = temperatureValueLabel(
          left.appliedTemperature ?? state.temperatures[i],
        );
        final rightLabel = temperatureValueLabel(
          right.appliedTemperature ?? state.temperatures[j],
        );
        pairs.add(
          Text(
            similarity == null
                ? 'Сходство $leftLabel ↔ $rightLabel (лексическая эвристика): недоступно'
                : 'Сходство $leftLabel ↔ $rightLabel (лексическая эвристика Jaccard): '
                      '${formatLexicalRatio(similarity)}',
            key: ValueKey('similarity-$i-$j'),
          ),
        );
      }
    }
    if (pairs.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const ValueKey('pairwise-similarity'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Попарное лексическое сходство',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        ...pairs,
      ],
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.state});

  final TemperatureExperimentState state;

  @override
  Widget build(BuildContext context) {
    final hasResults = state.lanes.any((lane) => lane.isTerminal);
    final unrated =
        hasResults &&
        state.lanes
            .where((lane) => lane.isTerminal)
            .every((lane) => !lane.evaluation.hasAnyScore);
    final summary = !hasResults
        ? 'Запустите сравнение, затем оцените точность, креативность и '
              'разнообразие вручную. Победитель не назначается автоматически.'
        : unrated
        ? 'Оцените точность, креативность и разнообразие вручную. '
              'Автоматические оценки качества и победитель не назначаются.'
        : 'Сводка содержит только ваши оценки и заметки. '
              'Автоматический победитель не назначается.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Сравнение', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(summary, key: const ValueKey('temperature-summary')),
        const SizedBox(height: 8),
        const Text(
          'Один ответ на каждую температуру показывает различия, но не '
          'оценивает полное стохастическое распределение модели. Повторные '
          'запуски дают новые примеры и в этой версии не агрегируются.',
          key: ValueKey('single-sample-limitation'),
        ),
        if (hasResults) ...[
          const SizedBox(height: 8),
          for (var index = 0; index < state.lanes.length; index++)
            if (state.laneAt(index).isTerminal) _laneSummary(state, index),
        ],
      ],
    );
  }

  Widget _laneSummary(TemperatureExperimentState state, int index) {
    final lane = state.laneAt(index);
    final evaluation = lane.evaluation;
    final temperature = temperatureValueLabel(
      lane.appliedTemperature ?? state.temperatures[index],
    );
    final note = evaluation.note.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        't=$temperature: точность ${temperatureRatingLabel(evaluation.accuracy)}, '
        'креативность ${temperatureRatingLabel(evaluation.creativity)}, '
        'разнообразие ${temperatureRatingLabel(evaluation.diversity)}'
        '${note.isEmpty ? '' : '; заметка: $note'}',
        key: ValueKey('summary-lane-$index'),
      ),
    );
  }
}
