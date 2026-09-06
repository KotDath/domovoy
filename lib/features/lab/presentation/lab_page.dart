import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../prompt/domain/agent.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../../settings/domain/model_settings.dart';
import '../../settings/presentation/api_key_settings_dialog.dart';
import '../../settings/presentation/reasoning_settings.dart';
import '../domain/format_contracts.dart';
import 'comparison_controller.dart';
import 'format_experiment_controller.dart';
import 'length_experiment_controller.dart';
import 'stop_experiment_controller.dart';

enum LabExperiment { format, length, stop }

class LabPage extends StatefulWidget {
  const LabPage({
    required this.agent,
    required this.overrideStore,
    required this.apiKeyResolver,
    required this.modelSettingsStore,
    this.reasoningSettings,
    this.isWeb = kIsWeb,
    super.key,
  });

  final Agent agent;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final ReasoningSettings? reasoningSettings;
  final bool isWeb;

  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> {
  LabExperiment _selected = LabExperiment.format;
  late final ReasoningSettings _reasoning;
  bool _ownsReasoning = false;

  late final FormatExperimentController _format;
  late final LengthExperimentController _length;
  late final StopExperimentController _stop;

  late final TextEditingController _formatPrompt;
  late final TextEditingController _jsonSpec;
  late final TextEditingController _markdownHeadings;
  late final TextEditingController _markdownCount;
  late final TextEditingController _lengthPrompt;
  late final TextEditingController _lengthChars;
  late final TextEditingController _lengthTokens;
  late final TextEditingController _stopPrompt;
  late final TextEditingController _stopMarker;

  @override
  void initState() {
    super.initState();
    final shared = widget.reasoningSettings;
    if (shared != null) {
      _reasoning = shared;
    } else {
      _ownsReasoning = true;
      _reasoning = ReasoningSettings(store: widget.modelSettingsStore);
    }
    _reasoning.addListener(_rebuild);
    _format = FormatExperimentController(widget.agent)..addListener(_rebuild);
    _length = LengthExperimentController(widget.agent)..addListener(_rebuild);
    _stop = StopExperimentController(widget.agent)..addListener(_rebuild);
    _formatPrompt = TextEditingController(text: _format.basePrompt);
    _jsonSpec = TextEditingController(
      text: 'title:string, summary:string, items:array:3',
    );
    _markdownHeadings = TextEditingController(text: 'Обзор, Выводы');
    _markdownCount = TextEditingController(text: '3');
    _lengthPrompt = TextEditingController(text: _length.basePrompt);
    _lengthChars = TextEditingController(text: _length.maxCharsText);
    _lengthTokens = TextEditingController(text: _length.maxTokensText);
    _stopPrompt = TextEditingController(text: _stop.basePrompt);
    _stopMarker = TextEditingController(text: _stop.markerText);
    unawaited(_reasoning.load());
  }

  @override
  void dispose() {
    _reasoning.removeListener(_rebuild);
    if (_ownsReasoning) {
      _reasoning.dispose();
    }
    _format
      ..removeListener(_rebuild)
      ..dispose();
    _length
      ..removeListener(_rebuild)
      ..dispose();
    _stop
      ..removeListener(_rebuild)
      ..dispose();
    _formatPrompt.dispose();
    _jsonSpec.dispose();
    _markdownHeadings.dispose();
    _markdownCount.dispose();
    _lengthPrompt.dispose();
    _lengthChars.dispose();
    _lengthTokens.dispose();
    _stopPrompt.dispose();
    _stopMarker.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Explicit refresh for when the laboratory becomes visible again, so a
  /// reasoning change made from the prompt workspace never stays stale.
  Future<void> refreshReasoning() => _reasoning.load();

  ThinkingMode get _thinking => _reasoning.reasoningEnabled
      ? ThinkingMode.enabled
      : ThinkingMode.disabled;

  Future<void> _openSettings() async {
    await showApiKeySettingsDialog(
      context: context,
      overrideStore: widget.overrideStore,
      resolver: widget.apiKeyResolver,
      isWeb: widget.isWeb,
      modelSettingsStore: widget.modelSettingsStore,
    );
    await _reasoning.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Лаборатория · День 2')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 900;
            return ListView(
              key: ValueKey(isWide ? 'wide-lab-layout' : 'narrow-lab-layout'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _ReasoningBanner(
                  loading: !_reasoning.isLoaded,
                  enabled: _reasoning.reasoningEnabled,
                  onOpenSettings: _openSettings,
                ),
                const SizedBox(height: 12),
                SegmentedButton<LabExperiment>(
                  key: const ValueKey('experiment-selector'),
                  segments: const [
                    ButtonSegment(
                      value: LabExperiment.format,
                      label: Text('Формат'),
                      icon: Icon(Icons.data_object),
                    ),
                    ButtonSegment(
                      value: LabExperiment.length,
                      label: Text('Длина'),
                      icon: Icon(Icons.straighten),
                    ),
                    ButtonSegment(
                      value: LabExperiment.stop,
                      label: Text('Стоп'),
                      icon: Icon(Icons.stop_circle_outlined),
                    ),
                  ],
                  selected: {_selected},
                  onSelectionChanged: (selection) {
                    setState(() => _selected = selection.first);
                  },
                ),
                const SizedBox(height: 16),
                if (_selected == LabExperiment.format)
                  _FormatSection(
                    controller: _format,
                    prompt: _formatPrompt,
                    jsonSpec: _jsonSpec,
                    markdownHeadings: _markdownHeadings,
                    markdownCount: _markdownCount,
                    thinking: _thinking,
                    isWide: isWide,
                  ),
                if (_selected == LabExperiment.length)
                  _LengthSection(
                    controller: _length,
                    prompt: _lengthPrompt,
                    maxChars: _lengthChars,
                    maxTokens: _lengthTokens,
                    thinking: _thinking,
                    reasoningEnabled: _reasoning.reasoningEnabled,
                    isWide: isWide,
                  ),
                if (_selected == LabExperiment.stop)
                  _StopSection(
                    controller: _stop,
                    prompt: _stopPrompt,
                    marker: _stopMarker,
                    thinking: _thinking,
                    isWide: isWide,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ReasoningBanner extends StatelessWidget {
  const _ReasoningBanner({
    required this.loading,
    required this.enabled,
    required this.onOpenSettings,
  });

  final bool loading;
  final bool enabled;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('reasoning-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.psychology_outlined, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: loading
                ? const Text('Загрузка настроек Reasoning…')
                : Text(
                    enabled
                        ? 'Reasoning: включено (thinking=enabled, high).'
                        : 'Reasoning: выключено (thinking=disabled).',
                    key: const ValueKey('reasoning-state'),
                  ),
          ),
          TextButton(
            key: const ValueKey('open-deepseek-settings'),
            onPressed: onOpenSettings,
            child: const Text('Настройки DeepSeek'),
          ),
        ],
      ),
    );
  }
}

// ---------- Format ----------

class _FormatSection extends StatelessWidget {
  const _FormatSection({
    required this.controller,
    required this.prompt,
    required this.jsonSpec,
    required this.markdownHeadings,
    required this.markdownCount,
    required this.thinking,
    required this.isWide,
  });

  final FormatExperimentController controller;
  final TextEditingController prompt;
  final TextEditingController jsonSpec;
  final TextEditingController markdownHeadings;
  final TextEditingController markdownCount;
  final ThinkingMode thinking;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final isJson = controller.formatKind == ResponseFormatKind.json;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Формат', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('format-prompt'),
          controller: prompt,
          enabled: !controller.isRunning && !controller.isRepairRunning,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: 'Базовый запрос',
            errorText: controller.promptError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<ResponseFormatKind>(
          key: const ValueKey('format-kind'),
          segments: const [
            ButtonSegment(value: ResponseFormatKind.json, label: Text('JSON')),
            ButtonSegment(
              value: ResponseFormatKind.markdown,
              label: Text('Markdown'),
            ),
          ],
          selected: {controller.formatKind},
          onSelectionChanged: controller.isRunning || controller.isRepairRunning
              ? null
              : (selection) {
                  controller.formatKind = selection.first;
                  controller.contractError = null;
                  // ignore: invalid_use_of_protected_member
                  controller.refresh();
                },
        ),
        const SizedBox(height: 12),
        if (isJson)
          TextField(
            key: const ValueKey('format-json-spec'),
            controller: jsonSpec,
            enabled: !controller.isRunning && !controller.isRepairRunning,
            decoration: InputDecoration(
              labelText: 'Контракт JSON (имя:тип[:количество], …)',
              hintText: 'title:string, summary:string, items:array:3',
              errorText: controller.contractError,
              border: const OutlineInputBorder(),
            ),
          )
        else ...[
          TextField(
            key: const ValueKey('format-markdown-headings'),
            controller: markdownHeadings,
            enabled: !controller.isRunning && !controller.isRepairRunning,
            decoration: InputDecoration(
              labelText: 'Заголовки через запятую (по порядку)',
              hintText: 'Обзор, Выводы',
              errorText: controller.contractError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<MarkdownListKind>(
                  key: const ValueKey('format-markdown-list-kind'),
                  segments: const [
                    ButtonSegment(
                      value: MarkdownListKind.unordered,
                      label: Text('Маркированный'),
                    ),
                    ButtonSegment(
                      value: MarkdownListKind.ordered,
                      label: Text('Нумерованный'),
                    ),
                  ],
                  selected: {_markdownKind()},
                  onSelectionChanged:
                      controller.isRunning || controller.isRepairRunning
                      ? null
                      : (selection) {
                          controller.markdownContract = MarkdownFormatContract(
                            headings: controller.markdownContract.headings,
                            listKind: selection.first,
                            expectedItems:
                                controller.markdownContract.expectedItems,
                          );
                          // ignore: invalid_use_of_protected_member
                          controller.refresh();
                        },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: TextField(
                  key: const ValueKey('format-markdown-count'),
                  controller: markdownCount,
                  enabled: !controller.isRunning && !controller.isRepairRunning,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Пунктов',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('run-format'),
          onPressed: controller.isRunning || controller.isRepairRunning
              ? null
              : () => _runFormat(),
          icon: controller.isRunning
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(
            controller.isRunning
                ? 'Выполнение… (${controller.costLabel})'
                : 'Сравнить (2 API-вызова)',
          ),
        ),
        const SizedBox(height: 16),
        _ResultPair(
          baseline: controller.baseline,
          controlled: controller.controlled,
          isWide: isWide,
          baselineExtra: _FormatEvidence(
            validation: controller.baselineValidation,
            answer: controller.baseline.answer,
            completed:
                controller.baseline.status == ExperimentLaneStatus.completed,
          ),
          controlledExtra: _FormatEvidence(
            validation: controller.controlledValidation,
            answer: controller.answerForTestHook,
            completed:
                controller.controlled.status == ExperimentLaneStatus.completed,
          ),
          controlledFooter: _RepairBlock(controller: controller),
          appliedControl: controller.appliedControlLabel,
          baselineTitle: 'Без ограничений',
          controlledTitle: 'С контролем',
          onToggleBaseline: controller.toggleBaselineReasoning,
          onToggleControlled: controller.toggleControlledReasoning,
        ),
        const SizedBox(height: 12),
        const _ConclusionCard(
          key: ValueKey('conclusion-format'),
          text:
              'Вывод: подсказка и JSON-режим влияют на поведение, но не гарантируют схему. '
              'Контракт проверяет приложение, а «Исправить формат» делает один явный повтор.',
        ),
      ],
    );
  }

  MarkdownListKind _markdownKind() => controller.markdownContract.listKind;

  void _runFormat() {
    if (controller.formatKind == ResponseFormatKind.json) {
      final parsed = parseJsonSpec(jsonSpec.text);
      if (parsed.error != null) {
        controller.contractError = parsed.error;
        // ignore: invalid_use_of_protected_member
        controller.refresh();
        return;
      }
      controller.jsonContract = parsed.contract!;
    } else {
      final headings = parseHeadings(markdownHeadings.text);
      final count = int.tryParse(markdownCount.text.trim());
      if (headings.isEmpty) {
        controller.contractError = 'Добавьте хотя бы один заголовок.';
        // ignore: invalid_use_of_protected_member
        controller.refresh();
        return;
      }
      if (count == null || count <= 0) {
        controller.contractError =
            'Количество пунктов должно быть положительным числом.';
        // ignore: invalid_use_of_protected_member
        controller.refresh();
        return;
      }
      if (count > maxSupportedCollectionCount) {
        controller.contractError =
            'Количество пунктов не должно превышать '
            '$maxSupportedCollectionCount.';
        // ignore: invalid_use_of_protected_member
        controller.refresh();
        return;
      }
      controller.markdownContract = MarkdownFormatContract(
        headings: headings,
        listKind: controller.markdownContract.listKind,
        expectedItems: count,
      );
    }
    controller.runComparison(rawPrompt: prompt.text, thinking: thinking);
  }
}

extension on FormatExperimentController {
  String get answerForTestHook => controlled.answer;
}

final class ParsedJsonSpec {
  const ParsedJsonSpec({this.contract, this.error});

  final JsonFormatContract? contract;
  final String? error;
}

ParsedJsonSpec parseJsonSpec(String raw) {
  final parts = raw
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return const ParsedJsonSpec(
      error: 'Добавьте хотя бы одно обязательное поле.',
    );
  }
  final fields = <JsonFieldSpec>[];
  for (final part in parts) {
    final segments = part.split(':').map((s) => s.trim()).toList();
    if (segments.isEmpty || segments.first.isEmpty) {
      return const ParsedJsonSpec(error: 'Имя поля не должно быть пустым.');
    }
    final name = segments[0];
    final type = segments.length > 1 && segments[1].isNotEmpty
        ? parseJsonFieldType(segments[1])
        : JsonFieldType.string;
    if (type == null) {
      return ParsedJsonSpec(
        error:
            'Поле "$name": неизвестный тип "${segments[1]}". '
            'Допустимо: string, integer, number, boolean, array, object.',
      );
    }
    int? expected;
    if (segments.length > 2 && segments[2].isNotEmpty) {
      expected = int.tryParse(segments[2]);
      if (expected == null || expected <= 0) {
        return ParsedJsonSpec(
          error:
              'Поле "$name": ожидаемое количество должно быть положительным.',
        );
      }
      if (expected > maxSupportedCollectionCount) {
        return ParsedJsonSpec(
          error:
              'Поле "$name": количество не должно превышать '
              '$maxSupportedCollectionCount.',
        );
      }
      if (type != JsonFieldType.array && type != JsonFieldType.object) {
        return ParsedJsonSpec(
          error:
              'Поле "$name": количество поддерживается только для array/object.',
        );
      }
    }
    if (segments.length > 3) {
      return ParsedJsonSpec(
        error: 'Поле "$name": используйте формат имя:тип[:количество].',
      );
    }
    fields.add(JsonFieldSpec(name: name, type: type, expectedCount: expected));
  }
  final contract = JsonFormatContract(fields: fields);
  final contractError = contract.validateContract();
  if (contractError != null) {
    return ParsedJsonSpec(error: contractError);
  }
  return ParsedJsonSpec(contract: contract);
}

List<String> parseHeadings(String raw) {
  return raw
      .split(RegExp(r'[,\n]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

class _FormatEvidence extends StatelessWidget {
  const _FormatEvidence({
    required this.validation,
    required this.answer,
    required this.completed,
  });

  final Object? validation;
  final String answer;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    if (!completed) {
      return const SizedBox.shrink();
    }
    final result = validation as dynamic;
    if (result == null) {
      return const SizedBox.shrink();
    }
    final valid = result.valid as bool;
    final diagnostics = (result.diagnostics as List).cast<String>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          valid ? 'Валидация: корректно.' : 'Валидация: некорректно.',
          key: ValueKey(
            'format-validation-${valid ? 'valid' : 'invalid'}-${answer.hashCode}',
          ),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (diagnostics.isNotEmpty) ...diagnostics.map((d) => Text('• $d')),
      ],
    );
  }
}

class _RepairBlock extends StatelessWidget {
  const _RepairBlock({required this.controller});

  final FormatExperimentController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.controlled.status != ExperimentLaneStatus.completed) {
      return const SizedBox.shrink();
    }
    if (controller.repairUnnecessary) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Ремонт не требуется: ответ соответствует контракту.',
          key: ValueKey('repair-unnecessary'),
        ),
      );
    }
    if (!controller.repairAvailable &&
        !controller.repairAttempted &&
        controller.controlledValidation == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (controller.repairAvailable)
          FilledButton.tonalIcon(
            key: const ValueKey('repair-format'),
            onPressed: () => controller.repair(),
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: const Text('Исправить формат (1 API-вызов)'),
          ),
        if (controller.repairAttempted) ...[
          const SizedBox(height: 8),
          _LaneCard(
            key: const ValueKey('repair-card'),
            title: 'После ремонта',
            lane: controller.repairLane,
            onToggleReasoning: controller.toggleRepairReasoning,
            footer: controller.repairedValidation == null
                ? const SizedBox.shrink()
                : _FormatEvidence(
                    validation: controller.repairedValidation,
                    answer: controller.repairLane.answer,
                    completed:
                        controller.repairLane.status ==
                        ExperimentLaneStatus.completed,
                  ),
          ),
          if (controller.repairLane.status == ExperimentLaneStatus.completed &&
              controller.repairedValidation != null &&
              !controller.repairedValidation!.valid)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Повтор не прошёл проверку. Автоматических повторов больше нет.',
                key: ValueKey('repair-exhausted'),
              ),
            ),
        ],
      ],
    );
  }
}

