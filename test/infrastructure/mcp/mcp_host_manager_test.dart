import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../support/mcp_fakes.dart';
import '../../support/mcp_fixture_servers.dart';
import '../../support/memory_jsonl_storage.dart';

void main() {
  late CancellationToken token;

  setUp(() {
    token = CancellationSource().token;
  });

  group('host manager with real built-in servers', () {
    late LocalMcpServerHost servers;
    late McpHostManager manager;
    late MemoryMcpDiagnosticsSink diagnostics;

    final serverIds = <String>['arxiv', 'digest', 'library', 'automation'];
    final uniqueTools = <String, String>{
      'arxiv': 'search_papers',
      'digest': 'summarize_papers',
      'library': 'save_digest',
      'automation': 'create_task',
    };

    setUp(() async {
      diagnostics = MemoryMcpDiagnosticsSink();
      servers = LocalMcpServerHost(
        preference: McpLocalTransportPreference.stream,
        runtimeSecrets: RuntimeMcpSecretResolver(),
        diagnostics: diagnostics,
      );
      final repository = InMemoryMcpConnectionRepository();
      for (final serverId in serverIds) {
        final unique = uniqueTools[serverId]!;
        servers.register(
          FixtureMcpServerFactory(
            serverId: serverId,
            displayName: serverId,
            tools: <FixtureTool>[
              ...fixtureToolsFor(serverId),
              FixtureTool(
                name: unique,
                description: 'Unique tool of $serverId',
                handler: (args, extra) async => sdk.CallToolResult(
                  content: <sdk.Content>[
                    sdk.TextContent(text: '$serverId:$unique'),
                  ],
                  structuredContent: <String, dynamic>{
                    'server': serverId,
                    'tool': unique,
                  },
                ),
              ),
            ],
          ),
        );
        await servers.start(serverId);
        await repository.save(
          servers.connectionConfig(serverId),
          expectedRevision: 0,
          cancellation: token,
        );
      }
      manager = McpHostManager(
        transports: McpSdkTransportFactory(
          streams: servers,
          diagnostics: diagnostics,
        ),
        repository: repository,
        secrets: RuntimeMcpSecretResolver(),
        diagnostics: diagnostics,
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
      );
    });

    tearDown(() async {
      await manager.stop();
      manager.dispose();
      await servers.stopAll();
    });

    test('keeps four isolated catalogs with unique model names', () async {
      await manager.start();
      await waitFor(
        () => manager.snapshot.connections.every((status) => status.isReady),
      );
      final snapshot = manager.snapshot;
      expect(snapshot.connections.length, 4);
      for (final serverId in serverIds) {
        final id = McpConnectionId(serverId);
        final tools = snapshot.catalog
            .forConnection(id)
            .map((route) => route.originalToolName)
            .toSet();
        expect(tools, <String>{
          'search',
          'echo',
          'fail',
          uniqueTools[serverId]!,
        }, reason: serverId);
        expect(snapshot.statusFor(id)!.handshake!.serverName, serverId);
      }
      expect(snapshot.catalog.length, 16);
      // Same tool names on different servers never share a model name.
      final modelNames = snapshot.catalog.routes
          .map((route) => route.modelToolName.value)
          .toList();
      expect(modelNames.toSet().length, modelNames.length);
      expect(modelNames, contains('mcp_arxiv__search'));
      expect(modelNames, contains('mcp_digest__search'));
      expect(
        snapshot.catalog.lookup('mcp_arxiv__search_papers')!.connectionId,
        McpConnectionId('arxiv'),
      );
    });

    test(
      'routes calls to the owning server and never leaks across catalogs',
      () async {
        await manager.start();
        await waitFor(
          () => manager.snapshot.connections.every((status) => status.isReady),
        );
        for (final serverId in serverIds) {
          final unique = uniqueTools[serverId]!;
          final result = await manager.callTool(
            modelToolName: 'mcp_${serverId}__$unique',
            arguments: const <String, Object?>{},
          );
          expect(result.isError, isFalse, reason: serverId);
          expect(result.structuredContent, <String, Object?>{
            'server': serverId,
            'tool': unique,
          }, reason: serverId);
        }
        await expectLater(
          manager.callTool(
            modelToolName: 'mcp_arxiv__does_not_exist',
            arguments: const <String, Object?>{},
          ),
          throwsA(
            isA<McpException>().having(
              (error) => error.error.kind,
              'kind',
              McpErrorKind.toolNotFound,
            ),
          ),
        );
      },
    );

    test('removing a connection removes its routes atomically', () async {
      await manager.start();
      await waitFor(
        () => manager.snapshot.connections.every((status) => status.isReady),
      );
      expect(
        manager.snapshot.catalog.lookup('mcp_arxiv__search_papers'),
        isNotNull,
      );
      await manager.removeConnection(McpConnectionId('arxiv'));
      expect(
        manager.snapshot.catalog.lookup('mcp_arxiv__search_papers'),
        isNull,
      );
      expect(
        manager.snapshot.catalog.lookup('mcp_library__save_digest'),
        isNotNull,
      );
      expect(
        manager.snapshot.connections.any(
          (status) => status.id == McpConnectionId('arxiv'),
        ),
        isFalse,
      );
      await expectLater(
        manager.callTool(
          modelToolName: 'mcp_arxiv__search_papers',
          arguments: const <String, Object?>{},
        ),
        throwsA(isA<McpException>()),
      );
    });

    test('refreshCatalog is atomic and keeps the catalog stable', () async {
      await manager.start();
      await waitFor(
        () => manager.snapshot.connections.every((status) => status.isReady),
      );
      final before = manager.snapshot;
      await manager.refreshCatalog();
      final after = manager.snapshot;
      expect(after.catalog.length, before.catalog.length);
      final beforeNames = before.catalog.routes
          .map((route) => route.modelToolName.value)
          .toList();
      final afterNames = after.catalog.routes
          .map((route) => route.modelToolName.value)
          .toList();
      expect(afterNames, beforeNames);
    });
  });

  group('host manager with scripted connections', () {
    late InMemoryMcpConnectionRepository repository;
    late McpHostManager manager;

    McpConnectionConfig configFor(String id) => McpConnectionConfig(
      connectionId: McpConnectionId(id),
      alias: id,
      transport: McpInProcessStreamTransportConfig(serverId: id),
    );

    setUp(() async {
      repository = InMemoryMcpConnectionRepository();
    });

    tearDown(() async {
      await manager.stop();
      manager.dispose();
    });

    Future<void> save(
      McpConnectionConfig config, {
      int expectedRevision = 0,
    }) async {
      await repository.save(
        config,
        expectedRevision: expectedRevision,
        cancellation: token,
      );
    }

    test(
      'fetches the whole catalog across paginated tools/list pages',
      () async {
        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('paged'),
          pages: <McpToolPage>[
            McpToolPage(
              tools: <McpToolDescriptor>[
                scriptedTool('paged', 'a'),
                scriptedTool('paged', 'b'),
              ],
              nextCursor: '1',
            ),
            McpToolPage(
              tools: <McpToolDescriptor>[
                scriptedTool('paged', 'c'),
                scriptedTool('paged', 'd'),
              ],
              nextCursor: '2',
            ),
            McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'e')]),
          ],
        );
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            <String, ScriptedMcpConnection Function()>{
              'paged': () => connection,
            },
          ),
          repository: repository,
          secrets: InMemoryMcpSecretVault(),
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        await save(configFor('paged'));
        await manager.start();
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        expect(connection.listedCursors, <String?>[null, '1', '2']);
        expect(manager.snapshot.catalog.length, 5);
        expect(manager.snapshot.catalog.lookup('mcp_paged__e'), isNotNull);
      },
    );

    test(
      'repeating pagination cursor fails the connection explicitly',
      () async {
        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('paged'),
          pages: <McpToolPage>[
            McpToolPage(
              tools: <McpToolDescriptor>[scriptedTool('paged', 'a')],
              nextCursor: 'x',
            ),
            McpToolPage(
              tools: <McpToolDescriptor>[scriptedTool('paged', 'b')],
              nextCursor: 'x',
            ),
          ],
        );
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            <String, ScriptedMcpConnection Function()>{
              'paged': () => connection,
            },
          ),
          repository: repository,
          secrets: InMemoryMcpSecretVault(),
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        await save(configFor('paged'));
        await manager.start();
        final status = manager.snapshot.statusFor(McpConnectionId('paged'))!;
        expect(status.phase, McpConnectionPhase.failed);
        expect(status.lastError, contains('pagination cursor'));
        expect(manager.snapshot.catalog.isEmpty, isTrue);
      },
    );

    test(
      'unexpected close drops stale routes and reconnect restores them',
      () async {
        var created = 0;
        late ScriptedMcpConnection first;
        late ScriptedMcpConnection second;
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            <String, ScriptedMcpConnection Function()>{
              'paged': () {
                created += 1;
                if (created == 1) {
                  first = ScriptedMcpConnection(
                    connectionId: McpConnectionId('paged'),
                    pages: <McpToolPage>[
                      McpToolPage(
                        tools: <McpToolDescriptor>[scriptedTool('paged', 'a')],
                      ),
                    ],
                  );
                  return first;
                }
                second = ScriptedMcpConnection(
                  connectionId: McpConnectionId('paged'),
                  pages: <McpToolPage>[
                    McpToolPage(
                      tools: <McpToolDescriptor>[scriptedTool('paged', 'a')],
                    ),
                  ],
                );
                return second;
              },
            },
          ),
          repository: repository,
          secrets: InMemoryMcpSecretVault(),
          reconnectPolicy: McpReconnectPolicy(
            maxAttempts: 2,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
          delay: (duration) async {},
        );
        await save(configFor('paged'));
        await manager.start();
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);

        first.triggerUnexpectedClose();
        expect(
          manager.snapshot.statusFor(McpConnectionId('paged'))!.phase,
          McpConnectionPhase.failed,
        );
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);

        await waitFor(
          () =>
              created >= 2 &&
              manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);
        expect(second.connectCount, 1);
      },
    );

    test('call timeout and cancellation propagate through the host', () async {
      final connection = ScriptedMcpConnection(
        connectionId: McpConnectionId('slow'),
        pages: <McpToolPage>[
          McpToolPage(tools: <McpToolDescriptor>[scriptedTool('slow', 'wait')]),
        ],
        callDelay: const Duration(seconds: 30),
      );
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{'slow': () => connection},
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      await save(configFor('slow'));
      await manager.start();
      await waitFor(
        () => manager.snapshot.statusFor(McpConnectionId('slow'))!.isReady,
      );

      await expectLater(
        manager.callTool(
          modelToolName: 'mcp_slow__wait',
          arguments: const <String, Object?>{},
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.timeout,
          ),
        ),
      );

      final source = CancellationSource();
      Future<void>.delayed(const Duration(milliseconds: 20), source.cancel);
      await expectLater(
        manager.callTool(
          modelToolName: 'mcp_slow__wait',
          arguments: const <String, Object?>{},
          cancellation: source.token,
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.error.kind,
            'kind',
            McpErrorKind.cancelled,
          ),
        ),
      );
    });

    test('tools/list_changed refreshes the catalog atomically', () async {
      final connection = ScriptedMcpConnection(
        connectionId: McpConnectionId('paged'),
        pages: <McpToolPage>[
          McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
        ],
      );
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{'paged': () => connection},
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      await save(configFor('paged'));
      await manager.start();
      await waitFor(
        () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
      );
      expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);

      connection.replacePages(<McpToolPage>[
        McpToolPage(
          tools: <McpToolDescriptor>[
            scriptedTool('paged', 'a'),
            scriptedTool('paged', 'b'),
          ],
        ),
      ]);
      connection.triggerToolsChanged();
      await waitFor(
        () => manager.snapshot.catalog.lookup('mcp_paged__b') != null,
      );
      expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);

      connection.replacePages(<McpToolPage>[
        McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'b')]),
      ]);
      connection.triggerToolsChanged();
      await waitFor(
        () => manager.snapshot.catalog.lookup('mcp_paged__a') == null,
      );
      expect(manager.snapshot.catalog.lookup('mcp_paged__b'), isNotNull);
    });

    test(
      'host can be stopped and started again with a fresh lifecycle',
      () async {
        var created = 0;
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            <String, ScriptedMcpConnection Function()>{
              'paged': () {
                created += 1;
                return ScriptedMcpConnection(
                  connectionId: McpConnectionId('paged'),
                  pages: <McpToolPage>[
                    McpToolPage(
                      tools: <McpToolDescriptor>[scriptedTool('paged', 'a')],
                    ),
                  ],
                );
              },
            },
          ),
          repository: repository,
          secrets: InMemoryMcpSecretVault(),
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        await save(configFor('paged'));
        await manager.start();
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        await manager.stop();
        expect(
          manager.snapshot.statusFor(McpConnectionId('paged'))!.phase,
          McpConnectionPhase.stopped,
        );
        await manager.start();
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        expect(created, 2);
      },
    );

    test(
      'configuration persistence and diagnostics never contain a token',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final store = JsonlMcpConnectionStore(storage: storage);
        final diagnostics = MemoryMcpDiagnosticsSink();
        const tokenValue = 'token-value-should-never-appear';
        final vault = InMemoryMcpSecretVault(<String, String>{
          'mcp.remote.bearer': tokenValue,
        });
        await store.save(
          McpConnectionConfig(
            connectionId: McpConnectionId('remote'),
            alias: 'Remote',
            transport: McpHttpTransportConfig(
              url: 'https://mcp.example.com/mcp',
              bearerSecret: McpSecretReference.bearer(
                McpConnectionId('remote'),
              ),
            ),
          ),
          expectedRevision: 0,
          cancellation: token,
        );
        final streams = await storage.read(JsonlMcpConnectionStore.streamKey);
        final text = utf8.decode(
          (await streams!.toList()).expand((chunk) => chunk).toList(),
        );
        expect(text, isNot(contains(tokenValue)));
        expect(
          await vault.read(
            McpSecretReference.bearer(McpConnectionId('remote')),
          ),
          tokenValue,
        );

        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('remote'),
          pages: <McpToolPage>[
            McpToolPage(
              tools: <McpToolDescriptor>[scriptedTool('remote', 'ping')],
            ),
          ],
        );
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            <String, ScriptedMcpConnection Function()>{
              'remote': () => connection,
            },
          ),
          repository: store,
          secrets: vault,
          diagnostics: diagnostics,
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        await manager.start();
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('remote'))!.isReady,
        );
        final joinedDiagnostics = diagnostics.lines.join('\n');
        expect(joinedDiagnostics, isNot(contains(tokenValue)));
        expect(
          jsonEncode(manager.snapshot.connections.first.toJson()),
          isNot(contains(tokenValue)),
        );
      },
    );
  });
}
