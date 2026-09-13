import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/agents/agents.dart';
import '../core/llm/llm.dart';
import 'day09_compaction.dart';
import 'day09_dependencies.dart';
import 'day09_scenario.dart';
import 'day09_session_pointer.dart';

final class Day09UsageView {
  Day09UsageView(AgentSessionSnapshot snapshot)
    : assistant = AgentUsageAggregate.fromUsages(
        snapshot.tokenAccounting.ledger
            .map((view) => view.entry)
            .where(
              (entry) =>
                  entry.operationKind == AgentModelOperationKind.assistant,
            )
            .map((entry) => entry.usage),
      ),
      summary = AgentUsageAggregate.fromUsages(
        snapshot.tokenAccounting.ledger
            .map((view) => view.entry)
            .where(
              (entry) =>
                  entry.operationKind == AgentModelOperationKind.compaction,
            )
            .map((entry) => entry.usage),
      ),
      total = AgentUsageAggregate.fromUsages(
        snapshot.tokenAccounting.ledger.map((view) => view.entry.usage),
      ),
      latestAnswerRequest = snapshot.tokenAccounting.ledger
          .map((view) => view.entry)
          .where(
            (entry) =>
                entry.operationKind == AgentModelOperationKind.assistant &&
                entry.outcome == AgentModelInvocationOutcome.completed,
          )
          .lastOrNull
          ?.usage
          .requestContext;

  final AgentUsageAggregate assistant;
  final AgentUsageAggregate summary;
  final AgentUsageAggregate total;
  final LlmUsageMetric? latestAnswerRequest;
}

final class Day09MessageView {
  const Day09MessageView({required this.role, required this.text});
  final LlmMessageRole role;
  final String text;
}

final class Day09ComparisonController extends ChangeNotifier {
  Day09ComparisonController({
    required this.dependencies,
    required this.pointerStore,
    required this.steps,
  });

  final Day09DemoDependencies dependencies;
  final Day09PairPointerStore pointerStore;
  final List<Day09ScenarioStep> steps;

  AgentSession? _baseline;
  AgentSession? _summarized;
  Day09PairIds? _ids;
  var _busy = false;
  var _ready = false;
  var _disposed = false;
  var _completedSteps = 0;
  var _needsReset = false;
  String status = 'Загрузка истории…';
  String? error;

  bool get busy => _busy;
  bool get ready => _ready;
  bool get needsReset => _needsReset;
  int get completedSteps => _completedSteps;
  AgentSessionSnapshot? get baselineSnapshot => _baseline?.snapshot;
  AgentSessionSnapshot? get summarizedSnapshot => _summarized?.snapshot;
  Day09PairIds? get pairIds => _ids;

  Future<void> initialize() async {
    if (_busy || _ready) return;
    _set(busy: true, status: 'Восстанавливаем два чата…', error: null);
    try {
      await dependencies.baseline.providerModelCatalog?.initialize();
      await dependencies.summarized.providerModelCatalog?.initialize();
      final existing = await pointerStore.read();
      if (existing == null) {
        await _createFreshPair();
      } else {
        _ids = existing;
        _baseline = await dependencies.baseline.runtime
            .agent(_definition('baseline'))
            .restoreSession(existing.baseline);
        _summarized = await dependencies.summarized.runtime
            .agent(_definition('summary'))
            .restoreSession(existing.summarized);
      }
      _syncProgress();
      _ready = true;
      _set(
        busy: false,
        status: _needsReset
            ? 'Истории разошлись; начните новый сценарий.'
            : 'Готово · шаг $_completedSteps из ${steps.length}',
      );
    } on Object {
      _needsReset = true;
      _set(
        busy: false,
        error: 'Не удалось восстановить демонстрацию. Начните новый сценарий.',
        status: 'Нужен новый сценарий',
      );
    }
  }

  Future<void> runNext() => _runSteps(all: false);
  Future<void> runAll() => _runSteps(all: true);

