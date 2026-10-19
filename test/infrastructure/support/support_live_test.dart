// Opt-in useful live smoke; never enabled by the ordinary offline suite.
// Uses only real production provider/embedding/MCP adapters, with isolated data.
import 'dart:convert';
import 'dart:io';
import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/support/application/support_catalog.dart';
import 'package:domovoy/features/support/application/support_controller.dart';
import 'package:domovoy/features/support/application/support_run_preparer.dart';
import 'package:domovoy/features/support/application/support_service.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_filesystem_storage_io.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:domovoy/infrastructure/support/jsonl_support_repository.dart';
import 'package:domovoy/infrastructure/support/support_manual.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final enabled = Platform.environment['SUPPORT_LIVE_SMOKE'] == '1';
  final replayPath = Platform.environment['SUPPORT_LIVE_REPLAY'];
  test(
    'fresh native replay of preserved live smoke (no provider invocation)',
    () async {
      final evidence =
          jsonDecode(await File(replayPath!).readAsString())
              as Map<String, dynamic>;
      final original = AgentSessionRecord.fromJson(evidence['record']);
      final directory = Directory(evidence['storageRoot'] as String);
      final sessions = JsonlAgentSessionStore(
        storage: JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: () async => directory,
          namespaceDirectoryName: 'live-sessions',
        ),
      );
      final replayed = (await sessions.load(original.id))!;
      expect(replayed.revision, greaterThanOrEqualTo(original.revision));
      expect(
        replayed.updatedAtMicros,
        greaterThanOrEqualTo(original.updatedAtMicros),
      );
      final normalized = original.copyWith(
        revision: replayed.revision,
        updatedAtMicros: replayed.updatedAtMicros,
      );
      expect(replayed.toJson(), normalized.toJson());
      final tickets = JsonlSupportRepository(
        JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: () async => directory,
          namespaceDirectoryName: 'live-support',
        ),
      );
      final ticket = (await tickets.load(evidence['ticketId'] as String))!;
      expect(ticket.toJson(), evidence['ticket']);
      expect(ticket.sessionId, original.id);
      expect(evidence['result'], 'succeeded');
      expect(evidence['supportTransport'], 'streamableHttp');
      expect(evidence['supportSidecarProcessId'], isA<int>());
      await File('$replayPath.replay.json').writeAsString(
        '${jsonEncode({'sourceTree': Platform.environment['SUPPORT_SOURCE_TREE'], 'originalEvidenceSourceTree': evidence['sourceTree'], 'result': 'pass', 'originalRevision': original.revision, 'closedRevision': replayed.revision, 'payloadEqualsExceptCloseRevisionAndTimestamp': true, 'ticketEquals': true, 'providerInvocations': 0})}\n',
      );
    },
    skip: replayPath == null
        ? 'Set SUPPORT_LIVE_REPLAY to inspect preserved live storage without any provider invocation'
        : false,
  );

  test(
    'real product support: fresh native ticket, actual embeddings + SDK HTTP context + provider + replay',
    () async {
      final outputPath = Platform.environment['SUPPORT_LIVE_OUTPUT'];
      if (outputPath == null ||
          Platform.environment['DEEPSEEK_API_KEY']?.isNotEmpty != true) {
        throw StateError(
          'Explicit evidence output and existing credential required',
        );
      }
      final output = File(outputPath);
      expect(
        output.existsSync(),
        false,
        reason: 'Never overwrite live evidence',
      );
      final directory = Directory(
        '${output.parent.path}/live-data-${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
      final client = http.Client();
      final credentials = DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (key) => Platform.environment[key],
      );
      JsonlFilesystemStreamStorage storage(String name) =>
          JsonlFilesystemStreamStorage(
            applicationSupportDirectoryResolver: () async => directory,
            namespaceDirectoryName: name,
          );
      final sessionStorage = storage('live-sessions');
      final sessions = JsonlAgentSessionStore(storage: sessionStorage);
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: credentials,
        repository: sessions,
        catalog: sessions,
      );
      final tickets = JsonlSupportRepository(storage('live-support'));
      final scopes = SupportRunScopes();
      final mcp = DomovoyMcpComposition.build(
        runtime: stack.runtime,
        tools: stack.runtime.tools,
        policies: stack.runtime.policies,
        registry: stack.registry,
        sessions: sessions,
        catalog: SupportSessionCatalog(sessions),
        piToolIds: const {},
        inputs: const McpCompositionInputs(
          localTransportPreference: McpLocalTransportPreference.stream,
          useDesktopSidecar: true,
        ),
        supportRepository: tickets,
        supportScopes: scopes,
      );
      final ragStorage = storage('live-support-rag');
      final models = RagModelServiceClient(
        client,
        Uri.parse('http://127.0.0.1:8765'),
      );
      final preparer = SupportRunPreparer(
        tickets: tickets,
        scopes: scopes,
        repository: JsonlRagRepository(ragStorage),
        models: models,
        traces: JsonlRagTraceRepository(ragStorage),
        ensureMcpReady: mcp.initialize,
        mcpReady: () => supportToolIds.every(
          (id) => mcp.host.snapshot.catalog.lookup(id) != null,
        ),
        loadManual: () =>
            BundledSupportManual.load(read: (p) => File(p).readAsString()),
      );
      final definition = supportDefinition(
        BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      );
      final service = SupportService(
        tickets: tickets,
        sessions: sessions,
        catalog: sessions,
        runtime: stack.runtime,
        definition: definition,
      );
      final chat = ChatWorkspaceController(
        runtime: stack.runtime,
        definition: definition,
        catalog: SupportSessionCatalog(sessions, support: true),
        repository: sessions,
        registry: stack.registry,
        runPreparer: preparer,
        supportMode: true,
      );
      SupportSnapshot snapshot(ModelRef model) => SupportSnapshot(
        observedAt: DateTime.now().microsecondsSinceEpoch,
        platform: Platform.operatingSystem,
        version: preparer.packageVersion,
        provider: model.providerId.value,
        model: model.modelId.value,
        mcp: 'Live smoke; actual observations in tool timeline',
        rag: 'Health/retrieval checked during turn',
      );
      final controller = SupportController(
        service: service,
        chat: chat,
        preparer: preparer,
        captureSnapshot: snapshot,
        initialSelection: () =>
            AgentSessionSelection.fromDefinition(definition),
      );
      try {
        await controller.initialize();
        final ticket = await service.create(
          subject: 'Как устроены обращения поддержки?',
          description:
              'Хочу понять, кто меняет статус и как продолжить решённое обращение.',
          snapshot: snapshot(definition.model),
        );
        await controller.select(ticket);
        final result = await controller.send(
          'Как отметить решение, а затем продолжить это же обращение? На какие данные опирается консультант поддержки?',
        );
        final endpoint = mcp.localServers.endpointFor('support');
        expect(endpoint, isA<LocalMcpHttpEndpoint>());
        expect((endpoint as LocalMcpHttpEndpoint).processId, isNotNull);
        final record = (await sessions.load(ticket.sessionId))!;
        final traces = await preparer.traces.list(
          supportRagProject,
          ticket.sessionId.value,
        );
        await controller.close();
        await mcp.close();
        await stack.runtime.close();
        final replayTickets = JsonlSupportRepository(storage('live-support'));
        final replaySession = await JsonlAgentSessionStore(
          storage: storage('live-sessions'),
        ).load(ticket.sessionId);
        final report = {
          'sourceTree':
              Platform.environment['SUPPORT_SOURCE_TREE'] ?? 'unrecorded',
          'storageRoot': directory.path,
          'supportTransport': endpoint.kind.name,
          'supportSidecarProcessId': endpoint.processId,
          'sessionId': ticket.sessionId.value,
          'ticketId': ticket.id,
          'result': result.status.name,
          'error': chat.state.error?.message,
          'preparationError': preparer.error,
          'ticket': (await replayTickets.load(ticket.id))!.toJson(),
          'record': record.toJson(),
          'traces': traces,
          'freshReplayEquals':
              jsonEncode(
                    record
                        .copyWith(
                          revision: replaySession!.revision,
                          updatedAtMicros: replaySession.updatedAtMicros,
                        )
                        .toJson(),
                  ) ==
                  jsonEncode(replaySession.toJson()) &&
              replaySession.revision >= record.revision &&
              replaySession.updatedAtMicros >= record.updatedAtMicros,
        };
        output.parent.createSync(recursive: true);
        output.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          flush: true,
        );
        expect(
          result.isSuccess,
          true,
          reason: preparer.error ?? chat.state.error?.message,
        );
        expect(report['freshReplayEquals'], true);
        expect(traces.single['protocol'], 'm1');
        expect(
          record.transcript.messages
              .expand((m) => m.parts)
              .whereType<LlmToolResultPart>()
              .length,
          greaterThanOrEqualTo(2),
        );
        // Final admission itself verifies exact current-scope successful results.
        expect(
          record.transcript.messages.last.parts.whereType<LlmTextPart>(),
          isNotEmpty,
        );
        stdout.writeln(
          'Live support evidence written; real SDK HTTP/RAG/provider completed, fresh replay matches.',
        );
      } finally {
        await controller.close();
        await mcp.close();
        await stack.runtime.close();
        await stack.providerModelCatalog?.close();
        client.close();
      }
    },
    skip: !enabled
        ? 'Set SUPPORT_LIVE_SMOKE=1 with explicit external SUPPORT_LIVE_OUTPUT to run paid smoke'
        : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
