import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';
import '../../chat/application/chat_run_preparer.dart';

final class RagChatController extends ChangeNotifier
    implements ChatRunPreparer {
  RagChatController({
    required this.coordinator,
    required this.traces,
    required this.registry,
    this.dynamicContext,
  });
  final RagTurnCoordinator coordinator;
  final RagTraceRepository traces;
  final LlmProviderRegistry registry;
  final AgentDynamicContextProvider? dynamicContext;
  bool enabled = false;
  bool neutralEvaluation = false;
  String corpus = 'domovoy';
  ChunkStrategy strategy = ChunkStrategy.structure;
  bool busy = false;
  String progress = '';
  String? error;
  String? _project, _session;
  List<Map<String, dynamic>> history = [];
  int _epoch = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void configure({
    bool? enabled,
    bool? neutral,
    String? corpus,
    ChunkStrategy? strategy,
  }) {
    if (busy) return;
    this.enabled = enabled ?? this.enabled;
    neutralEvaluation = neutral ?? neutralEvaluation;
    this.corpus = corpus ?? this.corpus;
    this.strategy = strategy ?? this.strategy;
    _notify();
  }

  Future<void> attach(AgentSessionSnapshot? snapshot) async {
    final project = snapshot?.projectId?.value ?? 'default';
    final session = snapshot?.id.value;
    if (project == _project && session == _session) return;
    final epoch = ++_epoch;
    _project = project;
    _session = session;
    history = [];
    error = null;
    _notify();
    if (session == null) return;
    try {
      final loaded = await traces.list(project, session);
      if (_disposed || epoch != _epoch) return;
      history = loaded;
      _notify();
    } on Object {
      if (_disposed || epoch != _epoch) return;
      error = 'Не удалось прочитать сохранённые RAG-трассы';
      _notify();
    }
  }

  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async {
    if (!enabled && !neutralEvaluation) return null;
    final useRag = enabled;
    final neutral = neutralEvaluation;
    final selectedCorpus = corpus;
    final selectedStrategy = strategy;
    final project = snapshot.projectId?.value ?? 'default';
    final session = snapshot.id.value;
    final model = registry.resolve(snapshot.selection.model).model;
    final output = min(2048, model.outputBound);
    final mode =
        model.capabilities.reasoning == ModelReasoningCapability.required
        ? ReasoningMode.enabled
        : ReasoningMode.disabled;
    final prompt = neutral
        ? ragAnswerInstructions
        : '${snapshot.definition.systemPrompt}\n\n$ragAnswerInstructions';
    final id = ragHash(
      '$project|$session|${DateTime.now().microsecondsSinceEpoch}|'
      '${Random.secure().nextInt(1 << 32)}',
    );
    final total = Stopwatch()..start();
    var attempt = 0;
    final attemptIds = <String>[];
    busy = true;
    progress = 'Подготовка контекста…';
    error = null;
    _notify();
    try {
      final dynamic = neutral
          ? null
          : await dynamicContext?.provide(
              AgentDynamicContextRequest(
                sessionId: snapshot.id,
                projectId: snapshot.projectId,
                query: input,
              ),
            );
      checkRagCancellation(cancellation.isCancelled);
      final frozenPrompt = [
        prompt,
        if (dynamic != null) dynamic.systemPromptText,
      ].join('\n\n');
      final baseRequest = LlmRequest(
        model: snapshot.selection.model,
        context: LlmContext(
          systemPrompt: frozenPrompt,
          messages: [
            ...snapshot.transcript.messages,
            LlmMessage(role: LlmMessageRole.user, parts: [LlmTextPart(input)]),
          ],
        ),
        generation: LlmGenerationConfig(
          reasoningMode: mode,
          temperature: snapshot.definition.generation.temperature,
          maxOutputTokens: output,
        ),
      );
      // Conservative complete request envelope: history, profile, memory,
      // protocol framing and output all consume the same provider budget.
      final maxBytes = model.contextBound - output - 1024;
      final baseBytes = utf8
          .encode(jsonEncode(baseRequest.snapshot().toJson()))
          .length;
      final prepared = await coordinator.prepare(
        RagTurnRequest(
          id: id,
          project: project,
          session: session,
          query: input,
          corpus: selectedCorpus,
          strategy: selectedStrategy,
          protocol: useRag ? RagProtocol.m1 : RagProtocol.m0,
          // Escaping the context as a JSON request adds overhead; a second
          // full-request check happens immediately before transport.
          contextByteBudget: min(24000, maxBytes - baseBytes - 2048),
        ),
        cancellation,
      );
      checkRagCancellation(cancellation.isCancelled);
      progress = 'Найдено источников: ${prepared.evidence.length}';
      _notify();
      return ChatPreparedRun(
        recordCompletedTurn: !neutral,
        options: AgentRunOptions(
          maxModelTurns: QuotaOverride.value(1),
          maxToolCalls: QuotaOverride.value(0),
          maxOutputTokensPerTurn: QuotaOverride.value(output),
          reasoning: AgentReasoningOverride(
            mode: mode,
            effort: ReasoningEffort.modelDefault,
          ),
          preparedContext: AgentPreparedContext(
            systemPromptOverride: prompt,
            suppressDynamicContext: true,
            disableTools: true,
            maxRequestBytes: maxBytes,
            contribution: AgentDynamicContext(
              systemPromptText: [
                if (dynamic != null) dynamic.systemPromptText,
                prepared.context,
              ].where((s) => s.isNotEmpty).join('\n\n'),
              audit: prepared,
            ),
            beforeRequest: (request, token) async {
              checkRagCancellation(token.isCancelled);
              final attemptId = '$id-${attempt++}';
              final requestJson = request.toJson();
              // Private reasoning/continuation payloads must not enter traces.
              final safeMessages = [
                for (final message in request.context.messages)
                  {
                    'role': message.role.name,
                    'text': [
                      for (final part in message.parts)
                        if (part is LlmTextPart) part.text,
                    ].join('\n'),
                  },
              ];
              await traces.saveRequest(project, session, attemptId, {
                ...prepared.toJson(),
                'id': attemptId,
                'session_revision_at_admission': snapshot.revision,
                'neutral_evaluation': neutral,
                'request': {
                  'model': request.model.toJson(),
                  'generation': request.generation.toJson(),
                  'system_prompt': request.context.systemPrompt,
                  'messages': safeMessages,
                  'tools_count': request.context.tools.length,
                  'continuation_count':
                      request.context.continuationEntries.length,
                  'sha256': ragHash(jsonEncode(requestJson)),
                  'utf8_bytes': utf8.encode(jsonEncode(requestJson)).length,
                  'max_utf8_bytes': maxBytes,
                  'reasoning_payloads': 'omitted',
                },
                'created_at_utc': DateTime.now().toUtc().toIso8601String(),
              });
              attemptIds.add(attemptId);
              checkRagCancellation(token.isCancelled);
            },
          ),
        ),
        onSettled: (settled, terminal) async {
          final ledger = settled.tokenAccounting.ledger
              .skip(snapshot.tokenAccounting.ledger.length)
              .toList();
          try {
            for (var i = 0; i < attemptIds.length; i++) {
              final attemptId = attemptIds[i];
              final last = i < ledger.length ? ledger[i].entry : null;
              final accepted =
                  last?.outcome == AgentModelInvocationOutcome.completed &&
                  last?.responseMessageId != null;
              await traces.saveCompletion(project, session, attemptId, {
                'terminal': terminal.runtimeType.toString(),
                'invocation_outcome': last?.outcome.name,
                'accepted_message_id': accepted
                    ? last?.responseMessageId?.value
                    : null,
                'provider_attempt_id': last?.attemptId.value,
                'usage': last?.usage.toJson(),
                'elapsed_ms': total.elapsedMilliseconds,
                'answer': accepted
                    ? settled.transcript.messages.last.parts
                          .whereType<LlmTextPart>()
                          .map((p) => p.text)
                          .join('')
                    : null,
              });
            }
            if (!_disposed && _project == project && _session == session) {
              history = await traces.list(project, session);
              _notify();
            }
          } on Object {
            final accepted = ledger.any(
              (item) =>
                  item.entry.outcome == AgentModelInvocationOutcome.completed &&
                  item.entry.responseMessageId != null,
            );
            error = accepted
                ? 'Ответ сохранён в истории, но связь с источниками '
                      'не удалось сохранить. Трасса запроса сохранена отдельно.'
                : 'Не удалось сохранить результат попытки в RAG-трассе. '
                      'Трасса запроса сохранена отдельно.';
            _notify();
          } finally {
            busy = false;
            progress = terminal is AgentRunCompleted
                ? 'Ответ завершён'
                : terminal is AgentRunCancelled || terminal == null
                ? 'Подготовка или ответ отменены'
                : 'Ответ не завершён';
            _notify();
          }
        },
      );
    } on Object {
      busy = false;
      progress = cancellation.isCancelled ? 'Подготовка отменена' : '';
      _notify();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
