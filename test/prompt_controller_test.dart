import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/generation.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/features/prompt/presentation/prompt_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('validates blank input without calling agent', () {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    expect(controller.submit('   '), isFalse);
    expect(runtime.inputs, isEmpty);
    expect(controller.state.inputError, isNotNull);
  });

  test('accumulates deltas, toggles reasoning, and completes', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    expect(controller.submit('question'), isTrue);
    expect(controller.submit('concurrent'), isFalse);
    runtime.latest.add(const AgentReasoningDelta('one '));
    runtime.latest.add(const AgentReasoningDelta('two'));
    runtime.latest.add(const AgentAnswerDelta('answer'));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.reasoning, 'one two');
    expect(controller.state.answer, 'answer');
    expect(controller.state.reasoningExpanded, isTrue);
    controller.toggleReasoning();
    expect(controller.state.reasoningExpanded, isFalse);

    runtime.latest.add(const AgentReasoningDelta(' hidden'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.reasoning, 'one two hidden');
    expect(controller.state.reasoningExpanded, isFalse);

    runtime.latest.add(const AgentRunCompleted());
    await runtime.latest.close();
    expect(controller.state.status, PromptRunStatus.completed);
  });

  test('new submission clears prior result and ignores old stream', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    controller.submit('first');
    final first = runtime.latest;
    first.add(const AgentAnswerDelta('old'));
    first.add(const AgentRunCompleted());
    await Future<void>.delayed(Duration.zero);

    controller.submit('second');
    expect(controller.state.answer, isEmpty);
    first.add(const AgentAnswerDelta('late'));
    runtime.latest.add(const AgentAnswerDelta('new'));
    runtime.latest.add(const AgentRunCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'new');
    expect(runtime.inputs, <String>['first', 'second']);
    await first.close();
    await runtime.latest.close();
  });

  test('retains partial output on typed failure', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    controller.submit('question');
    runtime.latest.add(const AgentAnswerDelta('partial'));
    runtime.latest.add(
      AgentRunFailed(
        AgentError(kind: AgentErrorKind.provider, message: 'network failed'),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'partial');
    expect(controller.state.status, PromptRunStatus.failed);
    expect(controller.state.failure?.message, 'network failed');
    await runtime.latest.close();
  });

  test('new submission after failure clears prior output and error', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    controller.submit('first');
    final first = runtime.latest;
    first.add(const AgentAnswerDelta('partial'));
    first.add(
      AgentRunFailed(
        AgentError(kind: AgentErrorKind.provider, message: 'network failed'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.status, PromptRunStatus.failed);

    expect(controller.submit('second'), isTrue);
    expect(controller.state.answer, isEmpty);
    expect(controller.state.failure, isNull);
    expect(controller.state.status, PromptRunStatus.streaming);

    runtime.latest.add(const AgentAnswerDelta('recovered'));
    runtime.latest.add(const AgentRunCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'recovered');
    expect(controller.state.failure, isNull);
    expect(controller.state.status, PromptRunStatus.completed);
    expect(runtime.inputs, <String>['first', 'second']);
    await first.close();
    await runtime.latest.close();
  });

  test('maps stop and cancellation terminals into existing state', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    controller.submit('tools');
    runtime.latest.add(const AgentAnswerDelta('partial'));
    runtime.latest.add(const AgentRunStopped(AgentStopReason.toolCallLimit));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.answer, 'partial');
    expect(controller.state.status, PromptRunStatus.completed);

    expect(controller.submit('cancel-me'), isTrue);
    runtime.latest.add(const AgentRunCancelled());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.status, PromptRunStatus.failed);
    expect(controller.state.failure?.message, contains('неожиданно'));
  });

  test('dispose cancels the active run and ignores late events', () async {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);

    expect(controller.submit('question'), isTrue);
    runtime.latest.add(const AgentAnswerDelta('partial'));
    await Future<void>.delayed(Duration.zero);
    controller.dispose();

    expect(runtime.latest.cancelled, isTrue);
    runtime.latest.add(const AgentAnswerDelta('late'));
    runtime.latest.add(const AgentRunCompleted());
    await Future<void>.delayed(Duration.zero);
    await runtime.latest.close();
  });

  test('snapshots reasoning into the copied definition', () {
    final runtime = ControlledAgentRuntime();
    final controller = _controller(runtime);
    addTearDown(controller.dispose);

    controller.setThinkingMode(ReasoningMode.disabled);
    expect(controller.submit('hello'), isTrue);
    expect(runtime.definitions, hasLength(1));
    expect(
      runtime.definitions.single.generation.reasoningMode,
      ReasoningMode.disabled,
    );
    expect(runtime.definitions.single.limits?.maxModelTurns, 1);
    expect(runtime.definitions.single.limits?.maxToolCalls, 0);
  });
}

PromptController _controller(AgentRuntime runtime) {
  return PromptController(runtime, definition: PromptWorkspace.definition());
}
