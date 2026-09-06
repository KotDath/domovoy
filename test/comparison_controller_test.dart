import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/comparison_models.dart';
import 'package:domovoy/features/comparison/domain/comparison_prompts.dart';
import 'package:domovoy/features/comparison/domain/elapsed_timer.dart';
import 'package:domovoy/features/comparison/domain/token_cost.dart';
import 'package:domovoy/features/comparison/presentation/comparison_controller.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntilIdle(ComparisonController controller) async {
  for (var i = 0; i < 80; i++) {
    if (!controller.isRunning) {
      return;
    }
    await _pump();
  }
}

List<AgentEvent> _ok(String answer, {AgentTokenUsage? usage}) => <AgentEvent>[
  AgentAnswerDelta(answer),
  AgentCompleted(
    finishReason: AgentFinishReason.stop,
    usage: usage ?? const AgentTokenUsage(totalTokens: 3),
  ),
];

bool _run(
  ComparisonController controller, {
  String prompt = kComparisonStarterPrompt,
  List<ChatModelProfile>? profiles,
}) {
  return controller.runComparison(
    rawPrompt: prompt,
    profiles: profiles ?? kDay5PresetProfiles,
  );
}

ComparisonController _controller(
  Agent agent, {
  ElapsedClockFactory? clockFactory,
}) {
  return ComparisonController(
    agentFactory: (_) => agent,
    clockFactory: clockFactory ?? StopwatchElapsedClock.new,
  );
}

