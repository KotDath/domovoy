import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/prompt/presentation/prompt_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('validates blank input without calling agent', () {
    final agent = ControlledAgent();
    final controller = PromptController(agent);
    addTearDown(controller.dispose);

    expect(controller.submit('   '), isFalse);
    expect(agent.inputs, isEmpty);
    expect(controller.state.inputError, isNotNull);
  });

  test('accumulates deltas, toggles reasoning, and completes', () async {
    final agent = ControlledAgent();
    final controller = PromptController(agent);
    addTearDown(controller.dispose);

    expect(controller.submit('question'), isTrue);
    expect(controller.submit('concurrent'), isFalse);
    agent.latest.add(const AgentReasoningDelta('one '));
    agent.latest.add(const AgentReasoningDelta('two'));
    agent.latest.add(const AgentAnswerDelta('answer'));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.reasoning, 'one two');
    expect(controller.state.answer, 'answer');
    expect(controller.state.reasoningExpanded, isTrue);
    controller.toggleReasoning();
    expect(controller.state.reasoningExpanded, isFalse);

    agent.latest.add(const AgentReasoningDelta(' hidden'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.reasoning, 'one two hidden');
    expect(controller.state.reasoningExpanded, isFalse);

    agent.latest.add(const AgentCompleted());
    await agent.latest.close();
    expect(controller.state.status, PromptRunStatus.completed);
  });

  test('new submission clears prior result and ignores old stream', () async {
    final agent = ControlledAgent();
    final controller = PromptController(agent);
    addTearDown(controller.dispose);

    controller.submit('first');
    final first = agent.latest;
    first.add(const AgentAnswerDelta('old'));
    first.add(const AgentCompleted());
    await Future<void>.delayed(Duration.zero);

    controller.submit('second');
    expect(controller.state.answer, isEmpty);
    first.add(const AgentAnswerDelta('late'));
    agent.latest.add(const AgentAnswerDelta('new'));
    agent.latest.add(const AgentCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'new');
    expect(agent.inputs.map((input) => input.text), <String>[
      'first',
      'second',
    ]);
    await first.close();
    await agent.latest.close();
  });

  test('retains partial output on typed failure', () async {
    final agent = ControlledAgent();
    final controller = PromptController(agent);
    addTearDown(controller.dispose);

    controller.submit('question');
    agent.latest.add(const AgentAnswerDelta('partial'));
    agent.latest.add(
      const AgentFailed(
        AgentFailure(kind: AgentFailureKind.network, message: 'network failed'),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'partial');
    expect(controller.state.status, PromptRunStatus.failed);
    expect(controller.state.failure?.message, 'network failed');
    await agent.latest.close();
  });

  test('new submission after failure clears prior output and error', () async {
    final agent = ControlledAgent();
    final controller = PromptController(agent);
    addTearDown(controller.dispose);

    controller.submit('first');
    final first = agent.latest;
    first.add(const AgentAnswerDelta('partial'));
    first.add(
      const AgentFailed(
        AgentFailure(kind: AgentFailureKind.network, message: 'network failed'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.status, PromptRunStatus.failed);

    expect(controller.submit('second'), isTrue);
    expect(controller.state.answer, isEmpty);
    expect(controller.state.failure, isNull);
    expect(controller.state.status, PromptRunStatus.streaming);

    agent.latest.add(const AgentAnswerDelta('recovered'));
    agent.latest.add(const AgentCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.answer, 'recovered');
    expect(controller.state.failure, isNull);
    expect(controller.state.status, PromptRunStatus.completed);
    expect(agent.inputs.map((input) => input.text), <String>[
      'first',
      'second',
    ]);
    await first.close();
    await agent.latest.close();
  });
}