// ---------- Length ----------

class _LengthSection extends StatelessWidget {
  const _LengthSection({
    required this.controller,
    required this.prompt,
    required this.maxChars,
    required this.maxTokens,
    required this.thinking,
    required this.reasoningEnabled,
    required this.isWide,
  });

  final LengthExperimentController controller;
  final TextEditingController prompt;
  final TextEditingController maxChars;
  final TextEditingController maxTokens;
  final ThinkingMode thinking;
  final bool reasoningEnabled;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final tokens = int.tryParse(maxTokens.text.trim());
    final showWarning =
        reasoningEnabled &&
        tokens != null &&
        tokens < LengthLimits.reasoningBudgetWarningTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Длина', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('length-prompt'),
          controller: prompt,
          enabled: !controller.isRunning,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: 'Базовый запрос',
            errorText: controller.promptError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('length-max-chars'),
                controller: maxChars,
                enabled: !controller.isRunning,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Макс. символов',
                  errorText: controller.maxCharsError,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('length-max-tokens'),
                controller: maxTokens,
                enabled: !controller.isRunning,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Макс. токенов',
                  errorText: controller.maxTokensError,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        if (showWarning)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Внимание: при включённом Reasoning токены мышления расходуют лимит. '
              'Настройка не меняется автоматически.',
              key: ValueKey('reasoning-budget-warning'),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('run-length'),
          onPressed: controller.isRunning
              ? null
              : () => controller.runComparison(
                  rawPrompt: prompt.text,
                  rawMaxChars: maxChars.text,
                  rawMaxTokens: maxTokens.text,
                  thinking: thinking,
                ),
          icon: controller.isRunning
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(
            controller.isRunning
                ? 'Выполнение… (${controller.costLabel})'
                : 'Сравнить (2 API-вызова)',
          ),
        ),
        const SizedBox(height: 16),
        _ResultPair(
          baseline: controller.baseline,
          controlled: controller.controlled,
          isWide: isWide,
          baselineExtra: _LengthEvidence(
            lane: controller.baseline,
            maxChars: null,
            maxTokens: null,
            truncated: controller.baselineTruncated,
          ),
          controlledExtra: _LengthEvidence(
            lane: controller.controlled,
            maxChars: controller.activeMaxChars,
            maxTokens: controller.activeMaxTokens,
            truncated: controller.controlledTruncated,
          ),
          appliedControl: controller.activeMaxChars == null
              ? '—'
              : 'инструкция ${controller.activeMaxChars} символов + max_tokens=${controller.activeMaxTokens}',
          baselineTitle: 'Без ограничений',
          controlledTitle: 'С контролем',
          onToggleBaseline: controller.toggleBaselineReasoning,
          onToggleControlled: controller.toggleControlledReasoning,
        ),
        const SizedBox(height: 12),
        const _ConclusionCard(
          key: ValueKey('conclusion-length'),
          text:
              'Вывод: инструкция про символы — поведенческая, max_tokens — жёсткий потолок токенов с возможной обрезкой. '
              'Точное соответствие требует проверки в приложении.',
        ),
      ],
    );
  }
}

