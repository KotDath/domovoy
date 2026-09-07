import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/reasoning/domain/four_house_puzzle.dart';
import 'package:domovoy/features/reasoning/domain/reasoning_models.dart';
import 'package:domovoy/features/reasoning/presentation/reasoning_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntilIdle(ReasoningController controller) async {
  for (var i = 0; i < 80; i++) {
    if (!controller.isRunning) {
      return;
    }
    await _pump();
  }
}

Future<void> _completeLatest(ControlledAgent agent, String answer) async {
  final lane = agent.latest;
  lane
    ..add(AgentAnswerDelta(answer))
    ..add(const AgentCompleted());
  await lane.close();
  await _pump();
  await _pump();
}

List<AgentEvent> _ok(String answer) => <AgentEvent>[
  AgentAnswerDelta(answer),
  const AgentCompleted(
    finishReason: AgentFinishReason.stop,
    usage: AgentTokenUsage(totalTokens: 3),
  ),
];

void main() {
  const task = fourHousePresetTask;

  group('ReasoningController', () {
    test('rejects empty task without calling the agent', () {
      final agent = ControlledAgent();
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      expect(controller.runComparison('   '), isFalse);
      expect(agent.inputs, isEmpty);
      expect(controller.state.taskError, isNotNull);
    });

    test('runs eight stages in order on one identical snapshot', () async {
      final agent = QueueScriptedAgent([
        _ok('direct'),
        _ok('step'),
        _ok('builder prompt'),
        _ok('solver'),
        _ok('analyst'),
        _ok('engineer'),
        _ok('critic'),
        _ok('synthesis'),
      ]);
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      expect(controller.runComparison('  $task  '), isTrue);
      await _pumpUntilIdle(controller);

      expect(agent.inputs, hasLength(8));
      expect(agent.inputs[0].text, task.trim());
      expect(agent.inputs[1].text, contains(task.trim()));
      expect(agent.inputs[1].text, contains('по шагам'));
      expect(agent.inputs[2].text, contains(task.trim()));
      expect(agent.inputs[2].text, contains('промпт-решатель'));
      expect(agent.inputs[3].text, contains('builder prompt'));
      expect(agent.inputs[3].text, contains(task.trim()));
      expect(agent.inputs[4].text, contains('Аналитик'));
      expect(agent.inputs[5].text, contains('Инженер'));
      expect(agent.inputs[6].text, contains('Критик'));
      for (final expertInput in agent.inputs.sublist(4, 7)) {
        expect(expertInput.text, contains(task.trim()));
        expect(expertInput.text, isNot(contains('analyst')));
        expect(expertInput.text, isNot(contains('engineer')));
        expect(expertInput.text, isNot(contains('critic')));
      }
      expect(agent.inputs[7].text, contains(task.trim()));
      expect(agent.inputs[7].text, contains('analyst'));
      expect(agent.inputs[7].text, contains('engineer'));
      expect(agent.inputs[7].text, contains('critic'));
      for (final input in agent.inputs) {
        expect(input.thinking, ThinkingMode.disabled);
        expect(input.control, isNull);
      }
      expect(controller.completedApiCalls, 8);
      expect(controller.state.direct.answer, 'direct');
      expect(controller.state.stepByStep.answer, 'step');
      expect(controller.state.generatedPrompt, 'builder prompt');
      expect(controller.state.generated.answer, 'solver');
      expect(controller.state.expertAnalyst.answer, 'analyst');
      expect(controller.state.expertEngineer.answer, 'engineer');
      expect(controller.state.expertCritic.answer, 'critic');
      expect(controller.state.expertGroup.answer, 'synthesis');
      expect(controller.state.direct.finishReason, AgentFinishReason.stop);
      expect(controller.state.direct.usage?.totalTokens, 3);
      expect(controller.state.taskSnapshot, task.trim());
      expect(controller.isRunning, isFalse);
    });

    test(
      'skips solver when the generated prompt is empty and continues',
      () async {
        final agent = QueueScriptedAgent([
          _ok('direct'),
          _ok('step'),
          const [AgentCompleted()],
          _ok('analyst'),
          _ok('engineer'),
          _ok('critic'),
          _ok('synthesis'),
        ]);
        final controller = ReasoningController(agent);
        addTearDown(controller.dispose);

        controller.runComparison(task);
        await _pumpUntilIdle(controller);

        expect(agent.inputs, hasLength(7));
        expect(agent.inputs.last.text, contains('analyst'));
        expect(controller.state.generated.status, ReasoningLaneStatus.failed);
        expect(controller.state.generated.failure?.message, contains('пуст'));
        expect(controller.state.expertGroup.answer, 'synthesis');
        expect(controller.completedApiCalls, 7);
      },
    );

    test(
      'keeps builder evidence after failure and still runs experts',
      () async {
        final agent = QueueScriptedAgent([
          _ok('direct'),
          _ok('step'),
          const [
            AgentAnswerDelta('partial builder'),
            AgentFailed(
              AgentFailure(kind: AgentFailureKind.network, message: 'down'),
            ),
          ],
          _ok('analyst'),
          _ok('engineer'),
          _ok('critic'),
          _ok('synthesis'),
        ]);
        final controller = ReasoningController(agent);
        addTearDown(controller.dispose);

        controller.runComparison(task);
        await _pumpUntilIdle(controller);

        expect(agent.inputs, hasLength(7));
        expect(controller.state.promptBuilder.answer, 'partial builder');
        expect(
          controller.state.promptBuilder.status,
          ReasoningLaneStatus.failed,
        );
        expect(controller.state.generated.status, ReasoningLaneStatus.failed);
        expect(controller.state.generated.failure?.message, 'down');
        expect(controller.state.expertGroup.answer, 'synthesis');
        expect(controller.completedApiCalls, 7);
      },
    );

    test('continues after a non-dependent strategy failure', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('partial direct'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        _ok('step'),
        _ok('builder prompt'),
        _ok('solver'),
        _ok('analyst'),
        _ok('engineer'),
        _ok('critic'),
        _ok('synthesis'),
      ]);
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(task);
      await _pumpUntilIdle(controller);

      expect(controller.state.direct.status, ReasoningLaneStatus.failed);
      expect(controller.state.direct.answer, 'partial direct');
      expect(controller.state.stepByStep.answer, 'step');
      expect(controller.state.generated.answer, 'solver');
      expect(controller.state.expertGroup.answer, 'synthesis');
      expect(controller.completedApiCalls, 8);
    });

    test(
      'preserves a failed expert and passes its evidence to synthesis',
      () async {
        final agent = QueueScriptedAgent([
          _ok('direct'),
          _ok('step'),
          _ok('builder prompt'),
          _ok('solver'),
          const [
            AgentAnswerDelta('partial analyst'),
            AgentFailed(
              AgentFailure(kind: AgentFailureKind.network, message: 'offline'),
            ),
          ],
          _ok('engineer'),
          _ok('critic'),
          _ok('synthesis'),
        ]);
        final controller = ReasoningController(agent);
        addTearDown(controller.dispose);

        controller.runComparison(task);
        await _pumpUntilIdle(controller);

        expect(controller.completedApiCalls, 8);
        expect(
          controller.state.expertAnalyst.status,
          ReasoningLaneStatus.failed,
        );
        expect(controller.state.expertAnalyst.answer, 'partial analyst');
        expect(controller.state.expertEngineer.answer, 'engineer');
        expect(controller.state.expertCritic.answer, 'critic');
        expect(controller.state.expertGroup.answer, 'synthesis');
        expect(agent.inputs.last.text, contains('partial analyst'));
        expect(agent.inputs.last.text, contains('offline'));
        expect(agent.inputs.last.text, contains('engineer'));
        expect(agent.inputs.last.text, contains('critic'));
      },
    );

    test(
      'marks an empty expert stream unavailable and still synthesizes',
      () async {
        final agent = QueueScriptedAgent([
          _ok('direct'),
          _ok('step'),
          _ok('builder prompt'),
          _ok('solver'),
          _ok('analyst'),
          const [],
          _ok('critic'),
          _ok('synthesis'),
        ]);
        final controller = ReasoningController(agent);
        addTearDown(controller.dispose);

        controller.runComparison(task);
        await _pumpUntilIdle(controller);

        expect(controller.completedApiCalls, 8);
        expect(
          controller.state.expertEngineer.status,
          ReasoningLaneStatus.failed,
        );
        expect(
          controller.state.expertEngineer.failure?.kind,
          AgentFailureKind.interrupted,
        );
        expect(agent.inputs.last.text, contains('Ответ недоступен'));
        expect(agent.inputs.last.text, contains('завершился неожиданно'));
        expect(controller.state.expertGroup.answer, 'synthesis');
      },
    );

    test('retains expert evidence when synthesis fails', () async {
      final agent = QueueScriptedAgent([
        _ok('direct'),
        _ok('step'),
        _ok('builder prompt'),
        _ok('solver'),
        _ok('analyst'),
        _ok('engineer'),
        _ok('critic'),
        const [
          AgentAnswerDelta('partial synthesis'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.provider, message: 'busy'),
          ),
        ],
      ]);
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(task);
      await _pumpUntilIdle(controller);

      expect(controller.completedApiCalls, 8);
      expect(controller.state.expertAnalyst.answer, 'analyst');
      expect(controller.state.expertEngineer.answer, 'engineer');
      expect(controller.state.expertCritic.answer, 'critic');
      expect(controller.state.expertGroup.answer, 'partial synthesis');
      expect(controller.state.expertGroup.status, ReasoningLaneStatus.failed);
      expect(controller.state.expertGroup.failure?.message, 'busy');
    });

    test('rejects duplicate runs while active', () async {
      final agent = ControlledAgent();
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      expect(controller.runComparison(task), isTrue);
      expect(controller.runComparison(task), isFalse);
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    test('resets verdicts on a new run', () async {
      final agent = QueueScriptedAgent([
        _ok('d1'),
        _ok('s1'),
        _ok('b1'),
        _ok('g1'),
        _ok('a1'),
        _ok('e1'),
        _ok('c1'),
        _ok('x1'),
        _ok('d2'),
        _ok('s2'),
        _ok('b2'),
        _ok('g2'),
        _ok('a2'),
        _ok('e2'),
        _ok('c2'),
        _ok('x2'),
      ]);
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(task);
      await _pumpUntilIdle(controller);
      controller.setVerdict(ReasoningStrategy.direct, ReasoningVerdict.correct);
      controller.setMostAccurate(ReasoningStrategy.direct);
      expect(controller.state.direct.verdict, ReasoningVerdict.correct);
      expect(controller.state.mostAccurate, ReasoningStrategy.direct);

      controller.runComparison(task);
      await _pumpUntilIdle(controller);
      expect(controller.state.direct.answer, 'd2');
      expect(controller.state.direct.verdict, ReasoningVerdict.unrated);
      expect(controller.state.mostAccurate, isNull);
    });

    test('cancels the lane subscription after terminal events', () async {
      final agent = ControlledAgent();
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(task);
      await _pump();
      agent.latest
        ..add(const AgentAnswerDelta('first'))
        ..add(const AgentCompleted());
      await _pump();
      await _pump();

      expect(agent.controllers, hasLength(2));
      expect(agent.controllers[0].hasListener, isFalse);

      agent.controllers[0].add(const AgentAnswerDelta('late'));
      await _pump();
      expect(controller.state.direct.answer, 'first');
    });

    test('dispose during a silent stage cancels the subscription', () async {
      final agent = ControlledAgent();
      final controller = ReasoningController(agent);
      controller.runComparison(task);
      await _pump();

      expect(agent.latest.hasListener, isTrue);
      controller.dispose();
      await _pump();
      expect(agent.controllers.first.hasListener, isFalse);
    });

    test('dispose during an expert stage cancels the ensemble', () async {
      final agent = ControlledAgent();
      final controller = ReasoningController(agent);
      controller.runComparison(task);
      await _pump();

      await _completeLatest(agent, 'direct');
      await _completeLatest(agent, 'step');
      await _completeLatest(agent, 'builder');
      await _completeLatest(agent, 'solver');

      expect(agent.inputs, hasLength(5));
      expect(controller.state.activeStage, ReasoningStage.expertAnalyst);
      expect(agent.latest.hasListener, isTrue);
      controller.dispose();
      await _pump();

      expect(agent.controllers[4].hasListener, isFalse);
      expect(agent.inputs, hasLength(5));
    });

    test(
      'sync prompt throw is sanitized, counted, and later stages continue',
      () async {
        final agent = _ThrowingOnNthAgent(
          QueueScriptedAgent([
            _ok('step'),
            _ok('builder prompt'),
            _ok('solver'),
            _ok('analyst'),
            _ok('engineer'),
            _ok('critic'),
            _ok('synthesis'),
          ]),
          throwOn: 0,
        );
        final controller = ReasoningController(agent);
        addTearDown(controller.dispose);

        controller.runComparison(task);
        await _pumpUntilIdle(controller);

        expect(agent.inputs, hasLength(8));
        expect(controller.isRunning, isFalse);
        expect(controller.completedApiCalls, 8);
        expect(controller.state.direct.status, ReasoningLaneStatus.failed);
        expect(
          controller.state.direct.failure?.kind,
          AgentFailureKind.interrupted,
        );
        expect(
          controller.state.direct.failure?.message,
          'Поток ответа завершился неожиданно.',
        );
        expect(
          controller.state.direct.failure?.message,
          isNot(contains('boom')),
        );
        expect(controller.state.stepByStep.answer, 'step');
        expect(controller.state.generatedPrompt, 'builder prompt');
        expect(controller.state.generated.answer, 'solver');
        expect(controller.state.expertGroup.answer, 'synthesis');
      },
    );

    test('ignores reasoning deltas and keeps independent answers', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentReasoningDelta('hidden'),
          AgentAnswerDelta('visible'),
          AgentCompleted(),
        ],
        _ok('step'),
        _ok('builder prompt'),
        _ok('solver'),
        _ok('analyst'),
        _ok('engineer'),
        _ok('critic'),
        _ok('synthesis'),
      ]);
      final controller = ReasoningController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(task);
      await _pumpUntilIdle(controller);

      expect(controller.state.direct.answer, 'visible');
      expect(controller.state.stepByStep.answer, 'step');
    });
  });
}

final class _ThrowingOnNthAgent implements Agent {
  _ThrowingOnNthAgent(this._inner, {required this.throwOn});

  final Agent _inner;
  final int throwOn;
  final List<AgentInput> inputs = <AgentInput>[];
  int _call = 0;

  @override
  Stream<AgentEvent> prompt(AgentInput input) {
    inputs.add(input);
    if (_call++ == throwOn) {
      throw StateError('boom');
    }
    return _inner.prompt(input);
  }
}
