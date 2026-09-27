import 'dart:async';

import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/research/research.dart'
    show LibraryRecord, summarizeLibraryRecord;
import 'package:domovoy/features/library/library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../infrastructure/mcp/servers/library/library_test_support.dart';

final class _ReadOnlyHost extends Fake implements McpHost {
  _ReadOnlyHost(this.harness, {bool available = true})
    : snapshot = McpHostSnapshot(
        revision: 1,
        connections: const [],
        catalog: McpCatalog(
          revision: 1,
          routes: [
            for (final name
                in available ? ['list_saved', 'get_saved'] : <String>[])
              McpToolRoute(
                connectionId: McpConnectionId('library'),
                modelToolName: McpModelToolName('mcp_library_$name'),
                descriptor: McpToolDescriptor(
                  connectionId: McpConnectionId('library'),
                  originalName: name,
                  inputSchema: const {},
                ),
              ),
          ],
        ),
      );

  final LibraryHarness harness;
  @override
  final McpHostSnapshot snapshot;
  final List<String> calls = [];

  @override
  Stream<McpHostEvent> get events => const Stream.empty();

  @override
  Future<McpToolCallResult> callTool({
    required String modelToolName,
    required Map<String, Object?> arguments,
    Duration? timeout,
    cancellation,
    void Function(double)? onProgress,
    Map<String, Object?>? requestMeta,
  }) {
    calls.add(modelToolName);
    return harness.call(
      modelToolName.replaceFirst('mcp_library_', ''),
      arguments: arguments,
    );
  }
}

void main() {
  test('list and detail replay through library MCP read tools', () async {
    final harness = await LibraryHarness.start();
    try {
      final saved = await harness.save(
        librarySaveArgs(runId: 'ran_0000000000000001'),
      );
      expect(saved.isError, isFalse);
      final host = _ReadOnlyHost(harness);
      final controller = LibraryController(host);
      await controller.refresh();
      expect(controller.error, isNull);
      expect(controller.cards, hasLength(1));
      expect(controller.cards.single.runId, 'ran_0000000000000001');
      await controller.open(controller.cards.single.libraryId);
      expect(
        controller.selected?.papers.single.abstractText,
        'Example abstract',
      );
      expect(controller.selected?.digest.sourceScope, 'abstract');
      expect(host.calls, ['mcp_library_list_saved', 'mcp_library_get_saved']);
      controller.dispose();

      final reopened = LibraryController(host);
      await reopened.refresh();
      expect(reopened.cards, hasLength(1));
      reopened.dispose();
    } finally {
      await harness.close();
    }
  });

  test('missing library server is a visible read error', () async {
    final harness = await LibraryHarness.start();
    try {
      final host = _ReadOnlyHost(harness, available: false);
      final controller = LibraryController(host);
      await controller.refresh();
      expect(controller.cards, isEmpty);
      expect(controller.error, contains('недоступен'));
      controller.dispose();
    } finally {
      await harness.close();
    }
  });

  test(
    'older list/detail responses cannot overwrite newer selections',
    () async {
      final host = _DeferredHost();
      final controller = LibraryController(host);
      final a = _record('a');
      final b = _record('b');
      final c = _record('c');
      final initial = controller.refresh();
      host.completeNext(_page([a, b], cursor: 'more'));
      await initial;

      final oldPage = controller.loadMore();
      final fresh = controller.refresh(search: 'new topic');
      host.completeAt(1, _page([c]));
      await fresh;
      host.completeAt(0, _page([b]));
      await oldPage;
      expect(controller.cards.map((card) => card.libraryId), [c.libraryId]);

      final openA = controller.open(a.libraryId);
      final openB = controller.open(b.libraryId);
      host.completeAt(1, b.toJson());
      await openB;
      host.completeAt(0, a.toJson());
      await openA;
      expect(controller.selected?.libraryId, b.libraryId);

      final pending = controller.refresh(search: 'pending');
      controller.dispose();
      host.completeNext(_page([a]));
      await pending;
      expect(controller.cards.map((card) => card.libraryId), [c.libraryId]);
    },
  );

  testWidgets('article URL stays selectable in the library detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _DeferredHost();
    final controller = LibraryController(host);
    final record = _record('a');
    await tester.pumpWidget(
      MaterialApp(home: LibraryPage(controller: controller)),
    );
    host.completeNext(_page([record]));
    await tester.pump();
    await tester.tap(find.text('Topic a').first);
    host.completeNext(record.toJson());
    await tester.pump();
    expect(
      find.textContaining('https://arxiv.org/abs/2501.01234'),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

LibraryRecord _record(String suffix) => LibraryRecord(
  libraryId: 'lib_${suffix.padLeft(16, '0')}',
  topic: 'Topic $suffix',
  papers: [libraryPaper()],
  digest: libraryDigest(topic: 'Topic $suffix'),
  savedAt: DateTime.utc(2026, 1, 1),
);

Map<String, Object?> _page(List<LibraryRecord> records, {String? cursor}) => {
  'schemaVersion': 1,
  'records': [
    for (final record in records) summarizeLibraryRecord(record).toJson(),
  ],
  'nextCursor': ?cursor,
  'totalCount': records.length,
};

final class _DeferredHost extends Fake implements McpHost {
  _DeferredHost()
    : snapshot = McpHostSnapshot(
        revision: 1,
        connections: const [],
        catalog: McpCatalog(
          revision: 1,
          routes: [
            for (final name in ['list_saved', 'get_saved'])
              McpToolRoute(
                connectionId: McpConnectionId('library'),
                modelToolName: McpModelToolName('mcp_library_$name'),
                descriptor: McpToolDescriptor(
                  connectionId: McpConnectionId('library'),
                  originalName: name,
                  inputSchema: const {},
                ),
              ),
          ],
        ),
      );

  @override
  final McpHostSnapshot snapshot;
  final List<Completer<McpToolCallResult>> pending = [];

  @override
  Future<McpToolCallResult> callTool({
    required String modelToolName,
    required Map<String, Object?> arguments,
    Duration? timeout,
    cancellation,
    void Function(double)? onProgress,
    Map<String, Object?>? requestMeta,
  }) {
    final completer = Completer<McpToolCallResult>();
    pending.add(completer);
    return completer.future;
  }

  void completeNext(Map<String, Object?> payload) => completeAt(0, payload);

  void completeAt(int index, Map<String, Object?> payload) {
    pending
        .removeAt(index)
        .complete(
          McpToolCallResult(
            isError: false,
            content: const [],
            structuredContent: payload,
          ),
        );
  }
}