class _LengthEvidence extends StatelessWidget {
  const _LengthEvidence({
    required this.lane,
    required this.maxChars,
    required this.maxTokens,
    required this.truncated,
  });

  final ExperimentLaneState lane;
  final int? maxChars;
  final int? maxTokens;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    if (lane.status != ExperimentLaneStatus.completed &&
        lane.status != ExperimentLaneStatus.failed) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Символов: ${lane.charCount}'),
        if (maxChars != null) Text('Цель: не более $maxChars символов.'),
        if (maxTokens != null) Text('Потолок: $maxTokens токенов.'),
        if (lane.finishReason != null)
          Text(
            'Причина завершения: ${agentFinishReasonLabel(lane.finishReason)}',
          ),
        if (lane.usage != null && !(lane.usage!.isEmpty))
          Text(
            'Токены: prompt=${lane.usage!.promptTokens ?? '—'}, '
            'completion=${lane.usage!.completionTokens ?? '—'}, '
            'total=${lane.usage!.totalTokens ?? '—'}.',
          ),
        if (truncated)
          const Text(
            'Ответ обрезан потолком токенов и не заявляет соответствие цели.',
            key: ValueKey('length-truncated'),
          ),
      ],
    );
  }
}

// ---------- Stop ----------

class _StopSection extends StatelessWidget {
  const _StopSection({
    required this.controller,
    required this.prompt,
    required this.marker,
    required this.thinking,
    required this.isWide,
  });

