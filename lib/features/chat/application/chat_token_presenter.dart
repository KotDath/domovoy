import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';

enum ChatTokenValueState { available, partial, inconsistent, unavailable }

final class ChatTokenValue {
  const ChatTokenValue({
    required this.label,
    required this.display,
    required this.state,
    this.provenanceLabel,
    this.explanation,
  });

  final String label;
  final String display;
  final ChatTokenValueState state;
  final String? provenanceLabel;
  final String? explanation;
}

final class ChatTokenGroup {
  ChatTokenGroup({
    required this.key,
    required this.title,
    required List<ChatTokenValue> values,
    this.modelLabel,
    this.correlationLabel,
    this.note,
  }) : values = List<ChatTokenValue>.unmodifiable(values);

  final String key;
  final String title;
  final String? modelLabel;
  final String? correlationLabel;
  final String? note;
  final List<ChatTokenValue> values;
}

final class ChatTokenProjection {
  ChatTokenProjection({
    required this.summaryLabel,
    required List<ChatTokenGroup> primaryGroups,
    required List<ChatTokenGroup> supplementaryGroups,
  }) : primaryGroups = List<ChatTokenGroup>.unmodifiable(primaryGroups),
       supplementaryGroups = List<ChatTokenGroup>.unmodifiable(
         supplementaryGroups,
       );

  final String summaryLabel;
  final List<ChatTokenGroup> primaryGroups;
  final List<ChatTokenGroup> supplementaryGroups;
}

/// Pure, read-only adapter over the runtime's committed accounting projection.
final class ChatTokenPresenter {
  const ChatTokenPresenter();

  ChatTokenProjection present({
    required AgentTokenAccountingSnapshot accounting,
    required LlmModel selectedModel,
  }) {
    final request = accounting.currentRequest;
    final response = accounting.latestResponse;
    final history = _aggregateGroup(
      key: 'history',
      title: 'Вся история и работа сессии',
      aggregate: accounting.session,
      note: accounting.legacyBaseline.isEmpty
          ? null
          : 'Включает legacy-объём без атрибуции.',
    );
    final requestInput = request?.usage.requestContext?.value;
    final responseOutput = response?.usage.responseGenerated?.value;
    final historyOverall = accounting.session.overall.contributorCount == 0
        ? null
        : accounting.session.overall.value;
    final shortValues = <String>[
      if (requestInput != null) 'запрос $requestInput',
      if (responseOutput != null) 'ответ $responseOutput',
      if (historyOverall != null) 'история $historyOverall',
    ];
    return ChatTokenProjection(
      summaryLabel: shortValues.isEmpty ? 'Токены —' : shortValues.join(' · '),
      primaryGroups: <ChatTokenGroup>[
        _usageGroup(
          key: 'current-request',
          title: request?.active == true
              ? 'Текущий запрос'
              : 'Последний запрос',
          usage: request?.usage,
          model: request?.model,
          correlation: request == null
              ? null
              : '${request.runId.value} / ${request.attemptId.value}',
          unavailableNote: 'Запросы модели ещё не выполнялись.',
        ),
        history,
        _usageGroup(
          key: 'latest-response',
          title: 'Последний подтверждённый ответ модели',
          usage: response?.usage,
          model: response?.model,
          correlation: response == null
              ? null
              : '${response.responseMessageId.value} / '
                    '${response.attemptId.value}',
          unavailableNote: 'Подтверждённого ответа модели ещё нет.',
        ),
      ],
      supplementaryGroups: <ChatTokenGroup>[
        _aggregateGroup(
          key: 'assistant-conversation',
          title: 'Ответы ассистента',
          aggregate: accounting.assistantConversation,
        ),
        _aggregateGroup(
          key: 'compaction',
          title: 'Сжатие контекста',
          aggregate: accounting.compaction,
        ),
        for (final entry in accounting.byModel.entries)
          _aggregateGroup(
            key:
                'model:${entry.key.providerId.value}:${entry.key.modelId.value}',
            title: 'По модели',
            aggregate: entry.value.session,
            model: entry.key,
          ),
      ],
    );
  }
}

ChatTokenGroup _usageGroup({
  required String key,
  required String title,
  required LlmUsage? usage,
  required ModelRef? model,
  required String? correlation,
  required String unavailableNote,
}) {
  return ChatTokenGroup(
    key: key,
    title: title,
    modelLabel: model?.toString(),
    correlationLabel: correlation,
    note: usage == null ? unavailableNote : null,
    values: <ChatTokenValue>[
      _metric('Ввод', usage?.requestContext),
      _metric('Вывод', usage?.responseGenerated),
      _metric('Рассуждение', usage?.reasoning),
      _metric('Чтение кэша', usage?.cacheRead),
      _metric('Запись кэша', usage?.cacheWrite),
      _ratio('Попадание в кэш', usage?.cacheHitRatio),
      _metric('Всего', usage?.overall),
      _metric('Ввод без кэша', usage?.input),
      _metric('Вывод без рассуждения', usage?.output),
    ],
  );
}

