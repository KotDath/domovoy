import '../core/agents/agents.dart';
import '../core/llm/llm.dart';
import 'day10_engine.dart';
import 'demo_dependencies.dart';

/// A fresh transient agent per request; the facade owns durable demo history.
final class Day10AgentConfig {
  Day10AgentConfig({ModelRef? model, LlmGenerationConfig? generation})
    : model = model ?? BuiltInLlmCatalog.deepSeekFlashModel.ref,
      generation =
          generation ??
          LlmGenerationConfig(
            reasoningMode: ReasoningMode.disabled,
            maxOutputTokens: 1536,
          );
  final ModelRef model;
  final LlmGenerationConfig generation;

  AgentDefinition definitionFor({
    required Day10Branch branch,
    required String role,
    required List<LlmMessage> initialMessages,
    required String systemPrompt,
  }) => AgentDefinition(
    id: AgentId('day10-$role-${branch.id}'),
    name: 'Day 10 $role ${branch.label}',
    systemPrompt: systemPrompt,
    model: model,
    initialMessages: initialMessages,
    generation: generation,
    limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
  );
}

final class Day10LiveInvoker implements Day10Invoker {
  Day10LiveInvoker(this.dependencies, {Day10AgentConfig? config})
    : config = config ?? Day10AgentConfig();
  final DemoDependencies dependencies;
  final Day10AgentConfig config;

  @override
  Future<Day10CallResult> call({
    required Day10Branch branch,
    required String role,
    required String prompt,
    required List<LlmMessage> initialMessages,
    required String systemPrompt,
  }) async {
    final definition = config.definitionFor(
      branch: branch,
      role: role,
      initialMessages: initialMessages,
      systemPrompt: systemPrompt,
    );
    final answer = StringBuffer();
    AgentRunEvent? terminal;
    final timer = Stopwatch()..start();
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
    timer.stop();
    return switch (terminal) {
      AgentRunCompleted() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'completed',
        physical: physical,
        elapsedMs: timer.elapsedMilliseconds,
      ),
      AgentRunFailed(:final error) => Day10CallResult(
        answer: answer.toString(),
        outcome: 'failed',
        physical: physical,
        elapsedMs: timer.elapsedMilliseconds,
        error: error.safeProviderMessage
            ? error.message
            : 'Провайдер не завершил запрос.',
      ),
      AgentRunCancelled() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'cancelled',
        physical: physical,
        elapsedMs: timer.elapsedMilliseconds,
        error: 'Запрос отменён.',
      ),
      AgentRunStopped() => Day10CallResult(
        answer: answer.toString(),
        outcome: 'stopped',
        physical: physical,
        elapsedMs: timer.elapsedMilliseconds,
        error: 'Запрос остановлен.',
      ),
      _ => Day10CallResult(
        answer: answer.toString(),
        outcome: 'failed',
        physical: physical,
        elapsedMs: timer.elapsedMilliseconds,
        error: 'Не получен результат запроса.',
      ),
    };
  }
}
