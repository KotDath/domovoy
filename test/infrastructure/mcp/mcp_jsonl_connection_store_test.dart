import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/config/jsonl_mcp_connection_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

McpConnectionConfig httpConnection({int revision = 0, bool enabled = true}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId('remote'),
    alias: 'Remote',
    transport: McpHttpTransportConfig(
      url: 'https://mcp.example.com/mcp',
      bearerSecret: McpSecretReference.bearer(McpConnectionId('remote')),
    ),
    enabled: enabled,
    revision: revision,
  );
}

McpConnectionConfig streamConnection({String id = 'arxiv', int revision = 0}) {
  return McpConnectionConfig(
    connectionId: McpConnectionId(id),
    alias: id,
    transport: McpInProcessStreamTransportConfig(serverId: id),
    revision: revision,
  );
}

Future<String> rawStreamText(FakeMemoryJsonlStorage storage) async {
  final stream = await storage.read(JsonlMcpConnectionStore.streamKey);
  final chunks = await stream!.toList();
  return utf8.decode(chunks.expand((chunk) => chunk).toList());
}

void main() {
  late FakeMemoryJsonlStorage storage;
  late JsonlMcpConnectionStore store;
  late CancellationToken token;

  setUp(() {
    storage = FakeMemoryJsonlStorage();
    store = JsonlMcpConnectionStore(storage: storage);
    token = CancellationSource().token;
  });

  test(
    'persists, replays and updates connections across store instances',
    () async {
      await store.save(
        streamConnection(),
        expectedRevision: 0,
        cancellation: token,
      );
      await store.save(
        httpConnection(),
        expectedRevision: 0,
        cancellation: token,
      );

      final reopened = JsonlMcpConnectionStore(storage: storage);
      final all = await reopened.loadAll();
      expect(all.map((config) => config.connectionId.value), <String>[
        'arxiv',
        'remote',
      ]);
      expect(
        (await reopened.load(McpConnectionId('remote')))!.transport,
        isA<McpHttpTransportConfig>(),
      );

      final updated = httpConnection(revision: 1).copyWith(alias: 'Remote 2');
      await reopened.save(updated, expectedRevision: 0, cancellation: token);
      final reloaded = JsonlMcpConnectionStore(storage: storage);
      expect(
        (await reloaded.load(McpConnectionId('remote')))!.alias,
        'Remote 2',
      );

      await expectLater(
        reloaded.save(
          httpConnection(revision: 1),
          expectedRevision: 0,
          cancellation: token,
        ),
        throwsA(isA<McpException>()),
      );
    },
  );

  test('delete creates a tombstone and allows a revised re-add', () async {
    await store.save(
      streamConnection(),
      expectedRevision: 0,
      cancellation: token,
    );
    await store.delete(
      McpConnectionId('arxiv'),
      expectedRevision: 0,
      cancellation: token,
    );
    expect(await store.load(McpConnectionId('arxiv')), isNull);

    await expectLater(
      store.save(streamConnection(), expectedRevision: 0, cancellation: token),
      throwsA(isA<McpException>()),
    );

    await store.save(
      streamConnection(revision: 1).copyWith(alias: 'arXiv again'),
      expectedRevision: 0,
      cancellation: token,
    );
    expect((await store.load(McpConnectionId('arxiv')))!.alias, 'arXiv again');
  });

  test('never writes secret values, only secure-storage references', () async {
    final vault = InMemoryMcpSecretVault(<String, String>{
      'mcp.remote.bearer': 'super-secret-token',
    });
    expect(
      await vault.read(McpSecretReference.bearer(McpConnectionId('remote'))),
      'super-secret-token',
    );
    await store.save(
      httpConnection(),
      expectedRevision: 0,
      cancellation: token,
    );
    final text = await rawStreamText(storage);
    expect(text, contains('secure_storage'));
    expect(text, contains('mcp.remote.bearer'));
    expect(text, isNot(contains('super-secret-token')));
    expect(text, contains('schemaVersion'));
  });

  test('tolerates a truncated tail and rejects corrupt entries', () async {
    await store.save(
      streamConnection(),
      expectedRevision: 0,
      cancellation: token,
    );
    storage.appendText(JsonlMcpConnectionStore.streamKey, '{"type":"partial"');
    final reopened = JsonlMcpConnectionStore(storage: storage);
    expect(
      (await reopened.loadAll()).map((config) => config.connectionId.value),
      <String>['arxiv'],
    );

    storage.replaceText(JsonlMcpConnectionStore.streamKey, 'not-json\n');
    final corrupt = JsonlMcpConnectionStore(storage: storage);
    await expectLater(
      corrupt.loadAll(),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.persistence,
        ),
      ),
    );
  });

  test('stale updates from a second store writer are rejected', () async {
    await store.save(
      streamConnection(),
      expectedRevision: 0,
      cancellation: token,
    );
    final first = JsonlMcpConnectionStore(storage: storage);
    final second = JsonlMcpConnectionStore(storage: storage);
    await first.save(
      streamConnection(revision: 1).copyWith(alias: 'first'),
      expectedRevision: 0,
      cancellation: token,
    );
    await expectLater(
      second.save(
        streamConnection(revision: 1).copyWith(alias: 'second'),
        expectedRevision: 0,
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );
  });
}
