import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/temperature/domain/temperature_models.dart';
import 'package:domovoy/features/temperature/domain/temperature_prompts.dart';
import 'package:domovoy/features/temperature/presentation/temperature_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntilIdle(TemperatureController controller) async {
  for (var i = 0; i < 80; i++) {
    if (!controller.isRunning) {
      return;
    }
    await _pump();
  }
}

List<AgentEvent> _ok(String answer) => <AgentEvent>[
  AgentAnswerDelta(answer),
  const AgentCompleted(
    finishReason: AgentFinishReason.stop,
    usage: AgentTokenUsage(totalTokens: 3),
  ),
];

bool _run(
  TemperatureController controller, {
  String prompt = kTemperatureStarterPrompt,
  List<double> temperatures = kTemperaturePresetValues,
}) {
  return controller.runComparison(
    rawPrompt: prompt,
    temperatures: temperatures,
  );
}

void main() {
  group('TemperatureController', () {
    test('rejects empty prompt without calling the agent', () {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      expect(_run(controller, prompt: '   '), isFalse);
      expect(agent.inputs, isEmpty);
      expect(controller.state.promptError, isNotNull);
    });

    test('rejects equal temperatures without calling the agent', () {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      expect(_run(controller, temperatures: const [0.0, 0.0, 1.2]), isFalse);
      expect(agent.inputs, isEmpty);
      expect(controller.state.temperatureError, contains('различаться'));
    });

    test('runs three lanes in order on one identical snapshot', () async {
      final agent = QueueScriptedAgent([_ok('low'), _ok('mid'), _ok('high')]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      expect(_run(controller, prompt: '  sky task  '), isTrue);
      await _pumpUntilIdle(controller);

      expect(agent.inputs, hasLength(3));
      for (final input in agent.inputs) {
        expect(input.text, 'sky task');
        expect(input.thinking, ThinkingMode.disabled);
        expect(input.control, isNull);
      }
      expect(agent.inputs[0].temperature, 0.0);
      expect(agent.inputs[1].temperature, 0.7);
      expect(agent.inputs[2].temperature, 1.2);
      expect(controller.completedApiCalls, 3);
      expect(controller.state.lanes[0].answer, 'low');
      expect(controller.state.lanes[1].answer, 'mid');
      expect(controller.state.lanes[2].answer, 'high');
      expect(controller.state.lanes[0].appliedTemperature, 0.0);
      expect(controller.state.lanes[1].appliedTemperature, 0.7);
      expect(controller.state.lanes[2].appliedTemperature, 1.2);
      expect(controller.state.lanes[0].finishReason, AgentFinishReason.stop);
      expect(controller.state.lanes[0].usage?.totalTokens, 3);
      expect(controller.state.promptSnapshot, 'sky task');
      expect(controller.isRunning, isFalse);
    });

    test('keeps custom lane order for distinct values', () async {
      final agent = QueueScriptedAgent([_ok('a'), _ok('b'), _ok('c')]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller, temperatures: const [1.2, 0.0, 0.7]);
      await _pumpUntilIdle(controller);

      expect(agent.inputs.map((input) => input.temperature), [1.2, 0.0, 0.7]);
    });

    test('appends progressive deltas to one lane only', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pump();
      agent.latest.add(const AgentAnswerDelta('one'));
      await _pump();
      agent.latest.add(const AgentAnswerDelta(' two'));
      await _pump();

      expect(controller.state.lanes[0].answer, 'one two');
      expect(controller.state.lanes[1].answer, isEmpty);
      expect(controller.state.lanes[2].answer, isEmpty);
      await agent.latest.close();
    });

    test('continues after a stream failure and keeps partial output', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('partial-low'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        _ok('mid'),
        _ok('high'),
      ]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].status, TemperatureLaneStatus.failed);
      expect(controller.state.lanes[0].answer, 'partial-low');
      expect(controller.state.lanes[0].failure?.message, 'down');
      expect(controller.state.lanes[1].answer, 'mid');
      expect(controller.state.lanes[2].answer, 'high');
      expect(controller.completedApiCalls, 3);
    });

    test(
      'sync prompt throw is sanitized, counted, and later lanes continue',
      () async {
        final agent = _ThrowingOnNthAgent(
          QueueScriptedAgent([_ok('mid'), _ok('high')]),
          throwOn: 0,
        );
        final controller = TemperatureController(agent);
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);

        expect(agent.inputs, hasLength(3));
        expect(controller.isRunning, isFalse);
        expect(controller.completedApiCalls, 3);
        expect(controller.state.lanes[0].status, TemperatureLaneStatus.failed);
        expect(
          controller.state.lanes[0].failure?.kind,
          AgentFailureKind.interrupted,
        );
        expect(
          controller.state.lanes[0].failure?.message,
          'Поток ответа завершился неожиданно.',
        );
        expect(
          controller.state.lanes[0].failure?.message,
          isNot(contains('boom')),
        );
        expect(controller.state.lanes[1].answer, 'mid');
        expect(controller.state.lanes[2].answer, 'high');
      },
    );

    test('silent stream ending becomes an interrupted lane failure', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('cut')],
        _ok('mid'),
        _ok('high'),
      ]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].status, TemperatureLaneStatus.failed);
      expect(controller.state.lanes[0].answer, 'cut');
      expect(
        controller.state.lanes[0].failure?.kind,
        AgentFailureKind.interrupted,
      );
      expect(controller.state.lanes[1].answer, 'mid');
      expect(controller.completedApiCalls, 3);
    });

    test('rejects duplicate runs while active', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      expect(_run(controller), isTrue);
      expect(_run(controller), isFalse);
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    test('resets results and evaluations on a new valid run', () async {
      final agent = QueueScriptedAgent([
        _ok('a1'),
        _ok('b1'),
        _ok('c1'),
        _ok('a2'),
        _ok('b2'),
        _ok('c2'),
      ]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);
      controller.setRating(
        laneIndex: 0,
        kind: TemperatureRatingKind.accuracy,
        value: 5,
      );
      controller.setNote(laneIndex: 0, note: 'coding');
      expect(controller.state.lanes[0].evaluation.accuracy, 5);
      expect(controller.state.lanes[0].evaluation.note, 'coding');

      _run(controller, prompt: 'second');
      await _pumpUntilIdle(controller);
      expect(controller.state.lanes[0].answer, 'a2');
      expect(controller.state.lanes[0].evaluation.accuracy, isNull);
      expect(controller.state.lanes[0].evaluation.note, isEmpty);
      expect(controller.state.promptSnapshot, 'second');
    });

    test('ignores ratings until a lane is terminal', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pump();
      controller.setRating(
        laneIndex: 0,
        kind: TemperatureRatingKind.accuracy,
        value: 4,
      );
      controller.setNote(laneIndex: 0, note: 'too soon');
      expect(controller.state.lanes[0].evaluation.accuracy, isNull);
      expect(controller.state.lanes[0].evaluation.note, isEmpty);
      await agent.latest.close();
    });

    test('cancels the lane subscription after terminal events', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
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
      expect(controller.state.lanes[0].answer, 'first');
    });

    test('dispose during a silent stage cancels the subscription', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      _run(controller);
      await _pump();

      expect(agent.latest.hasListener, isTrue);
      controller.dispose();
      await _pump();
      expect(agent.controllers.first.hasListener, isFalse);
    });

    test(
      'sync events after completion cannot mutate output or double-count',
      () async {
        final agent = QueueScriptedAgent([
          const [
            AgentAnswerDelta('keep'),
            AgentCompleted(
              finishReason: AgentFinishReason.stop,
              usage: AgentTokenUsage(totalTokens: 1),
            ),
            AgentAnswerDelta('late'),
            AgentFailed(
              AgentFailure(kind: AgentFailureKind.network, message: 'after'),
            ),
            AgentCompleted(
              finishReason: AgentFinishReason.length,
              usage: AgentTokenUsage(totalTokens: 99),
            ),
          ],
          _ok('mid'),
          _ok('high'),
        ]);
        final controller = TemperatureController(agent);
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);

        expect(controller.state.lanes[0].answer, 'keep');
        expect(
          controller.state.lanes[0].status,
          TemperatureLaneStatus.completed,
        );
        expect(controller.state.lanes[0].finishReason, AgentFinishReason.stop);
        expect(controller.state.lanes[0].usage?.totalTokens, 1);
        expect(controller.state.lanes[0].failure, isNull);
        expect(controller.state.lanes[1].answer, 'mid');
        expect(controller.state.lanes[2].answer, 'high');
        expect(controller.completedApiCalls, 3);
      },
    );

    test(
      'sync events after failure cannot mutate output or double-count',
      () async {
        final agent = QueueScriptedAgent([
          const [
            AgentAnswerDelta('partial'),
            AgentFailed(
              AgentFailure(kind: AgentFailureKind.network, message: 'down'),
            ),
            AgentAnswerDelta('late'),
            AgentCompleted(
              finishReason: AgentFinishReason.stop,
              usage: AgentTokenUsage(totalTokens: 99),
            ),
          ],
          _ok('mid'),
          _ok('high'),
        ]);
        final controller = TemperatureController(agent);
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);

        expect(controller.state.lanes[0].answer, 'partial');
        expect(controller.state.lanes[0].status, TemperatureLaneStatus.failed);
        expect(controller.state.lanes[0].failure?.message, 'down');
        expect(controller.state.lanes[0].finishReason, isNull);
        expect(controller.completedApiCalls, 3);
      },
    );

    test('queued extra events after complete do not double-count', () async {
      final agent = ControlledAgent();
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pump();
      agent.latest
        ..add(const AgentAnswerDelta('keep'))
        ..add(
          const AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(totalTokens: 1),
          ),
        )
        ..add(const AgentAnswerDelta('late'))
        ..add(
          const AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'after'),
          ),
        );
      await _pump();
      await _pump();

      expect(controller.state.lanes[0].answer, 'keep');
      expect(controller.state.lanes[0].status, TemperatureLaneStatus.completed);
      expect(controller.state.lanes[0].failure, isNull);
      expect(controller.completedApiCalls, 1);

      await _pump();
      expect(agent.controllers, hasLength(2));
      agent.latest
        ..add(const AgentAnswerDelta('mid'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await _pump();
      await _pump();

      agent.latest
        ..add(const AgentAnswerDelta('high'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await _pumpUntilIdle(controller);

      expect(controller.completedApiCalls, 3);
      expect(controller.isRunning, isFalse);
    });

    test('ignores reasoning deltas and keeps independent answers', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentReasoningDelta('hidden'),
          AgentAnswerDelta('visible'),
          AgentCompleted(),
        ],
        _ok('mid'),
        _ok('high'),
      ]);
      final controller = TemperatureController(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].answer, 'visible');
      expect(controller.state.lanes[1].answer, 'mid');
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
