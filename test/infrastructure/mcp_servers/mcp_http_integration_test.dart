import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/infrastructure/mcp_servers/archive_api_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/archive_server_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/archive_task_store_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/briefing_server_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/briefing_service_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/demo_flow_io.dart';
import 'package:domovoy/infrastructure/tools/mcp_remote_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'two HTTP MCP servers discover, route and persist the full pipeline',
    () async {
      final requests = <Uri>[];
      final api = ArchiveApi(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path == '/advancedsearch.php') {
            return http.Response(
              jsonEncode({
                'response': {
                  'numFound': 1,
                  'docs': [
                    {
                      'identifier': 'test-item',
                      'title': 'Test film',
                      'description': 'An animated film',
                      'mediatype': 'movies',
                    },
                  ],
                },
              }),
              200,
            );
          }
          if (request.url.path == '/metadata/test-item') {
            return http.Response(
              jsonEncode({
                'metadata': {
                  'title': 'Test film',
                  'description': 'An animated film',
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final directory = await Directory.systemTemp.createTemp(
        'domovoy-mcp-test-',
      );
      final archive = ArchiveMcpService(
        api: api,
        tasks: ArchiveTaskStore(File('${directory.path}/tasks.jsonl')),
        port: 0,
      );
      await archive.start();
      final archiveEndpoint = Uri.parse(
        'http://127.0.0.1:${archive.boundPort}/mcp',
      );
      final store = File('${directory.path}/reports.jsonl');
      final briefing = BriefingMcpServer(
        service: BriefingService(
          dataFile: store,
          searchArchive: ArchiveMcpSource(archiveEndpoint).search,
          pollInterval: const Duration(hours: 1),
        ),
        port: 0,
      );
      await briefing.start();
      final briefingEndpoint = Uri.parse(
        'http://127.0.0.1:${briefing.boundPort}/mcp',
      );
      try {
        final flow = await runMcpDemoFlow(
          archiveEndpoint: archiveEndpoint,
          briefingEndpoint: briefingEndpoint,
          query: 'subject:animation',
        );
        expect(
          flow['archiveTools'],
          containsAll([
            'archive_search',
            'archive_item',
            'task_create',
            'task_list',
            'task_complete',
          ]),
        );
        expect(
          flow['briefingTools'],
          containsAll([
            'summarize_items',
            'save_digest',
            'schedule_digest',
            'list_digests',
          ]),
        );
        expect(flow['order'], [
          'archive_search',
          'archive_item',
          'task_create',
          'summarize_items',
          'save_digest',
          'task_complete',
          'list_digests',
        ]);
        expect((flow['saved'] as Map)['count'], 1);
        expect((flow['completedTask'] as Map)['status'], 'done');
        expect(requests.map((uri) => uri.path), [
          '/advancedsearch.php',
          '/metadata/test-item',
        ]);
        expect(await store.readAsLines(), hasLength(1));
        expect(
          await File('${directory.path}/tasks.jsonl').readAsLines(),
          hasLength(2),
        );

        final bridge = await McpRemoteTools.connect({
          'archive': archiveEndpoint,
          'briefing': briefingEndpoint,
        });
        try {
          expect(
            bridge.enabled.map((id) => id.value),
            containsAll(['archive__archive_search', 'briefing__list_digests']),
          );
          final executor = bridge.registry
              .lookup('briefing__list_digests')!
              .executor;
          final result = await executor.execute(
            ToolInvocation(
              callId: 'test',
              name: 'briefing__list_digests',
              arguments: {},
            ),
            cancellation: CancellationSource().token,
            liveness: _NoProgress(),
          );
          expect(result.success, isTrue);
          expect((result.output as Map)['reports'], hasLength(1));
        } finally {
          await bridge.close();
        }
      } finally {
        await briefing.stop();
        await archive.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'scheduled digests run through Archive MCP and survive restart',
    () async {
      final api = ArchiveApi(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'response': {
                'numFound': 1,
                'docs': [
                  {'identifier': 'scheduled-item', 'title': 'Scheduled film'},
                ],
              },
            }),
            200,
          ),
        ),
      );
      final directory = await Directory.systemTemp.createTemp(
        'domovoy-mcp-schedule-',
      );
      final archive = ArchiveMcpService(
        api: api,
        tasks: ArchiveTaskStore(File('${directory.path}/tasks.jsonl')),
        port: 0,
      );
      await archive.start();
      final source = ArchiveMcpSource(
        Uri.parse('http://127.0.0.1:${archive.boundPort}/mcp'),
      );
      final file = File('${directory.path}/reports.jsonl');
      var current = DateTime.utc(2026, 1, 1);
      final service = BriefingService(
        dataFile: file,
        searchArchive: source.search,
        now: () => current,
        pollInterval: const Duration(hours: 1),
      );
      try {
        await service.start();
        final schedule = await service.schedule('mediatype:movies', 60);
        final run = await service.runDue();
        expect(run['completed'], 1);
        expect(
          service.reports(scheduleId: schedule['id'] as String),
          hasLength(1),
        );
        current = current.add(const Duration(seconds: 60));
        expect((await service.runDue())['completed'], 1);
        await service.stop();

        final restored = BriefingService(
          dataFile: file,
          searchArchive: source.search,
          now: () => current,
          pollInterval: const Duration(hours: 1),
        );
        await restored.start();
        expect(restored.schedules().single['runCount'], 2);
        expect(restored.reports(), hasLength(2));
        expect(
          (await restored.cancel(schedule['id'] as String))['cancelled'],
          true,
        );
        await restored.stop();

        final cancelled = BriefingService(
          dataFile: file,
          searchArchive: source.search,
          now: () => current,
          pollInterval: const Duration(hours: 1),
        );
        await cancelled.start();
        expect(cancelled.schedules(), isEmpty);
        expect(cancelled.reports(), hasLength(2));
        await cancelled.stop();
      } finally {
        await service.stop();
        await archive.stop();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _NoProgress implements ToolExecutionLiveness {
  @override
  void reportProgress({String? detail}) {}
}
