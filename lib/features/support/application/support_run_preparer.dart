import 'package:flutter/foundation.dart';
import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/rag/contracts.dart';
import '../../../core/rag/index_builder.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';
import '../../../core/support/support.dart';
import '../../../core/support/manual.dart';
import '../../chat/application/chat_run_preparer.dart';
import 'support_context_precondition.dart';

/// A namespace in a dedicated repository, independent of any checkout/project.
const supportRagProject = 'product-support';
const supportRagCorpus = 'manual';

final class SupportRunPreparer extends ChangeNotifier
    implements ChatRunPreparer {
  SupportRunPreparer({
    required this.tickets,
    required this.scopes,
    required this.repository,
    required this.models,
    required this.ensureMcpReady,
    required this.mcpReady,
    required this.traces,
    required this.loadManual,
  });
  final SupportRepository tickets;
  final SupportRunScopes scopes;
  final RagRepository repository;
  final RagModelProvider models;
  final RagTraceRepository traces;
  final Future<void> Function() ensureMcpReady;
  final bool Function() mcpReady;
  final SupportManualLoader loadManual;
  bool busy = false;
  String progress = 'Ещё не проверено';
  String? error;
  String? fingerprint;
  DateTime? modelObservedAt;
  String packageVersion = 'Неизвестна';
  RagPreparedTurn? evidence;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadMetadata() async {
    packageVersion = (await loadManual()).packageVersion;
  }

  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async {
    if (_disposed || !isSupportSession(snapshot.id)) {
      throw const ChatPreparationException('Это не диалог поддержки.');
    }
    if (busy) {
      throw const ChatPreparationException(
        'Подготовка поддержки уже выполняется.',
      );
    }
    busy = true;
    error = null;
    evidence = null;
    _notify();
    AgentRunToolContext? context;
    try {
      final matching = (await tickets.list())
          .where((t) => t.sessionId == snapshot.id && t.ready)
          .toList();
      if (matching.length != 1) throw StateError('Обращение не найдено');
      final ticket = matching.single;
      if (ticket.status == SupportStatus.resolved) {
        throw const ChatPreparationException(
          'Сначала повторно откройте обращение.',
        );
      }
      checkRagCancellation(cancellation.isCancelled);
      progress = 'Проверка руководства и модели эмбеддингов';
      _notify();
      final manual = await loadManual();
      final model = await models.health(cancellation);
      modelObservedAt = DateTime.now();
      fingerprint = model.fingerprint;
      final identity = ragIndexIdentity(
        manual.documents,
        model,
        ChunkStrategy.structure,
        manual.revision,
      );
      final existing = await repository.loadIndex(
        supportRagProject,
        supportRagCorpus,
        ChunkStrategy.structure,
      );
      checkRagCancellation(cancellation.isCancelled);
      if (existing?.generation != identity) {
        final index = await buildRagIndex(
          models: models,
          model: model,
          documents: manual.documents,
          strategy: ChunkStrategy.structure,
          cancellation: cancellation,
          revisionScope: manual.revision,
          progress: (stage, done, total) {
            progress =
                '${stage == 'chunking' ? 'Разбиение руководства' : 'Эмбеддинги'}: $done / $total';
            _notify();
          },
        );
        checkRagCancellation(cancellation.isCancelled);
        await repository.saveDocuments(
          supportRagProject,
          supportRagCorpus,
          manual.documents,
        );
        checkRagCancellation(cancellation.isCancelled);
        await repository.publishIndex(
          supportRagProject,
          supportRagCorpus,
          index,
        );
      }
      progress = 'Поиск по руководству';
      _notify();
      final turn =
          await RagTurnCoordinator(
            repository: repository,
            models: models,
          ).prepare(
            RagTurnRequest(
              id: newSupportId(),
              project: supportRagProject,
              session: snapshot.id.value,
              query: '${ticket.subject}\n$input',
              corpus: supportRagCorpus,
              strategy: ChunkStrategy.structure,
              protocol: RagProtocol.m1,
              contextByteBudget: 24000,
            ),
            cancellation,
          );
      if (turn.evidence.isEmpty) {
        throw const ChatPreparationException(
          'Руководство не дало фрагментов для ответа. Уточните вопрос.',
        );
      }
      evidence = turn;
      progress = 'Подключение MCP поддержки';
      _notify();
      await ensureMcpReady();
      checkRagCancellation(cancellation.isCancelled);
      if (!mcpReady()) {
        throw const ChatPreparationException(
          'MCP поддержки недоступен. Проверьте MCP-подключения и повторите.',
        );
      }
      await traces.saveRequest(
        supportRagProject,
        snapshot.id.value,
        turn.request.id,
        turn.toJson(),
      );
      checkRagCancellation(cancellation.isCancelled);
      context = scopes.begin(ticket);
      final issued = context;
      progress = 'Руководство готово · M1 / Structure';
      return ChatPreparedRun(
        recordCompletedTurn: false,
        options: AgentRunOptions(
          toolContext: issued,
          additionalEnabledTools: supportToolIds.map(ToolId.new),
          preparedContext: AgentPreparedContext(
            systemPromptOverride: supportInstructions,
            suppressDynamicContext: true,
            isolateCurrentRun: true,
            allowedToolIds: supportToolIds,
            beforeFinalAnswer: (draft, token) async {
              try {
                requireSupportContext(draft, scopes, issued, ticket, token);
              } on AgentException catch (failure) {
                if (failure.error.kind == AgentErrorKind.protocol) {
                  error = failure.error.message;
                  _notify();
                }
                rethrow;
              }
            },
            contribution: AgentDynamicContext(
              systemPromptText: '$ragAnswerInstructions\n${turn.context}',
            ),
          ),
        ),
        onSettled: (finalSnapshot, terminal) async {
          scopes.end(issued);
          await traces.saveCompletion(
            supportRagProject,
            snapshot.id.value,
            turn.request.id,
            {
              'terminal': terminal.runtimeType.toString(),
              'revision': finalSnapshot.revision,
              'transcriptMessages': finalSnapshot.transcript.messages.length,
            },
          );
        },
      );
    } on Object catch (failure) {
      if (context != null) scopes.end(context);
      if (cancellation.isCancelled || failure is RagCancelled) {
        progress = 'Подготовка отменена';
        rethrow;
      }
      error = failure is ChatPreparationException
          ? failure.message
          : 'Не удалось подготовить поддержку на этапе «$progress». Проверьте сервис эмбеддингов и MCP-подключения, затем повторите. Данные обращения сохранены.';
      progress = 'Подготовка не завершена';
      throw ChatPreparationException(error!);
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    scopes.clear();
    super.dispose();
  }
}