  Future<void> _runSteps({required bool all}) async {
    if (!_ready || _busy || _needsReset || _completedSteps >= steps.length) {
      return;
    }
    _set(busy: true, error: null);
    try {
      do {
        final index = _completedSteps;
        final step = steps[index];
        _set(status: 'Шаг ${index + 1}/${steps.length}: без сжатия…');
        await _runSession(_baseline!, step.prompt);
        _set(status: 'Шаг ${index + 1}/${steps.length}: с summary…');
        await _runSession(_summarized!, step.prompt);
        _syncProgress();
        if (_needsReset || _completedSteps != index + 1) {
          throw StateError('Day 9 sessions diverged.');
        }
        _set(status: 'Готово · шаг $_completedSteps из ${steps.length}');
      } while (all && _completedSteps < steps.length);
    } on _Day09ProviderFailure catch (failure) {
      _syncProgress();
      _needsReset = true;
      _set(
        error: failure.message,
        status: 'Шаг прерван; сохранённые вызовы и расход видны ниже.',
      );
    } on Object {
      _syncProgress();
      _needsReset = true;
      _set(
        error: 'Не удалось завершить шаг. Сохранённые вызовы не потеряны.',
        status: 'Шаг прерван; начните новый сценарий.',
      );
    } finally {
      _set(busy: false);
    }
  }

  Future<void> reset() async {
    if (_busy) return;
    _set(busy: true, error: null, status: 'Создаём новый сценарий…');
    try {
      await _baseline?.close();
      await _summarized?.close();
      _baseline = null;
      _summarized = null;
      final old = _ids ?? await pointerStore.read();
      if (old != null) {
        await _deleteIfPresent(old.baseline);
        await _deleteIfPresent(old.summarized);
      }
      await _createFreshPair();
      _completedSteps = 0;
      _needsReset = false;
      _ready = true;
      _set(busy: false, status: 'Готово · шаг 0 из ${steps.length}');
    } on Object {
      _needsReset = true;
      _set(
        busy: false,
        status: 'Не удалось сбросить сценарий',
        error: 'Проверьте доступность хранилища и попробуйте снова.',
      );
    }
  }

  Future<void> _createFreshPair() async {
    final next = Day09PairIds.fresh();
    final baseline = await dependencies.baseline.runtime
        .agent(_definition('baseline'))
        .createSession(
          id: next.baseline,
          persistence: SessionPersistence.repository,
        );
    final summarized = await dependencies.summarized.runtime
        .agent(_definition('summary'))
        .createSession(
          id: next.summarized,
          persistence: SessionPersistence.repository,
        );
    await pointerStore.write(next);
    _ids = next;
    _baseline = baseline;
    _summarized = summarized;
  }

  Future<void> _deleteIfPresent(AgentSessionId id) async {
    final record = await dependencies.repository.load(id);
    if (record == null) return;
    await dependencies.repository.delete(
      id,
      expectedRevision: record.revision,
      cancellation: CancellationSource().token,
    );
  }

  Future<void> _runSession(AgentSession session, String prompt) async {
    final events = await session.run(prompt).events.toList();
    final terminal = events.lastOrNull;
    if (terminal is AgentRunCompleted) return;
    if (terminal is AgentRunFailed && terminal.error.safeProviderMessage) {
      throw _Day09ProviderFailure(terminal.error.message);
    }
    if (terminal is AgentRunFailed &&
        terminal.error.kind == AgentErrorKind.compaction) {
      throw const _Day09ProviderFailure(
        'Не удалось создать корректное summary. Уже завершённые API-вызовы '
        'и их расход сохранены; начните новый сценарий.',
      );
    }
    throw const _Day09ProviderFailure(
      'Шаг не завершился. Уже подтверждённые API-вызовы и расход сохранены.',
    );
  }

