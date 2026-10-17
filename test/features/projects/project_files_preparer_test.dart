import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/features/chat/application/chat_run_preparer.dart';
import 'package:domovoy/features/projects/application/project_files_preparer.dart';
import 'package:domovoy/infrastructure/tools/local_workspace_executor_io.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  test(
    'file goal uses production loop, exact read revision, saved changes and enforced tool ceiling',
    () async {
      final root = await Directory.systemTemp.createTemp('file-goal-runtime-');
      addTearDown(() => root.delete(recursive: true));
      for (final (path, content) in [
        ('README.md', 'Old guide\n'),
        ('first.dart', 'final value = 1;'),
        ('second.dart', 'final copied = value;'),
      ]) {
        await File('${root.path}/$path').writeAsString(content);
      }
      final executor = LocalWorkspaceToolExecutor(
        resolveRoot: (_) async => root.path,
      );
      final tools = AgentToolRegistry();
      for (final descriptor in WorkspaceFileTools.descriptors) {
        tools.register(AgentTool(descriptor: descriptor, executor: executor));
      }
      final revision = sha256.convert(utf8.encode('Old guide\n')).toString();
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [
          textTurn('old project context must not cross'),
          toolTurn(name: 'find', callId: 'find', arguments: '{"pattern":"*"}'),
          for (final path in ['first.dart', 'second.dart', 'README.md'])
            toolTurn(
              name: 'read',
              callId: path,
              arguments: jsonEncode({'path': path}),
            ),
          toolTurn(
            name: 'edit',
            callId: 'edit',
            arguments: jsonEncode({
              'path': 'README.md',
              'expectedRevision': revision,
              'edits': [
                {'oldText': 'Old guide', 'newText': 'Current guide'},
              ],
            }),
          ),
          toolTurn(
            name: 'write',
            callId: 'write',
            arguments:
                '{"path":"architecture.md","content":"Actual architecture"}',
          ),
          toolTurn(
            name: 'bash',
            callId: 'denied',
            arguments: '{"command":"touch escaped"}',
          ),
          textTurn('Saved changes.'),
        ],
      );
      final runtime = testRuntime(provider: provider, tools: tools);
      final session = await runtime
          .agent(testDefinition(tools: WorkspaceFileTools.ids))
          .createSession(projectId: ProjectId('goal-project'));
      addTearDown(runtime.close);
      addTearDown(session.close);
      await session.run('old context').events.toList();
      final fallback = _Fallback();
      final preparer = ProjectFilesPreparer(fallback: fallback);
      final prepared = await preparer.prepare(
        session.snapshot,
        '/files Improve the maintainer guide from the implementation and save a new architecture note.',
        CancellationSource().token,
      );
      final events = await session
          .run(
            '/files Improve the maintainer guide from the implementation and save a new architecture note.',
            options: prepared!.options,
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(fallback.inputs, isEmpty);
      expect(
        await File('${root.path}/README.md').readAsString(),
        'Current guide\n',
      );
      expect(
        await File('${root.path}/architecture.md').readAsString(),
        'Actual architecture',
      );
      expect(await File('${root.path}/escaped').exists(), false);
      expect(
        provider.requests
            .skip(1)
            .every(
              (r) => !jsonEncode(
                r.context.messages.map((m) => m.toJson()).toList(),
              ).contains('old project context'),
            ),
        true,
      );
      for (final request in provider.requests.skip(1)) {
        expect(
          request.context.tools.map((d) => d.name).toSet(),
          WorkspaceFileTools.fileTaskIds,
        );
      }
      final messages = provider.requests.last.context.messages;
      final results = messages
          .expand((m) => m.parts)
          .whereType<LlmToolResultPart>()
          .map((r) => r.content)
          .join('\n');
      expect(results, contains(revision));
      expect(results, contains('"kind":"modified"'));
      expect(results, contains('"kind":"created"'));
      expect(results, contains('"before":"Old guide\\n"'));
      expect(results, contains('Unknown or disabled tool'));
      expect(prepared.options.preparedContext!.isolateCurrentRun, true);
      expect(
        prepared.options.preparedContext!.contribution!.systemPromptText,
        contains('RAG unavailable'),
      );
    },
  );

  test(
    'only explicit /files routes; missing project/goal and cancellation fail before model',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [],
      );
      final runtime = testRuntime(provider: provider);
      addTearDown(runtime.close);
      final session = await runtime.agent(testDefinition()).createSession();
      addTearDown(session.close);
      final fallback = _Fallback();
      final preparer = ProjectFilesPreparer(fallback: fallback);
      for (final input in [
        '/help question',
        '/filesomething',
        'an ordinary message',
      ]) {
        expect(
          await preparer.prepare(
            session.snapshot,
            input,
            CancellationSource().token,
          ),
          isNull,
        );
      }
      expect(fallback.inputs, [
        '/help question',
        '/filesomething',
        'an ordinary message',
      ]);
      expect(
        () => preparer.prepare(
          session.snapshot,
          '/files change',
          CancellationSource().token,
        ),
        throwsA(isA<ChatPreparationException>()),
      );
      final selected = await runtime
          .agent(testDefinition())
          .createSession(projectId: ProjectId('selected'));
      addTearDown(selected.close);
      expect(
        () => preparer.prepare(
          selected.snapshot,
          '/files',
          CancellationSource().token,
        ),
        throwsA(isA<ChatPreparationException>()),
      );
      final cancelled = CancellationSource()..cancel();
      expect(
        () => preparer.prepare(
          selected.snapshot,
          '/files change',
          cancelled.token,
        ),
        throwsA(anything),
      );
      expect(provider.requests, isEmpty);
    },
  );
}

final class _Fallback implements ChatRunPreparer {
  final inputs = <String>[];
  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async {
    inputs.add(input);
    return null;
  }
}
