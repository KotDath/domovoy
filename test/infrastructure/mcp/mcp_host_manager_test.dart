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

    test(
      'built-in stream servers survive disconnect/connect/restart',
      () async {
        await manager.start();
        await waitFor(
          () => manager.snapshot.connections.every((status) => status.isReady),
        );
        final id = McpConnectionId('arxiv');
        final before = await manager.callTool(
          modelToolName: 'mcp_arxiv__search',
          arguments: const <String, Object?>{'query': 'first'},
        );
        expect(before.isError, isFalse);

        await manager.disconnect(id);
        expect(manager.snapshot.catalog.lookup('mcp_arxiv__search'), isNull);
        expect(
          manager.snapshot.statusFor(id)!.phase,
          McpConnectionPhase.stopped,
        );

        await manager.connect(id);
        await waitFor(() => manager.snapshot.statusFor(id)!.isReady);
        final after = await manager.callTool(
          modelToolName: 'mcp_arxiv__search',
          arguments: const <String, Object?>{'query': 'second'},
        );
        expect(after.structuredContent, <String, Object?>{
          'server': 'arxiv',
          'tool': 'search',
          'query': 'second',
        });

        await manager.restart(id);
        await waitFor(() => manager.snapshot.statusFor(id)!.isReady);
        final restarted = await manager.callTool(
          modelToolName: 'mcp_arxiv__search',
          arguments: const <String, Object?>{'query': 'third'},
        );
        expect(restarted.isError, isFalse);
        expect(
          (restarted.structuredContent! as Map<String, Object?>)['query'],
          'third',
        );
      },
    );
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

    test(
      'host create/update/delete/re-add follows repository revision semantics',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final managers = <McpHostManager>[];
        final repositories = <McpConnectionRepository>[
          InMemoryMcpConnectionRepository(),
          JsonlMcpConnectionStore(storage: storage),
        ];
        for (final repository in repositories) {
          final host = McpHostManager(
            transports: ScriptedMcpTransportFactory(
              const <String, ScriptedMcpConnection Function()>{},
            ),
            repository: repository,
            secrets: InMemoryMcpSecretVault(),
            reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
            delay: (duration) async {},
          );
          managers.add(host);
          final id = McpConnectionId('remote');
          final base = McpConnectionConfig(
            connectionId: id,
            alias: 'Remote',
            transport: McpInProcessStreamTransportConfig(serverId: 'remote'),
          );
          await host.upsertConnection(base, connect: false);
          final created = await repository.load(id);
          expect(
            created!.revision,
            0,
            reason: repository.runtimeType.toString(),
          );
          expect(created.alias, 'Remote');

          // Updates keep the next revision and ignore caller-supplied numbers.
          await host.upsertConnection(
            base.copyWith(alias: 'Remote 2', revision: 41),
            connect: false,
          );
          final updated = await repository.load(id);
          expect(updated!.revision, 1);
          expect(updated.alias, 'Remote 2');

          await host.removeConnection(id);
          expect(await repository.load(id), isNull);

          // Re-add after delete continues from the tombstone revision.
          await host.upsertConnection(
            base.copyWith(alias: 'Remote 3'),
            connect: false,
          );
          final restored = await repository.load(id);
          expect(restored!.revision, 2);
          expect(restored.alias, 'Remote 3');
        }
        manager = managers.first;
        for (final host in managers.skip(1)) {
          await host.stop();
          host.dispose();
        }

        // The JSONL stream replays to the same final record.
        final replayed = JsonlMcpConnectionStore(storage: storage);
        final record = await replayed.load(McpConnectionId('remote'));
        expect(record!.revision, 2);
        expect(record.alias, 'Remote 3');
      },
    );

    test(
      'catalog refresh publishes descriptor changes with a new revision',
      () async {
        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('paged'),
          pages: <McpToolPage>[
            McpToolPage(
              tools: <McpToolDescriptor>[
                scriptedTool(
                  'paged',
                  'a',
                  description: 'first description',
                  inputSchema: const <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'query': <String, Object?>{'type': 'string'},
                    },
                  },
                ),
              ],
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
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        final beforeRevision = manager.snapshot.catalog.revision;
        final beforeProperties =
            manager.snapshot.catalog
                    .lookup('mcp_paged__a')!
                    .descriptor
                    .inputSchema['properties']!
                as Map<String, Object?>;
        expect(
          (beforeProperties['query']! as Map<String, Object?>)['maxLength'],
          isNull,
        );

        // Same names, changed schema/description: the snapshot must change.
        connection.replacePages(<McpToolPage>[
          McpToolPage(
            tools: <McpToolDescriptor>[
              scriptedTool(
                'paged',
                'a',
                description: 'second description',
                inputSchema: const <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{
                    'query': <String, Object?>{
                      'type': 'string',
                      'maxLength': 10,
                    },
                  },
                },
              ),
            ],
          ),
        ]);
        connection.triggerToolsChanged();
        await waitFor(() => manager.snapshot.catalog.revision > beforeRevision);
        final route = manager.snapshot.catalog.lookup('mcp_paged__a')!;
        expect(route.descriptor.description, 'second description');
        final afterProperties =
            route.descriptor.inputSchema['properties']! as Map<String, Object?>;
        expect(
          (afterProperties['query']! as Map<String, Object?>)['maxLength'],
          10,
        );
      },
    );

    test(
      'a connect that finishes after disconnect is discarded and closed',
      () async {
        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('paged'),
          pages: <McpToolPage>[
            McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
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
        await manager.upsertConnection(configFor('paged'), connect: false);
        connection.armConnectGate();
        final connectFuture = manager.connect(McpConnectionId('paged'));
        await waitFor(() => connection.connectCount == 1);
        await manager.disconnect(McpConnectionId('paged'));
        connection.releaseConnectGate();
        await connectFuture;

        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);
        expect(connection.connected, isFalse);
        expect(connection.closeCount, greaterThanOrEqualTo(1));
        expect(
          manager.snapshot.statusFor(McpConnectionId('paged'))!.phase,
          McpConnectionPhase.stopped,
        );
      },
    );

    test(
      'refresh results that finish after disconnect never reappear',
      () async {
        final connection = ScriptedMcpConnection(
          connectionId: McpConnectionId('paged'),
          pages: <McpToolPage>[
            McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
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
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);

        connection.armListGate();
        final refresh = manager.refreshCatalog(McpConnectionId('paged'));
        await waitFor(() => connection.listedCursors.length == 2);
        await manager.disconnect(McpConnectionId('paged'));
        connection.releaseListGate();
        await refresh;
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);

        // removeConnection has the same guarantee.
        connection.replacePages(<McpToolPage>[
          McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
        ]);
        await manager.connect(McpConnectionId('paged'));
        await waitFor(
          () => manager.snapshot.statusFor(McpConnectionId('paged'))!.isReady,
        );
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNotNull);
        connection.replacePages(<McpToolPage>[
          McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
        ]);
        connection.armListGate();
        final secondRefresh = manager.refreshCatalog(McpConnectionId('paged'));
        await waitFor(() => connection.listedCursors.length == 4);
        await manager.removeConnection(McpConnectionId('paged'));
        connection.releaseListGate();
        await secondRefresh;
        expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);
        expect(manager.snapshot.statusFor(McpConnectionId('paged')), isNull);
      },
    );

    test('a connect interrupted by stop never publishes', () async {
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
      await manager.upsertConnection(configFor('paged'), connect: false);
      connection.armConnectGate();
      final connectFuture = manager.connect(McpConnectionId('paged'));
      await waitFor(() => connection.connectCount == 1);
      await manager.stop();
      connection.releaseConnectGate();
      await connectFuture;

      expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);
      expect(connection.connected, isFalse);
      expect(connection.closeCount, greaterThanOrEqualTo(1));
    });

    test('reconnect attempts increment exactly once per failure', () async {
      var created = 0;
      final delays = <Duration>[];
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{
            'paged': () {
              created += 1;
              return ScriptedMcpConnection(
                connectionId: McpConnectionId('paged'),
                connectError: McpException(
                  McpError(kind: McpErrorKind.handshake, message: 'refused'),
                ),
              );
            },
          },
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 100),
          maxDelay: Duration(seconds: 1),
        ),
        delay: (duration) async {
          delays.add(duration);
        },
      );
      await save(configFor('paged'));
      await manager.start();
      await waitFor(() => created == 3);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(created, 3);
      expect(delays, <Duration>[
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
      ]);
    });

    test(
      'corrupt stored configuration is reported instead of treated as empty',
      () async {
        final storage = FakeMemoryJsonlStorage();
        storage.replaceText(JsonlMcpConnectionStore.streamKey, 'not-json\n');
        final store = JsonlMcpConnectionStore(storage: storage);
        final diagnostics = MemoryMcpDiagnosticsSink();
        final events = <McpHostEvent>[];
        manager = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            const <String, ScriptedMcpConnection Function()>{},
          ),
          repository: store,
          secrets: InMemoryMcpSecretVault(),
          diagnostics: diagnostics,
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        final subscription = manager.events.listen(events.add);
        await expectLater(
          manager.start(),
          throwsA(
            isA<McpException>().having(
              (error) => error.error.kind,
              'kind',
              McpErrorKind.persistence,
            ),
          ),
        );
        expect(
          manager.snapshot.configurationError!.kind,
          McpErrorKind.persistence,
        );
        expect(events.whereType<McpConfigurationFailed>(), isNotEmpty);
        expect(
          diagnostics.lines.join('\n'),
          contains('configuration load failed'),
        );
        await subscription.cancel();

        // A repaired configuration can start on the same manager.
        storage.replaceText(JsonlMcpConnectionStore.streamKey, '');
        await manager.start();
        expect(manager.snapshot.configurationError, isNull);
        expect(manager.snapshot.connections, isEmpty);

        final healthy = McpHostManager(
          transports: ScriptedMcpTransportFactory(
            const <String, ScriptedMcpConnection Function()>{},
          ),
          repository: JsonlMcpConnectionStore(
            storage: FakeMemoryJsonlStorage(),
          ),
          secrets: InMemoryMcpSecretVault(),
          reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
          delay: (duration) async {},
        );
        await healthy.start();
        expect(healthy.snapshot.configurationError, isNull);
        await healthy.stop();
        healthy.dispose();
      },
    );

    test('a disconnect during a gated start is not reconnected', () async {
      var created = 0;
      final delays = <Duration>[];
      final connection = ScriptedMcpConnection(
        connectionId: McpConnectionId('paged'),
        pages: <McpToolPage>[
          McpToolPage(tools: <McpToolDescriptor>[scriptedTool('paged', 'a')]),
        ],
      );
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{
            'paged': () {
              created += 1;
              return connection;
            },
          },
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
          maxDelay: Duration(milliseconds: 2),
        ),
        delay: (duration) async {
          delays.add(duration);
        },
      );
      await save(configFor('paged'));
      connection.armConnectGate();
      final startFuture = manager.start();
      await waitFor(() => connection.connectCount == 1);
      await manager.disconnect(McpConnectionId('paged'));
      connection.releaseConnectGate();
      await startFuture;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(created, 1);
      expect(delays, isEmpty);
      expect(manager.snapshot.catalog.lookup('mcp_paged__a'), isNull);
      expect(
        manager.snapshot.statusFor(McpConnectionId('paged'))!.phase,
        McpConnectionPhase.stopped,
      );
    });

    test('re-add after a restart continues from the JSONL tombstone', () async {
      final storage = FakeMemoryJsonlStorage();
      final firstStore = JsonlMcpConnectionStore(storage: storage);
      final first = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          const <String, ScriptedMcpConnection Function()>{},
        ),
        repository: firstStore,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      final id = McpConnectionId('remote');
      final base = McpConnectionConfig(
        connectionId: id,
        alias: 'Remote',
        transport: McpInProcessStreamTransportConfig(serverId: 'remote'),
      );
      await first.upsertConnection(base, connect: false);
      await first.removeConnection(id);
      expect(await firstStore.load(id), isNull);
      await first.stop();
      first.dispose();

      // A brand new manager over the same JSONL stream must know the tombstone.
      final secondStore = JsonlMcpConnectionStore(storage: storage);
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          const <String, ScriptedMcpConnection Function()>{},
        ),
        repository: secondStore,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      await manager.start();
      expect(manager.snapshot.configurationError, isNull);
      await manager.upsertConnection(
        base.copyWith(alias: 'Remote again'),
        connect: false,
      );
      final record = await secondStore.load(id);
      expect(record!.revision, 1);
      expect(record.alias, 'Remote again');

      // The replayed stream agrees, and optimistic checks stay strict.
      final replayed = JsonlMcpConnectionStore(storage: storage);
      expect((await replayed.load(id))!.revision, 1);
      await expectLater(
        replayed.save(base, expectedRevision: 0, cancellation: token),
        throwsA(isA<McpException>()),
      );
    });

    test('a catalog collision fails only the colliding connection', () async {
      final healthy = ScriptedMcpConnection(
        connectionId: McpConnectionId('healthy'),
        pages: <McpToolPage>[
          McpToolPage(
            tools: <McpToolDescriptor>[scriptedTool('healthy', 'search')],
          ),
        ],
      );
      final broken = ScriptedMcpConnection(
        connectionId: McpConnectionId('collision'),
        pages: <McpToolPage>[
          McpToolPage(
            tools: <McpToolDescriptor>[
              scriptedTool('collision', 'x' * 80),
              scriptedTool('collision', mcpCollidingToolNames[0]),
              scriptedTool('collision', mcpCollidingToolNames[1]),
            ],
          ),
        ],
      );
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{
            'healthy': () => healthy,
            'collision': () => broken,
          },
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      await save(configFor('healthy'));
      await save(configFor('collision'));
      await manager.start();
      await waitFor(
        () => manager.snapshot.statusFor(McpConnectionId('healthy'))!.isReady,
      );
      final collisionStatus = manager.snapshot.statusFor(
        McpConnectionId('collision'),
      )!;
      expect(collisionStatus.phase, McpConnectionPhase.failed);
      expect(collisionStatus.lastError, contains('collides'));
      expect(manager.snapshot.catalog.lookup('mcp_healthy__search'), isNotNull);
      expect(
        manager.snapshot.catalog.forConnection(McpConnectionId('collision')),
        isEmpty,
      );
      expect(broken.closeCount, greaterThanOrEqualTo(1));

      // Refreshing the healthy server must not crash on the failed neighbor.
      await manager.refreshCatalog();
      expect(manager.snapshot.catalog.lookup('mcp_healthy__search'), isNotNull);
      await expectLater(
        manager.callTool(
          modelToolName: mcpCollidingModelName,
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
    });

    test('a refresh collision rolls back and keeps other servers', () async {
      final collision = ScriptedMcpConnection(
        connectionId: McpConnectionId('collision'),
        pages: <McpToolPage>[
          McpToolPage(
            tools: <McpToolDescriptor>[
              scriptedTool('collision', mcpCollidingToolNames[0]),
            ],
          ),
        ],
      );
      final healthy = ScriptedMcpConnection(
        connectionId: McpConnectionId('healthy'),
        pages: <McpToolPage>[
          McpToolPage(
            tools: <McpToolDescriptor>[scriptedTool('healthy', 'search')],
          ),
        ],
      );
      manager = McpHostManager(
        transports: ScriptedMcpTransportFactory(
          <String, ScriptedMcpConnection Function()>{
            'collision': () => collision,
            'healthy': () => healthy,
          },
        ),
        repository: repository,
        secrets: InMemoryMcpSecretVault(),
        reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
        delay: (duration) async {},
      );
      await save(configFor('collision'));
      await save(configFor('healthy'));
      await manager.start();
      await waitFor(
        () =>
            manager.snapshot.statusFor(McpConnectionId('collision'))!.isReady &&
            manager.snapshot.statusFor(McpConnectionId('healthy'))!.isReady,
      );
      expect(manager.snapshot.catalog.lookup(mcpCollidingModelName), isNotNull);
      expect(manager.snapshot.catalog.lookup('mcp_healthy__search'), isNotNull);

      // The server adds a second tool that collides with its own published
      // name; the refresh must roll back and fail only this connection.
      collision.replacePages(<McpToolPage>[
        McpToolPage(
          tools: <McpToolDescriptor>[
            scriptedTool('collision', mcpCollidingToolNames[0]),
            scriptedTool('collision', mcpCollidingToolNames[1]),
          ],
        ),
      ]);
      await manager.refreshCatalog(McpConnectionId('collision'));

      final collisionStatus = manager.snapshot.statusFor(
        McpConnectionId('collision'),
      )!;
      expect(collisionStatus.phase, McpConnectionPhase.failed);
      expect(collisionStatus.lastError, contains('collides'));
      expect(collision.closeCount, greaterThanOrEqualTo(1));
      expect(manager.snapshot.catalog.lookup(mcpCollidingModelName), isNull);
      expect(manager.snapshot.catalog.lookup('mcp_healthy__search'), isNotNull);
    });
  });
}