  final StopExperimentController controller;
  final TextEditingController prompt;
  final TextEditingController marker;
  final ThinkingMode thinking;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Стоп', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('stop-prompt'),
          controller: prompt,
          enabled: !controller.isRunning,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: 'Запрос с инструкцией про маркер',
            errorText: controller.promptError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('stop-marker'),
          controller: marker,
          enabled: !controller.isRunning,
          decoration: InputDecoration(
            labelText: 'Точный стоп-маркер',
            hintText: '<END_OF_ANSWER>',
            errorText: controller.markerError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('run-stop'),
          onPressed: controller.isRunning
              ? null
              : () => controller.runComparison(
                  rawPrompt: prompt.text,
                  rawMarker: marker.text,
                  thinking: thinking,
                ),
          icon: controller.isRunning
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(
            controller.isRunning
                ? 'Выполнение… (${controller.costLabel})'
                : 'Сравнить (2 API-вызова)',
          ),
        ),
        const SizedBox(height: 16),
        _ResultPair(
          baseline: controller.baseline,
          controlled: controller.controlled,
          isWide: isWide,
          baselineExtra: _StopEvidenceView(
            lane: controller.baseline,
            marker: controller.activeMarker ?? controller.markerText,
          ),
          controlledExtra: _StopEvidenceView(
            lane: controller.controlled,
            marker: controller.activeMarker ?? controller.markerText,
          ),
          appliedControl: controller.activeMarker == null
              ? '—'
              : 'stop=["${controller.activeMarker}"]',
          baselineTitle: 'Без ограничений',
          controlledTitle: 'С контролем',
          onToggleBaseline: controller.toggleBaselineReasoning,
          onToggleControlled: controller.toggleControlledReasoning,
        ),
        const SizedBox(height: 12),
        const _ConclusionCard(
          key: ValueKey('conclusion-stop'),
          text:
              'Вывод: стоп-последовательность завершает генерацию, только если модель вывела точный маркер; совпавший маркер в ответ не возвращается. '
              'Отсутствие маркера само по себе не доказывает сбой или срабатывание настройки — модель могла его не вывести; такой исход остаётся валидным свидетельством.',
        ),
      ],
    );
  }
}

