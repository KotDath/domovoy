import 'dart:convert';
import 'dart:io';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/projects/project_context.dart';
import 'package:domovoy/core/projects/project_run_scope.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/chat/application/chat_run_preparer.dart';
import 'package:domovoy/features/knowledge/application/project_help_preparer.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/agent_harness.dart';
import '../../../support/mcp_composition_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('/help routing is a command, arbitrary questions pass through', () {
    expect(projectHelpQuestion('normal chat'), isNull);
    expect(projectHelpQuestion('/helpful'), isNull);
    expect(projectHelpQuestion(' /help '), contains('structure'));
    expect(
      projectHelpQuestion('/help where\nis the API?'),
      'where\nis the API?',
    );
  });

  test(
    'RAG plus real factory/SDK MCP in one isolated runtime run, refreshed revisions and read-only tools',
    () async {
      final temp = await Directory.systemTemp.createTemp('project-help-');
      addTearDown(() => temp.delete(recursive: true));
      final projectA = ProjectId('project-a'),
          projectB = ProjectId('project-b');
      for (final project in [projectA, projectB]) {
        final dir = await Directory('${temp.path}/${project.value}').create();
        await File('${dir.path}/README.md').writeAsString(
          '# ${project.value}\nUnique documentation ${project.value}',
        );
        for (final args in [
          ['init', '-b', 'feature/${project.value}'],
          ['add', 'README.md'],
          [
            '-c',
            'user.name=Test',
            '-c',
            'user.email=test@example.invalid',
            'commit',
            '-m',
            'docs: baseline',
          ],
        ]) {
          final result = await Process.run('git', ['-C', dir.path, ...args]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }
      }
      final service = LocalProjectContextService(
        resolveRoot: (id) async => '${temp.path}/${id.value}',
      );
      final models =
          FakeRagModels(); // Tests only: production uses actual embeddings.
      final repository = JsonlRagRepository(FakeMemoryJsonlStorage());
      final traces = JsonlRagTraceRepository(FakeMemoryJsonlStorage());
      final scopes = ProjectRunScopes();
      final provider = RoutingLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        agentResponder: (request, index) => index.isEven
            ? toolTurn(name: projectBranchToolId, callId: 'branch-$index')
            : textTurn('Answer grounded in README.md'),
      );
      final harness = await McpCompositionHarness.start(
        provider: provider,
        projectContext: service,
        projectScopes: scopes,
        withLibrary: false,
        withAutomation: false,
      );
      addTearDown(harness.dispose);
      final coordinator = RagTurnCoordinator(
        repository: repository,
        models: models,
      );
      final fallback = RagChatController(
        coordinator: coordinator,
        traces: traces,
        registry: harness.runtime.registry,
      );
      addTearDown(fallback.dispose);
      final preparer = ProjectHelpPreparer(
        projects: service,
        coordinator: coordinator,
        scopes: scopes,
        traces: traces,
        fallback: fallback,
        ensureMcpReady: harness.mcp.initialize,
      );
      final knowledge = KnowledgeController(
        repository: repository,
        models: models,
        importer: FakeRagImporter(),
        projectContext: service,
      );
      addTearDown(knowledge.dispose);
      for (final project in [projectA, projectB]) {
        await knowledge.initialize(projectId: project.value);
        await knowledge.selectCorpus(projectDocumentationCorpus);
        await knowledge.buildIndex();
        expect(knowledge.error, isNull);
        final session = await harness.runtime
            .agent(
              testDefinition(
                tools: [ToolId('read'), ToolId('write'), ToolId('bash')],
                initialMessages: [
                  LlmMessage(
                    role: LlmMessageRole.user,
                    parts: [LlmTextPart('OLD_PRIVATE_OTHER_PROJECT')],
                  ),
                ],
              ),
            )
            .createSession(projectId: project);
        final prepared = await preparer.prepare(
          session.snapshot,
          '/help explain the structure',
          CancellationSource().token,
        );
        final scope = prepared!.options.toolContext!;
        expect(scopes.resolve(scope.scopeKey), project);
        final events = await session
            .run('/help explain the structure', options: prepared.options)
            .events
            .toList();
        expect(events.last, isA<AgentRunCompleted>());
        expect(events.whereType<AgentToolStarted>(), hasLength(1));
        expect(events.whereType<AgentToolFinished>(), hasLength(1));
        final requests = provider.agentRequests.sublist(
          provider.agentRequests.length - 2,
        );
        expect(requests.first.context.tools.map((t) => t.name), [
          projectBranchToolId,
        ]);
        expect(
          requests.first.context.systemPrompt,
          contains('Unique documentation ${project.value}'),
        );
        final other = project == projectA ? projectB : projectA;
        expect(
          requests.first.context.systemPrompt,
          isNot(contains('Unique documentation ${other.value}')),
        );
        expect(
          jsonEncode(requests.first.snapshot().toJson()),
          isNot(contains('OLD_PRIVATE_OTHER_PROJECT')),
        );
        expect(
          jsonEncode(requests.last.snapshot().toJson()),
          contains('feature/${project.value}'),
        );
        expect(
          jsonEncode(requests.last.snapshot().toJson()),
          isNot(contains(scope.scopeKey)),
        );
        await prepared.onSettled!(session.snapshot, events.last);
        expect(scopes.resolve(scope.scopeKey), isNull);
        final trace = (await traces.list(project.value, session.id.value)).last;
        expect(trace['generation'], knowledge.activeIndex!.generation);
        expect(
          (trace['candidates'] as List).single['chunk']['source'],
          'README.md',
        );

        final oldGeneration = knowledge.activeIndex!.generation;
        await File(
          '${temp.path}/${project.value}/README.md',
        ).writeAsString('Revised documentation ${project.value}');
        await expectLater(
          preparer.prepare(
            session.snapshot,
            '/help explain',
            CancellationSource().token,
          ),
          throwsA(isA<ChatPreparationException>()),
        );
        await knowledge.refreshProjectDocs();
        expect(knowledge.indexStale(knowledge.activeIndex!), isTrue);
        await knowledge.buildIndex();
        expect(knowledge.error, isNull);
        expect(knowledge.activeIndex!.generation, isNot(oldGeneration));
        expect(knowledge.indexStale(knowledge.activeIndex!), isFalse);
        expect(
          await preparer.prepare(
            session.snapshot,
            'ordinary question',
            CancellationSource().token,
          ),
          isNull,
        );
        final cancelled = CancellationSource()..cancel();
        await expectLater(
          preparer.prepare(session.snapshot, '/help explain', cancelled.token),
          throwsA(isA<RagCancelled>()),
        );
      }
      provider.resetAgentTurns();
      provider.agentResponder = (request, index) => index == 0
          ? toolTurn(name: 'write', callId: 'forged-write')
          : textTurn('Write was denied');
      final hostileSession = await harness.runtime
          .agent(testDefinition(tools: [ToolId('write')]))
          .createSession(projectId: projectB);
      final readOnly = await preparer.prepare(
        hostileSession.snapshot,
        '/help explain',
        CancellationSource().token,
      );
      final blocked = await hostileSession
          .run('/help explain', options: readOnly!.options)
          .events
          .toList();
      expect(blocked.whereType<AgentToolStarted>(), isEmpty);
      expect(
        jsonEncode(
          hostileSession.snapshot.transcript.messages
              .map((m) => m.toJson())
              .toList(),
        ),
        contains('Unknown or disabled tool'),
      );
      await readOnly.onSettled!(hostileSession.snapshot, blocked.last);

      fallback.configure(
        enabled: true,
        corpus: projectDocumentationCorpus,
        protocol: RagProtocol.m1,
        taskStateEnabled: false,
      );
      final documentOnly = await preparer.prepare(
        hostileSession.snapshot,
        'document question',
        CancellationSource().token,
      );
      expect(documentOnly!.options.preparedContext!.disableTools, isTrue);
      expect(documentOnly.options.maxToolCalls!.value, 0);
      final scopeA = scopes.begin(projectA), scopeB = scopes.begin(projectB);
      expect(scopes.permits(scopeA, projectB), isFalse);
      expect(scopes.permits(scopeB, projectA), isFalse);
      scopes.end(scopeA);
      scopes.end(scopeB);

      expect(
        await repository.documents(projectA.value, projectDocumentationCorpus),
        hasLength(1),
      );
      expect(
        (await repository.documents(
          projectA.value,
          projectDocumentationCorpus,
        )).single.text,
        contains('project-a'),
      );
    },
  );
}
