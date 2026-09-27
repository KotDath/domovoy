import 'dart:async';

import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/features/library/library.dart';
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
}
