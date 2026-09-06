import 'package:domovoy/features/lab/domain/format_contracts.dart';
import 'package:domovoy/features/lab/presentation/comparison_controller.dart';
import 'package:domovoy/features/lab/presentation/format_experiment_controller.dart';
import 'package:domovoy/features/lab/presentation/length_experiment_controller.dart';
import 'package:domovoy/features/lab/presentation/stop_experiment_controller.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('FormatExperimentController', () {
    test('rejects invalid inputs without calling the agent', () {
      final agent = ControlledAgent();
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);

      expect(
        controller.runComparison(
          rawPrompt: '   ',
          thinking: ThinkingMode.enabled,
        ),
        isFalse,
      );
      expect(agent.inputs, isEmpty);
      expect(controller.promptError, isNotNull);
    });

    test('runs baseline then controlled with the same base prompt', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('base'), AgentCompleted()],
        const [AgentAnswerDelta('{"title": "t"}'), AgentCompleted()],
      ]);
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);
      controller.jsonContract = const JsonFormatContract(
        fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
      );

      expect(
        controller.runComparison(
          rawPrompt: 'same prompt',
          thinking: ThinkingMode.enabled,
        ),
        isTrue,
      );
      await _pump();
      await _pump();

      expect(agent.inputs, hasLength(2));
      expect(agent.inputs[0].text, contains('same prompt'));
      expect(agent.inputs[0].control, isNull);
      expect(agent.inputs[1].control, isA<FormatControl>());
      expect(agent.inputs[1].text, contains('same prompt'));
      expect(controller.baseline.answer, 'base');
      expect(controller.controlled.answer, '{"title": "t"}');
      expect(controller.completedApiCalls, 2);
    });

    test('continues controlled lane after baseline failure', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('partial'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        const [AgentAnswerDelta('ok'), AgentCompleted()],
      ]);
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);
      controller.jsonContract = const JsonFormatContract(
        fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
      );

      controller.runComparison(
        rawPrompt: 'task',
        thinking: ThinkingMode.enabled,
      );
      await _pump();
      await _pump();

      expect(controller.baseline.status, ExperimentLaneStatus.failed);
      expect(controller.baseline.answer, 'partial');
      expect(controller.controlled.answer, 'ok');
    });

    test('resubmission clears prior results', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('one'), AgentCompleted()],
        const [AgentAnswerDelta('two'), AgentCompleted()],
        const [AgentAnswerDelta('three'), AgentCompleted()],
        const [AgentAnswerDelta('four'), AgentCompleted()],
      ]);
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);
      controller.jsonContract = const JsonFormatContract(
        fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
      );

      controller.runComparison(rawPrompt: 'a', thinking: ThinkingMode.enabled);
      await _pump();
      await _pump();
      expect(controller.baseline.answer, 'one');

      controller.runComparison(rawPrompt: 'b', thinking: ThinkingMode.enabled);
      await _pump();
      await _pump();
      expect(controller.baseline.answer, 'three');
      expect(controller.controlled.answer, 'four');
    });

    test('repair is bounded to one attempt', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('base {}'), AgentCompleted()],
        const [AgentAnswerDelta('not json'), AgentCompleted()],
        const [
          AgentAnswerDelta('still bad'),
          AgentCompleted(finishReason: AgentFinishReason.stop),
        ],
      ]);
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);
      controller.jsonContract = const JsonFormatContract(
        fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
      );

      controller.runComparison(
        rawPrompt: 'task',
        thinking: ThinkingMode.enabled,
      );
      await _pump();
      await _pump();
      expect(controller.repairAvailable, isTrue);

      expect(await controller.repair(), isTrue);
      await _pump();
      expect(controller.repairAttempted, isTrue);
      expect(controller.repairAvailable, isFalse);
      // Second repair is refused permanently.
      expect(await controller.repair(), isFalse);
      expect(agent.inputs, hasLength(3));
    });

    test(
      'dispose during repair cancels the stream without notifying',
      () async {
        final agent = ControlledAgent();
        final controller = FormatExperimentController(agent);
        controller.jsonContract = const JsonFormatContract(
          fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
        );

        controller.runComparison(
          rawPrompt: 'task',
          thinking: ThinkingMode.enabled,
        );
        await _pump();
        agent.controllers[0]
          ..add(const AgentAnswerDelta('base'))
          ..add(const AgentCompleted());
        await _pump();
        await _pump();
        agent.controllers[1]
          ..add(const AgentAnswerDelta('not json'))
          ..add(const AgentCompleted());
        await _pump();
        await _pump();
        expect(controller.repairAvailable, isTrue);

        final repairing = controller.repair();
        await _pump();
        expect(agent.controllers, hasLength(3));
        expect(agent.controllers[2].hasListener, isTrue);

        // The repair stream stays silent; disposing must cancel it and the
        // pending repair future must resolve without throwing.
        controller.dispose();
        await _pump();
        expect(agent.controllers[2].hasListener, isFalse);
        expect(await repairing, isTrue);
      },
    );

    test('rejects duplicate runs while active', () async {
      final agent = ControlledAgent();
      final controller = FormatExperimentController(agent);
      addTearDown(controller.dispose);
      controller.jsonContract = const JsonFormatContract(
        fields: [JsonFieldSpec(name: 'title', type: JsonFieldType.string)],
      );

      expect(
        controller.runComparison(
          rawPrompt: 'first',
          thinking: ThinkingMode.enabled,
        ),
        isTrue,
      );
      expect(
        controller.runComparison(
          rawPrompt: 'second',
          thinking: ThinkingMode.enabled,
        ),
        isFalse,
      );
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });
  });

  group('LengthExperimentController', () {
    test('validates numeric limits', () {
      final controller = LengthExperimentController(ControlledAgent());
      addTearDown(controller.dispose);

      expect(
        controller.runComparison(
          rawPrompt: 'task',
          rawMaxChars: 'oops',
          rawMaxTokens: '0',
          thinking: ThinkingMode.enabled,
        ),
        isFalse,
      );
      expect(controller.maxCharsError, isNotNull);
      expect(controller.maxTokensError, isNotNull);
    });

    test('measures Unicode characters and truncation', () async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('привет'), AgentCompleted()],
        const [
          AgentAnswerDelta('ok'),
          AgentCompleted(finishReason: AgentFinishReason.length),
        ],
      ]);
      final controller = LengthExperimentController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(
        rawPrompt: 'task',
        rawMaxChars: '300',
        rawMaxTokens: '50',
        thinking: ThinkingMode.enabled,
      );
      await _pump();
      await _pump();

      expect(controller.baseline.charCount, 6);
      expect(controller.controlledTruncated, isTrue);
      expect(controller.activeMaxChars, 300);
      expect(controller.activeMaxTokens, 50);
    });

    test('counts grapheme clusters, not code units', () {
      const lane = ExperimentLaneState(
        status: ExperimentLaneStatus.completed,
        answer: '👨‍👩‍👧!',
      );
      // Family emoji (ZWJ sequence) plus exclamation mark: 2 graphemes,
      // but many more UTF-16 code units and code points.
      expect(lane.charCount, 2);
      expect(lane.answer.length, greaterThan(2));
      expect(lane.answer.runes.length, greaterThan(2));
    });
  });

  group('StopExperimentController', () {
    test('rejects blank markers', () {
      final controller = StopExperimentController(ControlledAgent());
      addTearDown(controller.dispose);

      expect(
        controller.runComparison(
          rawPrompt: 'task',
          rawMarker: '   ',
          thinking: ThinkingMode.enabled,
        ),
        isFalse,
      );
      expect(controller.markerError, isNotNull);
    });

    test('detects marker and post-marker presence', () async {
      final agent = QueueScriptedAgent([
        const [
          AgentAnswerDelta('answer <M> after'),
          AgentCompleted(finishReason: AgentFinishReason.stop),
        ],
        const [
          AgentAnswerDelta('answer without'),
          AgentCompleted(finishReason: AgentFinishReason.stop),
        ],
      ]);
      final controller = StopExperimentController(agent);
      addTearDown(controller.dispose);

      controller.runComparison(
        rawPrompt: 'emit <M> then after',
        rawMarker: '<M>',
        thinking: ThinkingMode.disabled,
      );
      await _pump();
      await _pump();

      expect(agent.inputs[0].text, agent.inputs[1].text);
      expect(agent.inputs[1].control, isA<StopControl>());
      expect(controller.baselineEvidence.containsMarker, isTrue);
      expect(controller.baselineEvidence.containsPostMarkerText, isTrue);
      expect(controller.controlledEvidence.containsMarker, isFalse);
    });

    test('detects the post-marker sentence without the marker', () {
      final withBoth = stopEvidenceFor(
        'совет <M> Продолжение после маркера',
        '<M>',
      );
      expect(withBoth.containsMarker, isTrue);
      expect(withBoth.containsPostMarkerSentence, isTrue);

      // The model emitted the sentence but never the marker: the sentence
      // is still reported independently.
      final withoutMarker = stopEvidenceFor(
        'совет. Продолжение после маркера',
        '<M>',
      );
      expect(withoutMarker.containsMarker, isFalse);
      expect(withoutMarker.containsPostMarkerText, isFalse);
      expect(withoutMarker.containsPostMarkerSentence, isTrue);

      final neither = stopEvidenceFor('короткий совет', '<M>');
      expect(neither.containsMarker, isFalse);
      expect(neither.containsPostMarkerSentence, isFalse);
    });

    test('cancels the lane subscription after terminal events', () async {
      final agent = ControlledAgent();
      final controller = StopExperimentController(agent);
      addTearDown(controller.dispose);
      controller.runComparison(
        rawPrompt: 'task',
        rawMarker: '<M>',
        thinking: ThinkingMode.enabled,
      );
      await _pump();

      agent.latest
        ..add(const AgentAnswerDelta('first'))
        ..add(const AgentCompleted());
      await _pump();
      await _pump();

      // The baseline lane reached a terminal state, so its subscription is
      // cancelled and the controlled lane has started.
      expect(agent.controllers, hasLength(2));
      expect(agent.controllers[0].hasListener, isFalse);

      // A late event on the replaced stream is buffered but never applied.
      agent.controllers[0].add(const AgentAnswerDelta('late'));
      await _pump();
      expect(controller.baseline.answer, 'first');

      agent.latest
        ..add(const AgentAnswerDelta('second'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await _pump();
      await _pump();
      expect(controller.controlled.answer, 'second');
      expect(controller.isRunning, isFalse);
    });

    test('dispose during a silent pair cancels the subscription', () async {
      final agent = ControlledAgent();
      final controller = StopExperimentController(agent);
      controller.runComparison(
        rawPrompt: 'task',
        rawMarker: '<M>',
        thinking: ThinkingMode.enabled,
      );
      await _pump();

      // The agent never emits; disposing must still cancel the subscription
      // instead of leaving the silent stream hanging.
      expect(agent.latest.hasListener, isTrue);
      controller.dispose();
      await _pump();
      expect(agent.latest.hasListener, isFalse);
    });

    test('disposal cancels without crashing', () async {
      final agent = ControlledAgent();
      final controller = StopExperimentController(agent);
      controller.runComparison(
        rawPrompt: 'task',
        rawMarker: '<M>',
        thinking: ThinkingMode.enabled,
      );
      controller.dispose();
      await agent.latest.close();
      // No exception means success.
    });
  });
}
