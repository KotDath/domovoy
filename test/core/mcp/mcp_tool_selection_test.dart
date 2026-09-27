import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CancellationToken token;

  setUp(() {
    token = CancellationSource().token;
  });

  test('targets round-trip and stay scoped by kind and id', () {
    final chat = McpToolAccessTarget.chat('chat-1');
    final project = McpToolAccessTarget.project('project-1');
    expect(chat.storeKey, 'chat:chat-1');
    expect(project.storeKey, 'project:project-1');
    expect(chat, isNot(equals(project)));
    expect(McpToolAccessTarget.fromJson(chat.toJson()), chat);
    expect(McpToolAccessTarget.fromJson(project.toJson()), project);
    expect(
      () => McpToolAccessTarget.fromJson(<String, Object?>{
        'kind': 'task',
        'id': 'x',
      }),
      throwsA(isA<McpException>()),
    );
  });

  test('records normalize tool ids and are deny-by-default', () {
    final record = McpToolSelectionRecord(
      target: McpToolAccessTarget.chat('chat-1'),
      toolIds: const <String>['mcp_b__b', 'mcp_a__a', 'mcp_a__a'],
    );
    expect(record.toolIds, <String>['mcp_a__a', 'mcp_b__b']);
    expect(record.allows('mcp_a__a'), isTrue);
    expect(record.allows('mcp_new'), isFalse);
    final decoded = McpToolSelectionRecord.fromJson(record.toJson());
    expect(decoded, record);
    expect(
      McpToolSelectionRecord(
        target: McpToolAccessTarget.project('p'),
      ).allows('anything'),
      isFalse,
    );
  });

  test('codec rejects unknown schema versions', () {
    expect(
      () => McpToolSelectionRecord.fromJson(<String, Object?>{
        'schemaVersion': 99,
        'target': <String, Object?>{'kind': 'chat', 'id': 'chat-1'},
        'toolIds': const <String>[],
        'revision': 0,
      }),
      throwsA(
        isA<McpException>().having(
          (error) => error.error.kind,
          'kind',
          McpErrorKind.unsupported,
        ),
      ),
    );
  });

  test('in-memory store enforces revisions and tombstones', () async {
    final store = InMemoryMcpToolSelectionStore();
    final target = McpToolAccessTarget.chat('chat-1');
    await store.save(
      McpToolSelectionRecord(
        target: target,
        toolIds: const <String>['mcp_a__a'],
      ),
      expectedRevision: 0,
      cancellation: token,
    );
    expect((await store.load(target))!.toolIds, <String>['mcp_a__a']);

    // A stale writer that believes it saw revision 1 must not overwrite the
    // stored revision 0 record.
    await expectLater(
      store.save(
        McpToolSelectionRecord(
          target: target,
          toolIds: const <String>['mcp_a__a'],
          revision: 2,
        ),
        expectedRevision: 1,
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );

    await store.save(
      McpToolSelectionRecord(
        target: target,
        toolIds: const <String>['mcp_a__a', 'mcp_b__b'],
        revision: 1,
      ),
      expectedRevision: 0,
      cancellation: token,
    );
    expect((await store.load(target))!.toolIds, hasLength(2));

    await store.delete(target, expectedRevision: 1, cancellation: token);
    expect(await store.load(target), isNull);
    await expectLater(
      store.save(
        McpToolSelectionRecord(target: target),
        expectedRevision: 0,
        cancellation: token,
      ),
      throwsA(isA<McpException>()),
    );
    await store.save(
      McpToolSelectionRecord(target: target, revision: 2),
      expectedRevision: 1,
      cancellation: token,
    );
    expect((await store.load(target))!.revision, 2);
    expect((await store.loadAll()), hasLength(1));
  });
}
