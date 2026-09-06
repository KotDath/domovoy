import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/environment/environment_reader.dart';
import '../../prompt/domain/agent.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../data/profile_agent_factory.dart';
import '../data/profile_credential_resolver.dart';
import '../domain/chat_model_profile.dart';
import '../domain/comparison_models.dart';
import '../domain/comparison_prompts.dart';
import '../domain/structural_checklist.dart';
import '../domain/token_cost.dart';
import 'comparison_controller.dart';
import 'comparison_profile_catalog.dart';
import 'profile_settings_dialog.dart';

class ComparisonPage extends StatefulWidget {
  const ComparisonPage({
    required this.agentFactory,
    required this.catalog,
    required this.sharedDeepSeekResolver,
    required this.profileOverrideStore,
    required this.environment,
    super.key,
  });

  final ComparisonAgentFactory agentFactory;
  final ComparisonProfileCatalog catalog;
  final ApiKeyResolver sharedDeepSeekResolver;
  final ProfileApiKeyOverrideStore profileOverrideStore;
  final EnvironmentReader environment;

  @override
  State<ComparisonPage> createState() => ComparisonPageState();
}

class ComparisonPageState extends State<ComparisonPage> {
  late final ComparisonController _controller;
  late final TextEditingController _prompt;
  late final TextEditingController _conclusion;
  late final List<TextEditingController> _notes;
  int _ratingEpoch = 0;

  @override
  void initState() {
    super.initState();
    _controller = ComparisonController(agentFactory: widget.agentFactory)
      ..addListener(_rebuild);
    _prompt = TextEditingController(text: kComparisonStarterPrompt)
      ..addListener(_rebuild);
    _conclusion = TextEditingController()
      ..addListener(() {
        _controller.setConclusion(_conclusion.text);
      });
    _notes = List<TextEditingController>.generate(
      kComparisonLaneCount,
      (_) => TextEditingController(),
    );
    widget.catalog.addListener(_onCatalog);
    unawaited(reloadProfiles());
  }

  @override
  void dispose() {
    widget.catalog.removeListener(_onCatalog);
    _controller
      ..removeListener(_rebuild)
      ..dispose();
    _prompt
      ..removeListener(_rebuild)
      ..dispose();
    _conclusion.dispose();
    for (final note in _notes) {
      note.dispose();
    }
    super.dispose();
  }

  Future<void> reloadProfiles() async {
    await widget.catalog.load();
    if (!mounted) {
      return;
    }
    _controller.setConfiguredProfiles(widget.catalog.profiles);
    _controller.setLoadWarning(widget.catalog.warning);
  }