class _StopEvidenceView extends StatelessWidget {
  const _StopEvidenceView({required this.lane, required this.marker});

  final ExperimentLaneState lane;
  final String marker;

  @override
  Widget build(BuildContext context) {
    if (lane.status != ExperimentLaneStatus.completed &&
        lane.status != ExperimentLaneStatus.failed) {
      return const SizedBox.shrink();
    }
    final evidence = stopEvidenceFor(lane.answer, marker);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Маркер "$marker": ${evidence.containsMarker ? 'есть' : 'нет'}.'),
        Text(
          'Текст после маркера: ${evidence.containsPostMarkerText ? 'есть' : 'нет'}.',
        ),
        Text(
          'Фраза «$stopPostMarkerSentence»: '
          '${evidence.containsPostMarkerSentence ? 'есть' : 'нет'}.',
          key: const ValueKey('stop-post-marker-sentence'),
        ),
        if (lane.finishReason != null)
          Text(
            'Причина завершения: ${agentFinishReasonLabel(lane.finishReason)}',
          ),
        if (lane.usage != null && !(lane.usage!.isEmpty))
          Text(
            'Токены: prompt=${lane.usage!.promptTokens ?? '—'}, '
            'completion=${lane.usage!.completionTokens ?? '—'}, '
            'total=${lane.usage!.totalTokens ?? '—'}.',
          ),
      ],
    );
  }
}

