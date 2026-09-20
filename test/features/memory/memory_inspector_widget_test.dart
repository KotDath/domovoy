import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/memory/application/memory_inspector_controller.dart';
import 'package:domovoy/features/memory/application/memory_inspector_state.dart';
import 'package:domovoy/features/memory/presentation/memory_inspector_panel.dart';
import 'package:domovoy/features/memory/presentation/memory_inspector_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

final projectId = ProjectId('project-1');
final open = CancellationSource().token;

final class _Fixture {
  _Fixture({
    required this.controller,
    required this.working,
    required this.candidates,
    required this.candidate,
  });

  final MemoryInspectorController controller;
  final InMemoryMemoryEntryRepository working;
  final InMemoryMemoryCandidateRepository candidates;
  final MemoryCandidate candidate;
}

Future<_Fixture> _fixture() async {
  final working = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
  final longTerm = InMemoryMemoryEntryRepository(layer: MemoryLayer.longTerm);
  final candidates = InMemoryMemoryCandidateRepository();
  await working.save(
    workingEntry(id: 'entry-working', content: 'Working requirement.'),
    expectedRevision: 0,
    cancellation: open,
  );
  await longTerm.save(
    longTermEntry(id: 'entry-longterm', content: 'Prefers concise answers.'),
    expectedRevision: 0,
    cancellation: open,
  );
  final candidate = createCandidate(
    id: 'candidate-1',
    content: 'Candidate fact from extraction.',
  );
  await candidates.save(candidate, expectedRevision: 0, cancellation: open);
  final repositories = MemoryRepositories(
    workingRepository: working,
    longTermRepository: longTerm,
    candidateRepository: candidates,
  );
  var sequence = 0;
  final controller = MemoryInspectorController(
    repositories: repositories,
    retrieval: LayeredMemoryRetrievalService(repositories: repositories),
    toggles: MemoryReadTogglesController(),
    entryIds: () => 'entry-${++sequence}',
    nowMicros: () => 1000,
  );
  final session = AgentSessionSnapshot(
    id: AgentSessionId('session-1'),
    definition: AgentDefinition(
      id: AgentId('tester'),
      name: 'Tester',
      systemPrompt: 'You are a test agent.',
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      policy: PolicyId('deny'),
    ),
    lifecycle: AgentSessionLifecycle.idle,
    transcript: AgentTranscript(
      messages: <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[LlmTextPart('Deployment uses kubernetes.')],
        ),
      ],
      messageIds: <AgentTranscriptMessageId?>[AgentTranscriptMessageId('m0')],
    ),
    usage: LlmUsage(),
    modelTurns: 0,
    toolAttempts: 0,
    revision: 0,
    compactionState: null,
  );
  await controller.attachSession(session: session, projectId: projectId);
  return _Fixture(
    controller: controller,
    working: working,
    candidates: candidates,
    candidate: candidate,
  );
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: DomovoyTheme.light(),
    home: Scaffold(body: child),
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPanel(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(
    _app(
      Center(
        child: SizedBox(
          width: DomovoyDimensions.memoryPanelWidth,
          height: 760,
          child: MemoryInspectorPanel(controller: fixture.controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop and tablet widths render the pane without overflow', (
    tester,
  ) async {
    for (final size in <Size>[const Size(1400, 900), const Size(900, 900)]) {
      _setSize(tester, size);
      final fixture = await _fixture();
      await _pumpPanel(tester, fixture);
      expect(find.byKey(const ValueKey('memory-panel')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('memory-layer-shortTerm')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      fixture.controller.dispose();
    }
  });

  testWidgets('phone sheet opens and closes with system Back', (tester) async {
    _setSize(tester, const Size(400, 800));
    final fixture = await _fixture();
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('open-memory'),
              onPressed: () =>
                  showMemoryInspectorSheet(context, fixture.controller),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-memory')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-panel')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-panel')), findsNothing);
    fixture.controller.dispose();
  });

  testWidgets('read toggles update the controller from the panel', (
    tester,
  ) async {
    _setSize(tester, const Size(1400, 900));
    final fixture = await _fixture();
    await _pumpPanel(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('memory-toggle-longterm')));
    await tester.pumpAndSettle();
    expect(fixture.controller.state.includeLongTerm, isFalse);

    await tester.tap(find.byKey(const ValueKey('memory-toggle-working')));
    await tester.pumpAndSettle();
    expect(fixture.controller.state.includeWorking, isFalse);
    fixture.controller.dispose();
  });

  testWidgets('candidate can be confirmed, edited, and rejected', (
    tester,
  ) async {
    _setSize(tester, const Size(900, 900));
    final fixture = await _fixture();
    await _pumpPanel(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('memory-layer-candidates')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('memory-candidate-candidate-1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('memory-edit-candidate-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory-edit-field')),
      'Edited candidate content.',
    );
    await tester.tap(find.byKey(const ValueKey('memory-edit-save')));
    await tester.pumpAndSettle();
    final edited = await fixture.candidates.load(
      MemoryCandidateId('candidate-1'),
      cancellation: open,
    );
    expect(edited!.content, 'Edited candidate content.');

    await tester.tap(find.byKey(const ValueKey('memory-confirm-candidate-1')));
    await tester.pumpAndSettle();
    expect(fixture.controller.state.candidates, isEmpty);
    expect(fixture.controller.state.working, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('memory-layer-candidates')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-empty')), findsOneWidget);
    fixture.controller.dispose();
  });

  testWidgets('working entry can be edited and forgotten from the panel', (
    tester,
  ) async {
    _setSize(tester, const Size(900, 900));
    final fixture = await _fixture();
    await _pumpPanel(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('memory-layer-working')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('memory-edit-entry-entry-working')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory-edit-field')),
      'Edited working requirement.',
    );
    await tester.tap(find.byKey(const ValueKey('memory-edit-save')));
    await tester.pumpAndSettle();
    final edited = await fixture.working.load(
      MemoryEntryId('entry-working'),
      cancellation: open,
    );
    expect(edited!.content, 'Edited working requirement.');

    await tester.tap(find.byKey(const ValueKey('memory-forget-entry-working')));
    await tester.pumpAndSettle();

    expect(await fixture.working.list(cancellation: open), isEmpty);
    expect(fixture.controller.state.working, isEmpty);
    fixture.controller.dispose();
  });

  testWidgets('trace display toggles from the panel', (tester) async {
    _setSize(tester, const Size(1400, 900));
    final fixture = await _fixture();
    await _pumpPanel(tester, fixture);
    expect(find.byKey(const ValueKey('memory-trace-list')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('memory-trace-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-trace-list')), findsOneWidget);
    fixture.controller.dispose();
  });
}
