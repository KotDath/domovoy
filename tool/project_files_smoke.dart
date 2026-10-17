// Real-provider file-goal probe. Operates on an explicitly supplied disposable
// local checkout; no scenario-specific paths, scripted tools or fake replies.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/projects/documentation_context.dart';
import 'package:domovoy/core/projects/project_context.dart';
import 'package:domovoy/core/rag/index_builder.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/chat/application/chat_run_preparer.dart';
import 'package:domovoy/features/projects/application/project_files_preparer.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_filesystem_storage_io.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:domovoy/infrastructure/runtime/production_agent_stack.dart';
import 'package:domovoy/infrastructure/tools/local_workspace_executor_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'Usage: dart run tool/project_files_smoke.dart CHECKOUT GOAL_FILE ARTIFACT_DIRECTORY RAG_URL',
    );
    exitCode = 2;
    return;
  }
  final root = await Directory(args[0]).resolveSymbolicLinks();
  final artifacts = Directory(p.absolute(args[2]));
  if (root == artifacts.path || p.isWithin(root, artifacts.path)) {
    throw ArgumentError(
      'Artifacts must be outside the model-visible checkout.',
    );
  }
  await artifacts.create(recursive: true);
  final input = '/files ${await File(args[1]).readAsString()}';
  final token = CancellationSource();
  final timer = Timer(const Duration(minutes: 20), token.cancel);
  final signals = [
    ProcessSignal.sigint.watch().listen((_) => token.cancel()),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => token.cancel()),
  ];
  final client = http.Client();
  final storage = JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: () async =>
        Directory(p.join(artifacts.path, 'state')),
  );
  final registry = AgentToolRegistry();
  final executor = LocalWorkspaceToolExecutor(resolveRoot: (_) async => root);
  for (final descriptor in WorkspaceFileTools.descriptors) {
    registry.register(AgentTool(descriptor: descriptor, executor: executor));
  }
  final stack = buildProductionAgentStack(
    httpClient: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(),
      readEnvironment: (name) => Platform.environment[name],
    ),
    storage: storage,
    tools: registry,
    enabledTools: WorkspaceFileTools.ids,
    loadBundled: () => File('assets/models_fallback.json').readAsString(),
  );
  AgentSession? session;
  final progress = File(p.join(artifacts.path, 'progress.jsonl')).openWrite();
  void log(Map<String, Object?> event) {
    progress.writeln(jsonEncode(event));
  }

  try {
    final project = ProjectId('file-smoke');
    final context = LocalProjectContextService(resolveRoot: (_) async => root);
    final repository = JsonlRagRepository(storage);
    final models = RagModelServiceClient(
      client,
      Uri.parse(args[3]),
      allowLoopbackHttp: true,
    );
    final docs = await context.scanDocumentation(project, token.token);
    await repository.saveDocuments(
      project.value,
      projectDocumentationCorpus,
      docs,
    );
    final model = await models.health(token.token);
    final index = await buildRagIndex(
      models: models,
      model: model,
      documents: docs,
      strategy: ChunkStrategy.structure,
      cancellation: token.token,
      progress: (stage, done, total) => log({
        'type': 'rag_progress',
        'stage': stage,
        'done': done,
        'total': total,
      }),
    );
    await repository.publishIndex(
      project.value,
      projectDocumentationCorpus,
      index,
    );
    session = await createProjectFileProbeSession(stack, project);
    final preparer = ProjectFilesPreparer(
      fallback: _Fallback(),
      projects: context,
      coordinator: RagTurnCoordinator(repository: repository, models: models),
    );
    final prepared = await preparer.prepare(
      session.snapshot,
      input,
      token.token,
    );
    final audit = prepared!.options.preparedContext!.contribution!.audit;
    log({
      'type': 'prepared',
      'rag': audit is ProjectDocumentationContext ? audit.toJson() : null,
    });
    final run = session.run(input, options: prepared.options);
    final cancel = token.token.register(run.cancel);
    AgentRunEvent? terminal;
    try {
      await for (final event in run.events) {
        if (event.isTerminal) terminal = event;
        // Reasoning and raw requests are intentionally omitted from artifacts.
        if (event is AgentToolAssembled) {
          log({
            'type': 'tool_calls',
            'calls': event.calls.map((c) => c.toJson()).toList(),
          });
        }
        if (event is AgentToolFinished) {
          log({
            'type': 'tool_finished',
            'call_id': event.callId.value,
            'success': event.success,
          });
        }
        if (event.isTerminal) log({'type': event.runtimeType.toString()});
      }
    } finally {
      cancel.dispose();
    }
    await prepared.onSettled?.call(session.snapshot, terminal);
    final replay = await verifyProjectFileProbeReplay(storage, session);
    final calls = <String, LlmToolCallPart>{};
    final results = <Map<String, Object?>>[];
    for (final message in session.snapshot.transcript.messages) {
      for (final part in message.parts) {
        if (part is LlmToolCallPart) calls[part.callId.value] = part;
        if (part is LlmToolResultPart) {
          results.add({
            'call_id': part.callId.value,
            'name': calls[part.callId.value]?.name,
            'arguments': calls[part.callId.value]?.arguments,
            'result': jsonDecode(part.content),
          });
        }
      }
    }
    final answer = session.snapshot.transcript.messages.last.parts
        .whereType<LlmTextPart>()
        .map((p) => p.text)
        .join();
    final changes = results
        .map((r) => r['result'])
        .whereType<Map>()
        .map((r) => r['change'])
        .whereType<Map>()
        .toList();
    final readBack = <Map<String, Object?>>[];
    final latestChanges = {
      for (final change in changes) change['path'] as String: change,
    };
    for (final change in latestChanges.values) {
      final path = change['path'] as String;
      final actual = await File(p.join(root, path)).readAsString();
      readBack.add({
        'path': path,
        'matches_saved_after': actual == change['after'],
        'content': actual,
      });
    }
    await File(p.join(artifacts.path, 'report.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'root': root,
        'agent_session_replay': replay,
        'goal': input,
        'terminal': terminal.runtimeType.toString(),
        'documentation_sources': docs
            .map((d) => {'path': d.source, 'revision': d.revision})
            .toList(),
        'rag_generation': index.generation,
        'rag_fingerprint': index.fingerprint,
        'tool_results': results,
        'saved_changes': changes,
        'fresh_readback': readBack,
        'answer': answer,
      }),
    );
    await File(p.join(artifacts.path, 'answer.md')).writeAsString(answer);
    exitCode = terminal is AgentRunCompleted
        ? 0
        : token.token.isCancelled
        ? 130
        : 1;
    stdout.writeln(
      'Terminal: ${terminal.runtimeType}; ${results.length} tool results, ${changes.length} change records. Artifacts: ${artifacts.path}',
    );
  } finally {
    timer.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
    await progress.close();
    await session?.close();
    await stack.runtime.close();
    client.close();
  }
}