// ---------- Shared result widgets ----------

class _ResultPair extends StatelessWidget {
  const _ResultPair({
    required this.baseline,
    required this.controlled,
    required this.isWide,
    required this.baselineExtra,
    required this.controlledExtra,
    this.controlledFooter = const SizedBox.shrink(),
    required this.appliedControl,
    required this.baselineTitle,
    required this.controlledTitle,
    required this.onToggleBaseline,
    required this.onToggleControlled,
  });

  final ExperimentLaneState baseline;
  final ExperimentLaneState controlled;
  final bool isWide;
  final Widget baselineExtra;
  final Widget controlledExtra;
  final Widget controlledFooter;
  final String appliedControl;
  final String baselineTitle;
  final String controlledTitle;
  final VoidCallback onToggleBaseline;
  final VoidCallback onToggleControlled;

  @override
  Widget build(BuildContext context) {
    final baselineCard = _LaneCard(
      key: const ValueKey('baseline-card'),
      title: baselineTitle,
      lane: baseline,
      onToggleReasoning: onToggleBaseline,
      footer: baselineExtra,
    );
    final controlledCard = _LaneCard(
      key: const ValueKey('controlled-card'),
      title: controlledTitle,
      lane: controlled,
      onToggleReasoning: onToggleControlled,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          controlledExtra,
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Применённый контроль: $appliedControl',
              key: const ValueKey('applied-control'),
            ),
          ),
          controlledFooter,
        ],
      ),
    );
    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: baselineCard),
          const SizedBox(width: 12),
          Expanded(child: controlledCard),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [baselineCard, const SizedBox(height: 12), controlledCard],
    );
  }
}

class _LaneCard extends StatelessWidget {
  const _LaneCard({
    required this.title,
    required this.lane,
    required this.onToggleReasoning,
    this.footer = const SizedBox.shrink(),
    super.key,
  });

  final String title;
  final ExperimentLaneState lane;
  final VoidCallback onToggleReasoning;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (lane.status == ExperimentLaneStatus.streaming)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (lane.status == ExperimentLaneStatus.completed)
                  const Icon(Icons.check_circle_outline, size: 20),
                if (lane.status == ExperimentLaneStatus.failed)
                  const Icon(Icons.error_outline, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            if (lane.reasoning.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: onToggleReasoning,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Expanded(child: Text('Ход рассуждений')),
                            Icon(
                              lane.reasoningExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (lane.reasoningExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        child: SelectableText(lane.reasoning),
                      ),
                  ],
                ),
              ),
            if (lane.answer.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(lane.answer),
            ],
            if (lane.status == ExperimentLaneStatus.streaming &&
                !lane.hasOutput)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Ожидаем первые токены…'),
              ),
            if (lane.failure case final failure?) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  failure.message,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
            footer,
          ],
        ),
      ),
    );
  }
}

class _ConclusionCard extends StatelessWidget {
  const _ConclusionCard({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
