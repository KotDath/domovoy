import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/tasks/tasks.dart';
import 'package:domovoy/infrastructure/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/fakes.dart';

void main() {
  test(
    'uses fresh tool-free invocations and parses structured roles',
    () async {
      final runtime = QueueScriptedAgentRuntime(<List<AgentRunEvent>>[
        <AgentRunEvent>[
          const AgentAnswerDelta(
            '{"nodes":[{"id":"work","title":"Work",'
            '"instructions":"Do work","acceptanceCriteria":"Done",'
            '"dependencies":[]}]}',
          ),
          const AgentRunCompleted(),
        ],
        const <AgentRunEvent>[
          AgentAnswerDelta('node markdown'),
          AgentRunCompleted(),
        ],
        const <AgentRunEvent>[
          AgentAnswerDelta('{"accepted":true,"evidence":"checked"}'),
          AgentRunCompleted(),
        ],
      ]);
      final gateway = AgentRuntimeTaskGateway(
        runtime: runtime,
        baseDefinition: testDefinition(tools: <ToolId>[ToolId('dangerous')]),
        ids: AgentIdFactory(prefix: 'gateway-test'),
      );

      final plan = await gateway.preparePlan(
        goal: 'Bounded goal',
        rules: const <TaskInvariantRule>[],
      );
      final output = await gateway.executeNode(
        goal: 'Bounded goal',
        plan: plan,
        node: plan.nodes.single,
        dependencyOutputs: const <TaskNodeId, String>{},
        rules: const <TaskInvariantRule>[],
      );
      final verification = await gateway.verifyNode(
        goal: 'Bounded goal',
        plan: plan,
        node: plan.nodes.single,
        output: output,
        rules: const <TaskInvariantRule>[],
      );

      expect(output, 'node markdown');
      expect(verification.accepted, isTrue);
      expect(verification.evidence, 'checked');
      expect(runtime.definitions, hasLength(3));
      expect(
        runtime.definitions.map((definition) => definition.id.value).toSet(),
        hasLength(3),
      );
      for (final definition in runtime.definitions) {
        expect(definition.enabledTools, isEmpty);
        expect(definition.policy, PolicyId('deny'));
        expect(definition.initialMessages, isEmpty);
      }
      expect(runtime.inputs, hasLength(3));
      expect(
        runtime.inputs.every((input) => input.contains('Bounded goal')),
        isTrue,
      );
    },
  );

  test('disables runtime dynamic context for every task invocation', () async {
    final runtime = ControlledAgentRuntime();
    final gateway = AgentRuntimeTaskGateway(
      runtime: runtime,
      baseDefinition: testDefinition(),
    );

    final pending = gateway.preparePlan(
      goal: 'Isolated goal',
      rules: const <TaskInvariantRule>[],
    );
    runtime.latest.add(
      const AgentAnswerDelta(
        '{"nodes":[{"id":"work","title":"Work",'
        '"instructions":"Do work","acceptanceCriteria":"Done",'
        '"dependencies":[]}]}',
      ),
    );
    runtime.latest.add(const AgentRunCompleted());
    await runtime.latest.close();

    await pending;

    expect(runtime.options, hasLength(1));
    expect(runtime.options.single?.includeDynamicContext, isFalse);
  });
}
