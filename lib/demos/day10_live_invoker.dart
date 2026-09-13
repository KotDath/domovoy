import '../core/agents/agents.dart';
import '../core/llm/llm.dart';
import 'day10_engine.dart';
import 'demo_dependencies.dart';

/// A fresh transient agent per request; the facade owns durable demo history.
final class Day10LiveInvoker implements Day10Invoker {
  Day10LiveInvoker(this.dependencies);
  final DemoDependencies dependencies;

  @override
  Future<Day10CallResult> call({
    required Day10Branch branch,
    required String prompt,
    required List<LlmMessage> initialMessages,
    required String systemPrompt,
  }) async {
    final definition = AgentDefinition(
      id: AgentId('day10-${branch.id}'),
      name: 'Day 10 ${branch.label}',
      systemPrompt: systemPrompt,
      model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
      initialMessages: initialMessages,
      generation: LlmGenerationConfig(
        reasoningMode: ReasoningMode.disabled,
        maxOutputTokens: 768,
      ),
      limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
    );
    final answer = StringBuffer();
    AgentRunEvent? terminal;
    await for (final event
        in dependencies.stack.runtime.agent(definition).run(prompt).events) {
      if (event is AgentAnswerDelta) answer.write(event.text);
      if (event.isTerminal) terminal = event;
    }
    final accounting = switch (terminal) {
      AgentRunCompleted(:final tokenAccounting) => tokenAccounting,
      AgentRunFailed(:final tokenAccounting) => tokenAccounting,
      AgentRunStopped(:final tokenAccounting) => tokenAccounting,
      AgentRunCancelled(:final tokenAccounting) => tokenAccounting,
      _ => null,
    };
    final physical = [
      for (final view in accounting?.ledger ?? <AgentModelUsageEntryView>[])
        if (view.entry.operationKind == AgentModelOperationKind.assistant)
          Day10Physical(view.entry.usage, view.entry.outcome.name),
    ];
    return switch (terminal) {
      AgentRunCompleted() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'completed',
        physical: physical,
      ),
      AgentRunFailed(:final error) => Day10CallResult(
        answer: answer.toString(),
        outcome: 'failed',
        physical: physical,
        error: error.safeProviderMessage
            ? error.message
            : 'Провайдер не завершил запрос.',
      ),
      AgentRunCancelled() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'cancelled',
        physical: physical,
        error: 'Запрос отменён.',
      ),
      AgentRunStopped() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'stopped',
        physical: physical,
        error: 'Запрос остановлен.',
      ),
      _ => Day10CallResult(
        answer: answer.toString(),
        outcome: 'failed',
        physical: physical,
        error: 'Не получен результат запроса.',
      ),
    };
  }
}