  void _syncProgress() {
    final baseline = _baseline?.snapshot;
    final summarized = _summarized?.snapshot;
    if (baseline == null || summarized == null) {
      _completedSteps = 0;
      _needsReset = true;
      return;
    }
    final baselineRaw = _rawCount(baseline.transcript.messages);
    final state = summarized.compactionState;
    final currentTail = summarized.transcript.messages.skip(
      state?.generatedPrefixEnd ?? 0,
    );
    final summaryTailRaw = _rawCount(currentTail);
    final total =
        state?.decisionMetadata[Day09MessageCadenceTrigger.rawTotalKey];
    final retained =
        state?.decisionMetadata[Day09MessageCadenceTrigger.retainedRawKey];
    final summaryRaw = state == null
        ? summaryTailRaw
        : (total is int &&
                  retained is int &&
                  total >= 0 &&
                  retained >= 0 &&
                  summaryTailRaw >= retained
              ? total + summaryTailRaw - retained
              : -1);
    _completedSteps = baselineRaw ~/ 2;
    final savedPrompts = baseline.transcript.messages
        .where((message) => message.role == LlmMessageRole.user)
        .map(
          (message) => message.parts
              .whereType<LlmTextPart>()
              .map((part) => part.text)
              .join(),
        )
        .toList();
    final scenarioMatches =
        savedPrompts.length == _completedSteps &&
        _completedSteps <= steps.length &&
        List<bool>.generate(
          _completedSteps,
          (index) => savedPrompts[index] == steps[index].prompt,
        ).every((same) => same);
    _needsReset =
        baselineRaw.isOdd ||
        summaryRaw.isOdd ||
        summaryRaw < 0 ||
        summaryRaw != baselineRaw ||
        _completedSteps > steps.length ||
        !scenarioMatches;
  }

  static int _rawCount(Iterable<LlmMessage> messages) => messages
      .where(
        (message) =>
            message.role == LlmMessageRole.user ||
            message.role == LlmMessageRole.assistant,
      )
      .length;

  AgentDefinition _definition(String mode) => AgentDefinition(
    id: AgentId('day09-$mode-agent-v1'),
    name: 'Day 9 ${mode == 'baseline' ? 'baseline' : 'summary'}',
    systemPrompt:
        'Ты помогаешь составить ТЗ сервиса записи в мастерскую. Сохраняй '
        'согласованные решения и отвечай кратко, если пользователь не просит '
        'итоговое ТЗ. Не придумывай отсутствующие факты.',
    model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
    generation: LlmGenerationConfig(
      reasoningMode: ReasoningMode.disabled,
      maxOutputTokens: 768,
    ),
    limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
  );

  String latestAnswer(AgentSessionSnapshot? snapshot) {
    if (snapshot == null) return '';
    for (final message in snapshot.transcript.messages.reversed) {
      if (message.role != LlmMessageRole.assistant) continue;
      final text = message.parts
          .whereType<LlmTextPart>()
          .map((part) => part.text)
          .join();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String savedSummary() {
    final snapshot = _summarized?.snapshot;
    final state = snapshot?.compactionState;
    if (snapshot == null || state == null) return '';
    final raw = snapshot.transcript.messages
        .skip(state.generatedPrefixStart)
        .take(state.generatedPrefixCount)
        .expand((message) => message.parts.whereType<LlmTextPart>())
        .map((part) => part.text)
        .join('\n');
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on FormatException {
      return raw;
    }
  }

  List<Day09MessageView> rawTail() {
    final snapshot = _summarized?.snapshot;
    if (snapshot == null) return const <Day09MessageView>[];
    final start = snapshot.compactionState?.generatedPrefixEnd ?? 0;
    return List<Day09MessageView>.unmodifiable(
      snapshot.transcript.messages
          .skip(start)
          .map(
            (message) => Day09MessageView(
              role: message.role,
              text: message.parts
                  .whereType<LlmTextPart>()
                  .map((part) => part.text)
                  .join(),
            ),
          ),
    );
  }

  void _set({bool? busy, String? status, String? error}) {
    if (_disposed) return;
    if (busy != null) _busy = busy;
    if (status != null) this.status = status;
    if (error != null || busy == true) this.error = error;
    notifyListeners();
  }

  Future<void> close() async {
    _disposed = true;
    await _baseline?.close();
    await _summarized?.close();
    await dependencies.close();
    super.dispose();
  }
}

final class _Day09ProviderFailure implements Exception {
  const _Day09ProviderFailure(this.message);
  final String message;
}
