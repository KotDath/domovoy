import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/rag/grounding.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/features/knowledge/presentation/rag_task_state_page.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_task_state_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';
import '../../../support/rag_task_state_fixture.dart';

void main() {
  testWidgets(
    'scoped state, superseded time, manual edit and off toggle persist honestly',
    (tester) async {
      final storage = FakeMemoryJsonlStorage();
      final states = JsonlRagTaskStateRepository(storage);
      final one = changedTaskState(
        RagTaskState(project: 'p', session: 's'),
        '09:00',
      );
      await states.save(
        one,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await states.save(
        changedTaskState(one, '08:30'),
        expectedRevision: 1,
        cancellation: CancellationSource().token,
      );
      final runtime = testRuntime(
        repository: InMemoryAgentSessionRepository(),
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [],
        ),
      );
      final session = await tester.runAsync(
        () => runtime
            .agent(testDefinition())
            .createSession(id: AgentSessionId('s'), projectId: ProjectId('p')),
      );
      final controller = RagChatController(
        coordinator: RagTurnCoordinator(
          repository: JsonlRagRepository(storage),
          models: FakeRagModels(),
        ),
        traces: JsonlRagTraceRepository(storage),
        registry: runtime.registry,
        taskStates: states,
      );
      addTearDown(controller.dispose);
      addTearDown(runtime.close);
      await controller.attach(session!.snapshot);
      await tester.pumpWidget(
        MaterialApp(
          theme: DomovoyTheme.light(),
          home: RagTaskStatePage(controller: controller),
        ),
      );
      expect(find.text('08:30'), findsOneWidget);
      expect(find.textContaining('Чат: s'), findsOneWidget);
      await tester.tap(find.byTooltip('Изменить constraint.time'));
      await tester.pumpAndSettle();
      final save = find.text('Сохранить ручную правку');
      await tester.scrollUntilVisible(
        save,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField).last, '07:45');
      await tester.tap(save);
      await tester.pumpAndSettle();
      final result = await JsonlRagTaskStateRepository(storage).load('p', 's');
      expect(result.facts.single.quote, '07:45');
      expect(result.facts.single.sourceKind, 'manual_user_edit');
      expect(result.superseded.map((f) => f.quote), ['09:00', '08:30']);
      await tester.scrollUntilVisible(
        find.text('Учитывать память задачи'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(controller.taskStateEnabled, false);
      expect((await states.load('p', 's')).facts.single.quote, '07:45');
      // Exercise the real manual-controller path, including text that is
      // read-only when supplied to the automatic extractor.
      await controller.editTaskFact(
        'goal.main',
        RagTaskFactKind.goal,
        'Plan another project',
      );
      await controller.editTaskFact(
        'goal.main',
        RagTaskFactKind.goal,
        'What matters most',
      );
      var manual = await states.load('p', 's');
      expect(
        manual.facts.singleWhere((f) => f.kind == RagTaskFactKind.goal).quote,
        'What matters most',
      );
      expect(
        manual.facts
            .singleWhere((f) => f.kind == RagTaskFactKind.goal)
            .sourceKind,
        'manual_user_edit',
      );
      await controller.editTaskFact(
        'goal.main',
        RagTaskFactKind.goal,
        'Remove this goal manually',
        retire: true,
      );
      manual = await states.load('p', 's');
      expect(
        manual.facts.where((f) => f.kind == RagTaskFactKind.goal),
        isEmpty,
      );
      expect(manual.retirements.single.quote, 'Remove this goal manually');
    },
  );

  for (final tampered in [false, true]) {
    testWidgets(
      'user-state source page ${tampered ? 'rejects scope mismatch' : 'distinguishes a user choice from documents'}',
      (tester) async {
        final state = changedTaskState(
          RagTaskState(project: 'p', session: 's'),
          '08:30',
        );
        final fact = state.facts.single;
        final start = fact.userText.indexOf('08:30');
        final citation = RagValidatedCitation.userState(
          state: state,
          fact: fact,
          quote: '08:30',
          start: start,
          end: start + 5,
        ).toJson();
        if (tampered) citation['project'] = 'other';
        await tester.pumpWidget(
          MaterialApp(
            theme: DomovoyTheme.light(),
            home: RagUserStateCitationPage(
              trace: {
                'project': 'p',
                'session': 's',
                'task_state': state.toJson(),
              },
              citation: citation,
            ),
          ),
        );
        if (tampered) {
          expect(find.textContaining('не совпадает'), findsOneWidget);
          expect(find.text('«08:30»'), findsNothing);
        } else {
          expect(find.text('«08:30»'), findsOneWidget);
          expect(
            find.text(
              'Выбор пользователя из этой беседы. Это не цитата документа.',
            ),
            findsOneWidget,
          );
          expect(find.text(fact.userText), findsOneWidget);
        }
      },
    );
  }
}