final class _Fallback implements ChatRunPreparer {
  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async => null;
}

/// Explicit durable composition shared with the offline persistence regression.
Future<AgentSession> createProjectFileProbeSession(
  ProductionAgentStack stack,
  ProjectId project,
) => stack.runtime
    .agent(stack.promptDefinition)
    .createSession(
      projectId: project,
      persistence: SessionPersistence.repository,
    );

/// A fresh store must replay the exact completed/cancelled transcript. RAG
/// streams alone are not evidence that an agent session was persisted.
Future<Map<String, Object?>> verifyProjectFileProbeReplay(
  JsonlFilesystemStreamStorage storage,
  AgentSession session,
) async {
  final record = await JsonlAgentSessionStore(
    storage: storage,
  ).load(session.id);
  if (record == null ||
      jsonEncode(record.transcript.toJson()) !=
          jsonEncode(session.snapshot.transcript.toJson())) {
    throw StateError(
      'Agent-session JSONL replay is missing or differs from the actual transcript.',
    );
  }
  final results = record.transcript.messages
      .expand((m) => m.parts)
      .whereType<LlmToolResultPart>()
      .toList();
  return {
    'session_id': session.id.value,
    'persistence': 'repository',
    'fresh_store_transcript_matches': true,
    'tool_result_count': results.length,
    'change_result_count': results.where((r) {
      final decoded = jsonDecode(r.content);
      return decoded is Map && decoded['change'] is Map;
    }).length,
  };
}
