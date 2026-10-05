import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';
import '../../../core/rag/retrieval.dart';
import '../../../core/rag/grounding.dart';
import '../../chat/application/chat_run_preparer.dart';
import 'rag_final_answer_gate.dart';

typedef RagQueryRewriterFactory =
    RagQueryRewriter Function(
      ModelRef model,
      Future<void> Function(Map<String, Object?>) beforeRequest,
      Future<void> Function(RagRewriteResult) afterResult,
    );

final class RagChatController extends ChangeNotifier
    implements ChatRunPreparer {
  RagChatController({
    required this.coordinator,
    required this.traces,
    required this.registry,
    this.dynamicContext,
    this.queryRewriterFactory,
    this.defaultRetrieval = const RagRetrievalConfig(),
    this.strictGrounding = false,
  }) : retrieval = defaultRetrieval,
       strategy = defaultRetrieval.strategy ?? ChunkStrategy.structure;
  final RagTurnCoordinator coordinator;
  final RagTraceRepository traces;
  final LlmProviderRegistry registry;
  final AgentDynamicContextProvider? dynamicContext;
  final RagQueryRewriterFactory? queryRewriterFactory;
  bool enabled = false;
  bool neutralEvaluation = false;
  bool strictGrounding;
  RagGroundingFault groundingFault = RagGroundingFault.none;
  RagProtocol protocol = RagProtocol.m1;
  final RagRetrievalConfig defaultRetrieval;
  RagRetrievalConfig retrieval;
  String corpus = 'domovoy';
  ChunkStrategy strategy;
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
    RagProtocol? protocol,
    RagRetrievalConfig? retrieval,
    bool? strictGrounding,
    RagGroundingFault? groundingFault,
  }) {
    if (busy) return;
    this.enabled = enabled ?? this.enabled;
    neutralEvaluation = neutral ?? neutralEvaluation;
    this.corpus = corpus ?? this.corpus;
    this.strategy = strategy ?? this.strategy;
    this.protocol = protocol ?? this.protocol;
    this.retrieval = retrieval ?? this.retrieval;
    this.strictGrounding = strictGrounding ?? this.strictGrounding;
    this.groundingFault = groundingFault ?? this.groundingFault;
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
    final selectedProtocol = protocol;
    final selectedRetrieval = retrieval;
    final neutral = neutralEvaluation;
    final selectedCorpus = corpus;
    final selectedStrategy = strategy;
    final grounded = useRag && strictGrounding;
    final selectedFault = groundingFault;
    if (useRag &&
        (selectedProtocol == RagProtocol.m3 ||
            selectedProtocol == RagProtocol.m4) &&
        selectedRetrieval.rewriteModel != null &&
        selectedRetrieval.rewriteModel !=
            '${snapshot.selection.model.providerId.value}/${snapshot.selection.model.modelId.value}') {
      throw StateError(
        'Для этого профиля калибровки выберите исходную модель rewrite '
        '${selectedRetrieval.rewriteModel}, либо явно задайте экспериментальные пороги.',
      );
    }
    final project = snapshot.projectId?.value ?? 'default';
    final session = snapshot.id.value;
    final model = registry.resolve(snapshot.selection.model).model;
    final output = min(2048, model.outputBound);
    final mode =
        model.capabilities.reasoning == ModelReasoningCapability.required
        ? ReasoningMode.enabled
        : ReasoningMode.disabled;
    final instruction = grounded
        ? ragGroundedAnswerInstruction
        : ragAnswerInstructions;
    final prompt = neutral
        ? instruction
        : '${snapshot.definition.systemPrompt}\n\n$instruction';
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
          protocol: useRag ? selectedProtocol : RagProtocol.m0,
          retrieval: selectedRetrieval,
          // Escaping the context as a JSON request adds overhead; a second
          // full-request check happens immediately before transport.
          contextByteBudget: min(24000, maxBytes - baseBytes - 2048),
        ),
        cancellation,
        rewriter: queryRewriterFactory?.call(
          snapshot.selection.model,
          (request) async {
            await traces.saveRequest(project, session, '$id-rewrite', {
              'version': 1,
              'id': '$id-rewrite',
              'project': project,
              'session': session,
              'query': input,
              'corpus': selectedCorpus,
              'strategy': selectedStrategy.name,
              'protocol': 'query_rewrite',
              'candidates': [],
              'request': {
                'model': request['model'],
                'generation': request['generation'],
                'system_prompt': (request['context'] as Map)['systemPrompt'],
                'tools_count': 0,
                'sha256': ragHash(jsonEncode(request)),
                'messages': (request['context'] as Map)['messages'],
              },
            });
          },
          (result) async {
            // A provider failure before request publication has no receipt.
            final rows = await traces.list(project, session);
            if (!rows.any((r) => r['id'] == '$id-rewrite')) return;
            await traces.saveCompletion(project, session, '$id-rewrite', {
              'terminal': result.fallbackReason ?? 'RewriteCompleted',
              'accepted_message_id': null,
              'usage': result.audit['usage'],
              'elapsed_ms': result.audit['elapsed_ms'],
              'rewritten_query': result.query,
            });
          },
        ),
      );
      checkRagCancellation(cancellation.isCancelled);
      progress = 'Найдено источников: ${prepared.evidence.length}';
      _notify();
      if (grounded && prepared.evidence.isEmpty) {
        return await _prepareHostAbstention(
          prepared,
          snapshot,
          neutral,
          total,
          cancellation,
        );
      }
      final gate = grounded
          ? RagFinalAnswerGate(
              turn: prepared,
              fault: selectedFault,
              persistDiagnostic: (diagnostic) => traces.saveDiagnostic(
                project,
                session,
                attemptIds.last,
                diagnostic,
              ),
            )
          : null;
      return ChatPreparedRun(
        recordCompletedTurn: !neutral && !grounded,
        options: AgentRunOptions(
          maxModelTurns: QuotaOverride.value(grounded ? 2 : 1),
          finalAnswerGate: gate,
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
                'strict_grounding': grounded,
                'fault_injection': selectedFault.name,
                'answer_attempt_ordinal': attempt - 1,
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
              .where(
                (item) =>
                    item.entry.operationKind ==
                    AgentModelOperationKind.assistant,
              )
              .toList();
          try {
            for (var i = 0; i < attemptIds.length; i++) {
              final attemptId = attemptIds[i];
              final last = i < ledger.length ? ledger[i].entry : null;
              final accepted =
                  last?.outcome == AgentModelInvocationOutcome.completed &&
                  last?.responseMessageId != null;
              final responseIndex = settled.transcript.messageIds.indexOf(
                last?.responseMessageId,
              );
              await traces.saveCompletion(project, session, attemptId, {
                'terminal': terminal.runtimeType.toString(),
                'invocation_outcome': last?.outcome.name,
                'accepted_message_id': accepted
                    ? last?.responseMessageId?.value
                    : null,
                'provider_attempt_id': last?.attemptId.value,
                'usage': last?.usage.toJson(),
                'elapsed_ms': total.elapsedMilliseconds,
                if (accepted && gate?.accepted != null)
                  'grounding': gate!.accepted!.toJson(),
                'answer': accepted
                    ? gate?.accepted?.render() ??
                          (responseIndex >= 0
                              ? settled.transcript.messages[responseIndex].parts
                                    .whereType<LlmTextPart>()
                                    .map((p) => p.text)
                                    .join('')
                              : null)
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

  Future<ChatPreparedRun> _prepareHostAbstention(
    RagPreparedTurn prepared,
    AgentSessionSnapshot before,
    bool neutral,
    Stopwatch total,
    CancellationToken cancellation,
  ) async {
    final project = prepared.request.project,
        session = prepared.request.session;
    final attemptId = '${prepared.request.id}-host';
    await traces.saveRequest(project, session, attemptId, {
      ...prepared.toJson(),
      'id': attemptId,
      'session_revision_at_admission': before.revision,
      'neutral_evaluation': neutral,
      'strict_grounding': true,
      'reason': 'insufficient_evidence',
      'physical_answer_requests': 0,
      'request': {
        'kind': 'host_response_without_answer_model',
        'model': null,
        'generation': null,
        'system_prompt': '',
        'messages': <Object?>[],
        'tools_count': 0,
        'continuation_count': 0,
        'utf8_bytes': 0,
      },
      'created_at_utc': DateTime.now().toUtc().toIso8601String(),
    });
    checkRagCancellation(cancellation.isCancelled);
    return ChatPreparedRun(
      recordCompletedTurn: false,
      options: AgentRunOptions(
        respondWithoutModel: AgentRespondWithoutModel(
          ragInsufficientEvidenceAnswer,
        ),
      ),
      onSettled: (settled, terminal) async {
        final accepted =
            terminal is AgentRunCompleted &&
            settled.transcript.messages.length ==
                before.transcript.messages.length + 2 &&
            settled.transcript.messages.last.role == LlmMessageRole.assistant;
        try {
          await traces.saveCompletion(project, session, attemptId, {
            'terminal': terminal.runtimeType.toString(),
            'reason': 'insufficient_evidence',
            'physical_answer_requests': 0,
            'usage': null,
            'accepted_message_id': accepted
                ? settled.transcript.messageIds.last?.value
                : null,
            'elapsed_ms': total.elapsedMilliseconds,
            'answer': accepted ? ragInsufficientEvidenceAnswer : null,
            'grounding': {
              'status': 'abstained',
              'claims': <Object?>[],
              'quote_validation': 'no_evidence',
              'semantic_entailment': 'not_applicable',
            },
          });
          if (!_disposed && _project == project && _session == session) {
            history = await traces.list(project, session);
          }
        } on Object {
          error = 'Не удалось сохранить результат отказа в RAG-трассе.';
        } finally {
          busy = false;
          progress = accepted
              ? 'Отказ: недостаточно данных'
              : 'Ответ не сохранён';
          _notify();
        }
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
