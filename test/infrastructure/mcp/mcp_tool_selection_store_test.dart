import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/config/jsonl_mcp_tool_selection_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

void main() {
  late FakeMemoryJsonlStorage storage;
  late JsonlMcpToolSelectionStore store;
  late CancellationToken token;

  setUp(() {
    storage = FakeMemoryJsonlStorage();
    store = JsonlMcpToolSelectionStore(storage: storage);
    token = CancellationSource().token;
  });

  test(
    'selections survive a restart and stay scoped per chat/project',
    () async {
      final chat = McpToolAccessTarget.chat('chat-1');
      final project = McpToolAccessTarget.project('project-1');
      await store.save(
        McpToolSelectionRecord(
          target: chat,
          toolIds: const <String>['mcp_arxiv__search_papers'],
        ),
        expectedRevision: 0,
        cancellation: token,
      );
      await store.save(
        McpToolSelectionRecord(
          target: project,
          toolIds: const <String>['mcp_digest__summarize_papers'],
        ),
        expectedRevision: 0,
        cancellation: token,
      );

      // A fresh store over the same bytes is what a restart looks like.
      final reopened = JsonlMcpToolSelectionStore(storage: storage);
      final chatRecord = (await reopened.load(chat))!;
      expect(chatRecord.toolIds, <String>['mcp_arxiv__search_papers']);
      final projectRecord = (await reopened.load(project))!;
      expect(projectRecord.toolIds, <String>['mcp_digest__summarize_papers']);
      expect(await reopened.load(McpToolAccessTarget.chat('other')), isNull);
      expect(await reopened.loadAll(), hasLength(2));
    },
  );

  test('updates and deletes replay after a restart', () async {
    final target = McpToolAccessTarget.chat('chat-1');
    await store.save(
      McpToolSelectionRecord(target: target, toolIds: const <String>['t1']),
      expectedRevision: 0,
      cancellation: token,
    );
    await store.save(
      McpToolSelectionRecord(
        target: target,
        toolIds: const <String>['t1', 't2'],
        revision: 1,
      ),
      expectedRevision: 0,
      cancellation: token,
    );

    final reopened = JsonlMcpToolSelectionStore(storage: storage);
    expect((await reopened.load(target))!.toolIds, <String>['t1', 't2']);
    expect((await reopened.load(target))!.revision, 1);

    await reopened.delete(target, expectedRevision: 1, cancellation: token);
    final afterDelete = JsonlMcpToolSelectionStore(storage: storage);
    expect(await afterDelete.load(target), isNull);
    await expectLater(
      afterDelete.save(
        McpToolSelectionRecord(target: target),
        expectedRevision: 0,
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );
    await afterDelete.save(
      McpToolSelectionRecord(target: target, revision: 2),
      expectedRevision: 1,
      cancellation: token,
    );
    final reAdded = JsonlMcpToolSelectionStore(storage: storage);
    expect((await reAdded.load(target))!.revision, 2);
    expect((await reAdded.load(target))!.toolIds, isEmpty);
  });

  test('stale writers conflict instead of overwriting', () async {
    final target = McpToolAccessTarget.project('project-1');
    await store.save(
      McpToolSelectionRecord(target: target, toolIds: const <String>['a']),
      expectedRevision: 0,
      cancellation: token,
    );
    await store.save(
      McpToolSelectionRecord(
        target: target,
        toolIds: const <String>['a', 'b'],
        revision: 1,
      ),
      expectedRevision: 0,
      cancellation: token,
    );
    await expectLater(
      store.save(
        McpToolSelectionRecord(
          target: target,
          toolIds: const <String>['stale'],
          revision: 1,
        ),
        expectedRevision: 0,
        cancellation: token,
      ),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.persistence,
        ),
      ),
    );
    expect((await store.load(target))!.toolIds, <String>['a', 'b']);
  });

  test('a truncated trailing line is ignored on replay', () async {
    final target = McpToolAccessTarget.chat('chat-1');
    await store.save(
      McpToolSelectionRecord(target: target, toolIds: const <String>['a']),
      expectedRevision: 0,
      cancellation: token,
    );
    storage.appendText(
      JsonlMcpToolSelectionStore.streamKey,
      '{"type":"domovoy.mcp_tool_selection_ope',
    );
    final reopened = JsonlMcpToolSelectionStore(storage: storage);
    final record = await reopened.load(target);
    expect(record, isNotNull);
    expect(record!.toolIds, <String>['a']);

    // The next write repairs the stream by replacing the invalid tail.
    await reopened.save(
      McpToolSelectionRecord(
        target: target,
        toolIds: const <String>['a', 'b'],
        revision: 1,
      ),
      expectedRevision: 0,
      cancellation: token,
    );
    final repaired = JsonlMcpToolSelectionStore(storage: storage);
    expect((await repaired.load(target))!.toolIds, <String>['a', 'b']);
  });

  test(
    'raw stream contains tool ids only, never secret-looking values',
    () async {
      final target = McpToolAccessTarget.chat('chat-1');
      await store.save(
        McpToolSelectionRecord(
          target: target,
          toolIds: const <String>['mcp_a__a'],
        ),
        expectedRevision: 0,
        cancellation: token,
      );
      final stream = await storage.read(JsonlMcpToolSelectionStore.streamKey);
      final chunks = await stream!.toList();
      final text = utf8.decode(chunks.expand((chunk) => chunk).toList());
      expect(text, contains('mcp_a__a'));
      expect(text, contains('domovoy.mcp_tool_selection_operation'));
      expect(text, isNot(contains('bearer')));
    },
  );
}