ChatTokenGroup _aggregateGroup({
  required String key,
  required String title,
  required AgentUsageAggregate aggregate,
  ModelRef? model,
  String? note,
}) {
  return ChatTokenGroup(
    key: key,
    title: title,
    modelLabel: model?.toString(),
    note: note,
    values: <ChatTokenValue>[
      _aggregate('Ввод', aggregate.requestContext),
      _aggregate('Вывод', aggregate.responseGenerated),
      _aggregate('Рассуждение', aggregate.reasoning),
      _aggregate('Чтение кэша', aggregate.cacheRead),
      _aggregate('Запись кэша', aggregate.cacheWrite),
      _aggregateRatio('Попадание в кэш', aggregate),
      _aggregate('Всего', aggregate.overall),
      _aggregate('Ввод без кэша', aggregate.input),
      _aggregate('Вывод без рассуждения', aggregate.output),
    ],
  );
}

ChatTokenValue _metric(
  String label,
  LlmUsageMetric? metric, {
  String explanation = 'Провайдер не сообщил значение.',
}) {
  if (metric == null) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state: ChatTokenValueState.unavailable,
      explanation: explanation,
    );
  }
  return ChatTokenValue(
    label: label,
    display: metric.value.toString(),
    state: ChatTokenValueState.available,
    provenanceLabel: _provenance(metric.provenance),
  );
}

ChatTokenValue _ratio(String label, LlmUsageRatio? ratio) {
  if (ratio == null || !ratio.value.isFinite) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state: ChatTokenValueState.unavailable,
      explanation: 'Недостаточно данных для доли кэша.',
    );
  }
  return ChatTokenValue(
    label: label,
    display: '${(ratio.value * 100).toStringAsFixed(1)}%',
    state: ChatTokenValueState.available,
    provenanceLabel: _provenance(ratio.provenance),
  );
}

ChatTokenValue _aggregate(
  String label,
  AgentUsageDimensionAggregate dimension,
) {
  if (dimension.contributorCount == 0) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state: ChatTokenValueState.unavailable,
      explanation: 'Вызовов провайдера ещё не было.',
    );
  }
  if (dimension.inconsistentContributorCount > 0 &&
      dimension.knownContributorCount == 0) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state: ChatTokenValueState.inconsistent,
      explanation:
          'Противоречивых источников: '
          '${dimension.inconsistentContributorCount}.',
    );
  }
  if (dimension.completeness == LlmUsageCompleteness.unavailable) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state: ChatTokenValueState.unavailable,
      explanation: 'Нет доступных вкладов.',
    );
  }
  if (dimension.completeness == LlmUsageCompleteness.partial) {
    return ChatTokenValue(
      label: label,
      display: '${dimension.knownSubtotal}+',
      state: ChatTokenValueState.partial,
      provenanceLabel: 'частично · из данных провайдера',
      explanation:
          'Нет значения для ${dimension.missingContributorCount} вкладов; '
          'противоречивых: ${dimension.inconsistentContributorCount}.',
    );
  }
  return ChatTokenValue(
    label: label,
    display: dimension.knownSubtotal.toString(),
    state: ChatTokenValueState.available,
    provenanceLabel: 'вычислено из данных провайдера',
  );
}

ChatTokenValue _aggregateRatio(String label, AgentUsageAggregate aggregate) {
  final ratio = aggregate.cacheHitRatio;
  if (ratio == null) {
    return ChatTokenValue(
      label: label,
      display: '—',
      state:
          aggregate.cacheRead.inconsistentContributorCount > 0 ||
              aggregate.requestContext.inconsistentContributorCount > 0
          ? ChatTokenValueState.inconsistent
          : ChatTokenValueState.unavailable,
      explanation: 'Полная доля кэша недоступна.',
    );
  }
  return _ratio(label, ratio);
}

String _provenance(LlmUsageMetricProvenance provenance) => switch (provenance) {
  LlmUsageMetricProvenance.providerReported => 'сообщено провайдером',
  LlmUsageMetricProvenance.derivedFromProvider =>
    'вычислено из данных провайдера',
  LlmUsageMetricProvenance.estimated => 'оценка',
};