void main() {
  group('ComparisonController', () {
    test('rejects empty prompt without calling the agent', () {
      final agent = ControlledAgent();
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      expect(_run(controller, prompt: '   '), isFalse);
      expect(agent.inputs, isEmpty);
      expect(controller.state.promptError, isNotNull);
    });

    test('rejects invalid profiles before any request', () {
      final agent = ControlledAgent();
      final controller = _controller(agent);
      addTearDown(controller.dispose);
      final invalid = kOllamaQwen35Profile.copyWith(
        endpoint: Uri.parse('http://example.com/v1/chat/completions'),
      );

      expect(
        _run(
          controller,
          profiles: [invalid, kDeepSeekFlashProfile, kDeepSeekProProfile],
        ),
        isFalse,
      );
      expect(agent.inputs, isEmpty);
      expect(controller.state.profileError, contains('HTTPS'));
    });

    test(
      'snapshots one prompt and three profiles in weak-to-strong order',
      () async {
        final agent = QueueScriptedAgent([
          _ok('weak'),
          _ok('medium'),
          _ok('strong'),
        ]);
        final controller = _controller(agent);
        addTearDown(controller.dispose);

        expect(_run(controller, prompt: '  ecs task  '), isTrue);
        await _pumpUntilIdle(controller);

        expect(agent.inputs, hasLength(3));
        for (final input in agent.inputs) {
          expect(input.text, 'ecs task');
          expect(input.thinking, ThinkingMode.disabled);
          expect(input.control, isNull);
          expect(input.temperature, isNull);
        }
        expect(controller.state.profiles.map((profile) => profile.id), [
          kOllamaQwen35ProfileId,
          kDeepSeekFlashProfileId,
          kDeepSeekProProfileId,
        ]);
        expect(controller.state.lanes[0].answer, 'weak');
        expect(controller.state.lanes[1].answer, 'medium');
        expect(controller.state.lanes[2].answer, 'strong');
        expect(controller.state.promptSnapshot, 'ecs task');
        expect(controller.completedApiCalls, 3);
      },
    );

    test(
      'freezes TTFT on the first non-empty delta and duration on terminal',
      () async {
        final clocks = <_ManualClock>[];
        final agent = ControlledAgent();
        final controller = ComparisonController(
          agentFactory: (_) => agent,
          clockFactory: () {
            final clock = _ManualClock();
            clocks.add(clock);
            return clock;
          },
        );
        addTearDown(controller.dispose);

        _run(controller);
        await _pump();
        clocks.single.elapsedValue = const Duration(milliseconds: 12);
        agent.latest.add(const AgentAnswerDelta('a'));
        await _pump();
        clocks.single.elapsedValue = const Duration(milliseconds: 40);
        agent.latest.add(const AgentAnswerDelta('b'));
        await _pump();
        clocks.single.elapsedValue = const Duration(milliseconds: 90);
        agent.latest.add(const AgentCompleted());
        await _pump();
        await agent.latest.close();
        await _pumpUntilIdle(controller);

        expect(
          controller.state.lanes[0].timeToFirstToken,
          const Duration(milliseconds: 12),
        );
        expect(
          controller.state.lanes[0].totalDuration,
          const Duration(milliseconds: 90),
        );
      },
    );

    test('ignores late and duplicate terminal events', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('one'),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(totalTokens: 1),
          ),
          AgentAnswerDelta('late'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'late-fail'),
          ),
          AgentCompleted(
            finishReason: AgentFinishReason.length,
            usage: AgentTokenUsage(totalTokens: 99),
          ),
        ],
        _ok('medium'),
        _ok('strong'),
      ]);
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].answer, 'one');
      expect(controller.state.lanes[0].status, ComparisonLaneStatus.completed);
      expect(controller.state.lanes[0].finishReason, AgentFinishReason.stop);
      expect(controller.state.lanes[0].usage?.totalTokens, 1);
      expect(controller.state.lanes[0].failure, isNull);
      expect(controller.state.lanes[1].answer, 'medium');
      expect(controller.state.lanes[2].answer, 'strong');
      expect(controller.completedApiCalls, 3);
      expect(controller.isRunning, isFalse);
    });

    test('continues after failure and keeps partial output', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('partial-weak'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        _ok('medium'),
        _ok('strong'),
      ]);
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].status, ComparisonLaneStatus.failed);
      expect(controller.state.lanes[0].answer, 'partial-weak');
      expect(controller.state.lanes[1].answer, 'medium');
      expect(controller.state.lanes[2].answer, 'strong');
      expect(controller.completedApiCalls, 3);
    });

    test('synchronous throw is sanitized and later lanes continue', () async {
      final agent = _ThrowingOnNthAgent(
        QueueScriptedAgent([_ok('medium'), _ok('strong')]),
        throwOn: 0,
      );
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].status, ComparisonLaneStatus.failed);
      expect(
        controller.state.lanes[0].failure?.message,
        isNot(contains('boom')),
      );
      expect(controller.state.lanes[1].answer, 'medium');
      expect(controller.completedApiCalls, 3);
    });

    test('silent stream ending becomes an interrupted failure', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('cut')],
        _ok('medium'),
        _ok('strong'),
      ]);
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      _run(controller);
      await _pumpUntilIdle(controller);

      expect(controller.state.lanes[0].status, ComparisonLaneStatus.failed);
      expect(
        controller.state.lanes[0].failure?.kind,
        AgentFailureKind.interrupted,
      );
      expect(controller.completedApiCalls, 3);
    });

    test('duplicate runs are locked while active', () async {
      final agent = ControlledAgent();
      final controller = _controller(agent);
      addTearDown(controller.dispose);

      expect(_run(controller), isTrue);
      expect(_run(controller), isFalse);
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    test(
      'computes zero local cost and unavailable cloud cost without usage',
      () async {
        final agent = QueueScriptedAgent([
          _ok('local', usage: null),
          _ok('flash', usage: null),
          _ok('pro', usage: null),
        ]);
        final controller = _controller(agent);
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);

        expect(controller.state.lanes[0].cost, isA<ZeroProviderFeeCost>());
        expect(controller.state.lanes[1].cost, isA<UnavailableEstimatedCost>());
        expect(controller.state.lanes[2].cost, isA<UnavailableEstimatedCost>());
      },
    );

    test(
      'records ratings, notes, conclusion and resets them on the next run',
      () async {
        final agent = QueueScriptedAgent([
          _ok('first-a'),
          _ok('first-b'),
          _ok('first-c'),
          _ok('second-a'),
          _ok('second-b'),
          _ok('second-c'),
        ]);
        final controller = _controller(agent);
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);
        controller.setRating(
          laneIndex: 0,
          kind: ComparisonRatingKind.correctness,
          value: 5,
        );
        controller.setNote(laneIndex: 0, note: 'solid');
        controller.setConclusion('flash is enough');
        expect(controller.state.lanes[0].evaluation.correctness, 5);
        expect(controller.state.conclusion, 'flash is enough');

        _run(controller, prompt: 'next');
        await _pumpUntilIdle(controller);
        expect(controller.state.lanes[0].answer, 'second-a');
        expect(controller.state.lanes[0].evaluation.correctness, isNull);
        expect(controller.state.lanes[0].evaluation.note, isEmpty);
        expect(controller.state.conclusion, isEmpty);
      },
    );

    test(
      'missing credentials fail one lane and later lanes still run',
      () async {
        final controller = ComparisonController(
          agentFactory: (profile) {
            if (profile.id == kDeepSeekFlashProfileId) {
              return ScriptedAgent(const [
                AgentFailed(
                  AgentFailure(
                    kind: AgentFailureKind.configuration,
                    message: 'Добавьте API-ключ в настройках.',
                  ),
                ),
              ]);
            }
            return ScriptedAgent(_ok(profile.modelId));
          },
        );
        addTearDown(controller.dispose);

        _run(controller);
        await _pumpUntilIdle(controller);

        expect(controller.state.lanes[0].answer, kOllamaQwen35ModelId);
        expect(controller.state.lanes[1].status, ComparisonLaneStatus.failed);
        expect(
          controller.state.lanes[1].failure?.kind,
          AgentFailureKind.configuration,
        );
        expect(controller.state.lanes[2].answer, kDeepSeekProModelId);
        expect(controller.completedApiCalls, 3);
      },
    );

    test('dispose cancels the active subscription', () async {
      final agent = ControlledAgent();
      final controller = _controller(agent);
      _run(controller);
      await _pump();
      controller.dispose();
      agent.latest.add(const AgentAnswerDelta('stale'));
      await _pump();
      expect(controller.isControllerDisposed, isTrue);
    });
  });
}

final class _ManualClock implements ElapsedClock {
  Duration elapsedValue = Duration.zero;

  @override
  Duration elapsed() => elapsedValue;
}

final class _ThrowingOnNthAgent implements Agent {
  _ThrowingOnNthAgent(this._inner, {required this.throwOn});

  final Agent _inner;
  final int throwOn;
  int _index = 0;
  final List<AgentInput> inputs = <AgentInput>[];

  @override
  Stream<AgentEvent> prompt(AgentInput input) {
    inputs.add(input);
    if (_index++ == throwOn) {
      throw StateError('boom');
    }
    return _inner.prompt(input);
  }
}