  void _onCatalog() {
    if (_controller.isRunning) {
      return;
    }
    _controller.setConfiguredProfiles(widget.catalog.profiles);
    _controller.setLoadWarning(widget.catalog.warning);
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openSettings() {
    if (_controller.isRunning) {
      return Future.value();
    }
    return showComparisonProfileSettingsDialog(
      context: context,
      catalog: widget.catalog,
      sharedDeepSeekResolver: widget.sharedDeepSeekResolver,
      profileOverrideStore: widget.profileOverrideStore,
      environment: widget.environment,
    );
  }

  void _run() {
    final started = _controller.runComparison(
      rawPrompt: _prompt.text,
      profiles: widget.catalog.profiles,
    );
    if (started) {
      setState(() {
        _ratingEpoch++;
        _conclusion.clear();
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
    final profiles = widget.catalog.profiles;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Лаборатория · День 5'),
        actions: [
          IconButton(
            key: const ValueKey('open-day5-settings'),
            tooltip: 'Профили моделей',
            onPressed: running ? null : _openSettings,
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
                isWide ? 'wide-comparison-layout' : 'narrow-comparison-layout',
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _GuidancePanel(),
                  const SizedBox(height: 12),
                  const _ThreeCallDisclosure(),
                  const SizedBox(height: 12),
                  _ProfileIdentityPanel(profiles: profiles),
                  if (state.loadWarning != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.loadWarning!,
                      key: const ValueKey('profile-load-warning'),
                    ),
                  ],
                  if (state.profileError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.profileError!,
                      key: const ValueKey('profile-validation-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('day5-prompt'),
                    controller: _prompt,
                    enabled: !running,
                    minLines: 6,
                    maxLines: 14,
                    decoration: InputDecoration(
                      labelText: 'Общий запрос',
                      errorText: state.promptError,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('run-comparison'),
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
                      key: const ValueKey('day5-run-progress'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _ResultGrid(
                    state: state,
                    profiles: profiles,
                    isWide: isWide,
                    notes: _notes,
                    ratingEpoch: _ratingEpoch,
                    onRating: _controller.setRating,
                    onNote: (index, note) =>
                        _controller.setNote(laneIndex: index, note: note),
                  ),
                  const SizedBox(height: 16),
                  _SummaryPanel(
                    state: state,
                    conclusion: _conclusion,
                    enabled: !running,
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

class _GuidancePanel extends StatelessWidget {
  const _GuidancePanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('comparison-guidance'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Метки «слабая / средняя / сильная» — экспериментальные ярлыки, '
            'а не гарантированная оценка качества.',
            key: ValueKey('tier-caveat'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Порядок запуска, сеть, кэш и холодный старт локальной модели '
            'влияют на один прогон и не делают измерение научным.',
            key: ValueKey('warmup-limitation'),
          ),
          const SizedBox(height: 8),
          Text(
            'Настроенный провайдер получает этот запрос. Ключи не хранятся в '
            'JSON профилей и не показываются на экране.',
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
      'Сравнение выполняет ровно 3 API-вызова: по одному независимому '
      'запросу на каждый профиль без истории диалога и без native reasoning.',
      key: ValueKey('day5-three-call-cost'),
    );
  }
}

class _ProfileIdentityPanel extends StatelessWidget {
  const _ProfileIdentityPanel({required this.profiles});

  final List<ChatModelProfile> profiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < profiles.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          _IdentityCard(index: index, profile: profiles[index]),
        ],
      ],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.index, required this.profile});

  final int index;
  final ChatModelProfile profile;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('profile-identity-$index'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comparisonLaneTitle(profile),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            SelectableText(
              'хост: ${profile.endpointHost}',
              key: ValueKey('profile-host-$index'),
            ),
            SelectableText(
              'модель: ${profile.modelId}',
              key: ValueKey('profile-model-id-$index'),
            ),
            SelectableText(
              profile.sourceUrl.toString(),
              key: ValueKey('profile-source-url-$index'),
            ),
            if (profile.resourceNote.isNotEmpty)
              Text(
                'Ресурс профиля: ${profile.resourceNote} (не измеренные RAM/CPU).',
                key: ValueKey('profile-resource-note-$index'),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.state,
    required this.profiles,
    required this.isWide,
    required this.notes,
    required this.ratingEpoch,
    required this.onRating,
    required this.onNote,
  });

  final ComparisonExperimentState state;
  final List<ChatModelProfile> profiles;
  final bool isWide;
  final List<TextEditingController> notes;
  final int ratingEpoch;
  final void Function({
    required int laneIndex,
    required ComparisonRatingKind kind,
    required int? value,
  })
  onRating;
  final void Function(int index, String note) onNote;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (var index = 0; index < kComparisonLaneCount; index++)
        _ComparisonCard(
          key: ValueKey('comparison-card-$index'),
          index: index,
          lane: state.laneAt(index),
          configured: profiles[index],
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

class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({
    required this.index,
    required this.lane,
    required this.configured,
    required this.note,
    required this.ratingEpoch,
    required this.onRating,
    required this.onNote,
    super.key,
  });

  final int index;
  final ComparisonLaneState lane;
  final ChatModelProfile configured;
  final TextEditingController note;
  final int ratingEpoch;
  final void Function({
    required int laneIndex,
    required ComparisonRatingKind kind,
    required int? value,
  })
  onRating;
  final void Function(int index, String note) onNote;

  @override
  Widget build(BuildContext context) {
    final profile = lane.profile ?? configured;
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
                    comparisonLaneTitle(profile),
                    key: ValueKey('applied-profile-$index'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (lane.status == ComparisonLaneStatus.streaming)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (lane.status == ComparisonLaneStatus.completed)
                  const Icon(Icons.check_circle_outline, size: 20),
                if (lane.status == ComparisonLaneStatus.failed)
                  const Icon(Icons.error_outline, size: 20),
              ],
            ),
            SelectableText(
              '${profile.endpointHost} · ${profile.modelId}',
              key: ValueKey('applied-identity-$index'),
            ),
            SelectableText(
              profile.sourceUrl.toString(),
              key: ValueKey('applied-source-$index'),
            ),
            if (lane.answer.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                lane.answer,
                key: ValueKey('comparison-answer-$index'),
              ),
            ],
            if (lane.status == ComparisonLaneStatus.streaming &&
                !lane.hasOutput)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Ожидаем первые токены…'),
              ),
            if (lane.failure case final failure?) ...[
              const SizedBox(height: 8),
              Text(failure.message, key: ValueKey('comparison-error-$index')),
            ],
            const SizedBox(height: 8),
            Text(
              'Причина завершения: ${agentFinishReasonLabel(lane.finishReason)}',
              key: ValueKey('comparison-finish-$index'),
            ),
            Text(
              _usageLabel(lane.usage),
              key: ValueKey('comparison-usage-$index'),
            ),
            Text(
              'TTFT: ${formatDurationMs(lane.timeToFirstToken)}',
              key: ValueKey('comparison-ttft-$index'),
            ),
            Text(
              'Длительность: ${formatDurationMs(lane.totalDuration)}',
              key: ValueKey('comparison-duration-$index'),
            ),
            Text(
              'Оценка стоимости: ${lane.cost == null ? 'недоступно' : formatEstimatedCost(lane.cost!)}',
              key: ValueKey('comparison-cost-$index'),
            ),
            if (profile.pricing != null)
              SelectableText(
                'Тариф на ${formatPricingDate(profile.pricing!.effectiveDate)}: '
                '${profile.pricing!.sourceUrl}',
                key: ValueKey('comparison-pricing-source-$index'),
              ),
            if (profile.resourceNote.isNotEmpty)
              Text(
                'Метаданные ресурса: ${profile.resourceNote}. '
                'CPU, RAM, энергия и сеть не измерены.',
                key: ValueKey('comparison-resource-$index'),
              ),
            if (lane.checklist != null) ...[
              const SizedBox(height: 8),
              _ChecklistPanel(index: index, evidence: lane.checklist!),
            ],
            if (lane.isTerminal) ...[
              const SizedBox(height: 8),
              _RatingField(
                key: ValueKey('rating-correctness-$index-$ratingEpoch'),
                fieldKey: ValueKey('rating-correctness-$index'),
                label: 'Корректность',
                value: lane.evaluation.correctness,
                onChanged: (value) => onRating(
                  laneIndex: index,
                  kind: ComparisonRatingKind.correctness,
                  value: value,
                ),
              ),
              _RatingField(
                key: ValueKey('rating-completeness-$index-$ratingEpoch'),
                fieldKey: ValueKey('rating-completeness-$index'),
                label: 'Полнота',
                value: lane.evaluation.completeness,
                onChanged: (value) => onRating(
                  laneIndex: index,
                  kind: ComparisonRatingKind.completeness,
                  value: value,
                ),
              ),
              _RatingField(
                key: ValueKey('rating-usefulness-$index-$ratingEpoch'),
                fieldKey: ValueKey('rating-usefulness-$index'),
                label: 'Практическая польза',
                value: lane.evaluation.practicalUsefulness,
                onChanged: (value) => onRating(
                  laneIndex: index,
                  kind: ComparisonRatingKind.practicalUsefulness,
                  value: value,
                ),
              ),
              TextField(
                key: ValueKey('day5-note-$index'),
                controller: note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Заметка',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => onNote(index, value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _usageLabel(AgentTokenUsage? usage) {
    if (usage == null || usage.isEmpty) {
      return 'Токены: недоступно (не выводятся из длины текста).';
    }
    return 'Токены: prompt=${usage.promptTokens ?? 'недоступно'}, '
        'completion=${usage.completionTokens ?? 'недоступно'}, '
        'total=${usage.totalTokens ?? 'недоступно'}, '
        'cache-hit=${usage.cacheHitPromptTokens ?? 'недоступно'}, '
        'cache-miss=${usage.cacheMissPromptTokens ?? 'недоступно'}.';
  }
}

class _ChecklistPanel extends StatelessWidget {
  const _ChecklistPanel({required this.index, required this.evidence});

  final int index;
  final StructuralChecklistEvidence evidence;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      key: ValueKey('checklist-$index'),
      children: [
        Text(
          'Структурно-лексическая эвристика, не семантическая оценка:',
          key: ValueKey('checklist-disclaimer-$index'),
        ),
        Text('Dart-код: ${_yesNo(evidence.hasDartCode)}'),
        Text('sparse/dense: ${_yesNo(evidence.hasSparseDenseMapping)}'),
        Text('swap-remove: ${_yesNo(evidence.hasSwapRemove)}'),
        Text('O(1): ${_yesNo(evidence.hasConstantTime)}'),
        Text('component storage: ${_yesNo(evidence.hasComponentStorage)}'),
        Text('query: ${_yesNo(evidence.hasQuery)}'),
      ],
    );
  }

  static String _yesNo(bool value) => value ? 'есть' : 'нет';
}

class _RatingField extends StatelessWidget {
  const _RatingField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final Key fieldKey;
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<int?>(
        key: fieldKey,
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem<int?>(value: null, child: Text('Без оценки')),
          DropdownMenuItem<int?>(value: 1, child: Text('1')),
          DropdownMenuItem<int?>(value: 2, child: Text('2')),
          DropdownMenuItem<int?>(value: 3, child: Text('3')),
          DropdownMenuItem<int?>(value: 4, child: Text('4')),
          DropdownMenuItem<int?>(value: 5, child: Text('5')),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.state,
    required this.conclusion,
    required this.enabled,
  });

  final ComparisonExperimentState state;
  final TextEditingController conclusion;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fastest = state.fastestLaneProfile();
    return Container(
      key: const ValueKey('comparison-summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Сводка', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (fastest != null)
            Text(
              'Самая быстрая дорожка этого прогона: ${fastest.label} '
              '(только по измеренной длительности).',
              key: const ValueKey('fastest-lane'),
            )
          else
            const Text(
              'Универсальный победитель по длительности не объявляется, '
              'пока нет сопоставимых значений.',
              key: ValueKey('no-cost-winner'),
            ),
          const SizedBox(height: 8),
          const Text(
            'Универсальный победитель по токенам или стоимости не объявляется.',
            key: ValueKey('no-token-cost-winner'),
          ),
          if (_unavailableCostLabels(state).isNotEmpty)
            Text(
              'Недоступная стоимость: ${_unavailableCostLabels(state).join(', ')}.',
              key: const ValueKey('unavailable-cost-evidence'),
            ),
          const SizedBox(height: 8),
          for (var index = 0; index < state.lanes.length; index++)
            Text(
              _laneSummary(index, state.laneAt(index)),
              key: ValueKey('summary-lane-$index'),
            ),
          if (!_hasHumanScores(state))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Оцените корректность, полноту и практическую пользу. '
                'Автоматический победитель по качеству не выводится.',
                key: ValueKey('request-evaluation'),
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Один запрос и один ответ на модель не устанавливают общее качество, '
            'стабильную задержку или полную эффективность ресурсов.',
            key: ValueKey('single-run-limitation'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Цены — датированная оценка, а не счёт. Локальная модель не имеет '
            'платы провайдеру; железо и энергия не измерены.',
            key: ValueKey('pricing-limitation'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('day5-conclusion'),
            controller: conclusion,
            enabled: enabled && state.completedApiCalls > 0,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Короткий вывод',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Ссылки:'),
          for (var index = 0; index < state.profiles.length; index++)
            SelectableText(
              state.profiles[index].sourceUrl.toString(),
              key: ValueKey('summary-source-$index'),
            ),
        ],
      ),
    );
  }

  static bool _hasHumanScores(ComparisonExperimentState state) {
    return state.lanes.any((lane) => lane.evaluation.hasAnyScore);
  }

  static List<String> _unavailableCostLabels(ComparisonExperimentState state) {
    return [
      for (final lane in state.lanes)
        if (lane.isTerminal && lane.cost is UnavailableEstimatedCost)
          lane.profile?.label ?? 'дорожка',
    ];
  }

  static String _laneSummary(int index, ComparisonLaneState lane) {
    final profile = lane.profile;
    final name = profile?.label ?? 'дорожка ${index + 1}';
    final cost = lane.cost == null
        ? 'недоступно'
        : formatEstimatedCost(lane.cost!);
    return '$name: длительность ${formatDurationMs(lane.totalDuration)}, '
        'стоимость $cost, '
        'корректность ${comparisonRatingLabel(lane.evaluation.correctness)}, '
        'полнота ${comparisonRatingLabel(lane.evaluation.completeness)}, '
        'польза ${comparisonRatingLabel(lane.evaluation.practicalUsefulness)}'
        '${lane.evaluation.note.trim().isEmpty ? '' : ', заметка: ${lane.evaluation.note}'}';
  }
}
