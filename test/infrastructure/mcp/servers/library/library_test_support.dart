import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/servers/library/library.dart';

import '../../../../support/memory_jsonl_storage.dart';

/// Deterministic clock for `LibraryRecord.savedAt`.
final class FakeLibraryClock implements LibraryClock {
  FakeLibraryClock([DateTime? now])
    : _now = now ?? DateTime.utc(2025, 1, 6, 12, 5);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void set(DateTime now) {
    _now = now;
  }

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

/// Deterministic, sortable identity generator for tests.
final class SequentialLibraryIdGenerator implements LibraryIdGenerator {
  SequentialLibraryIdGenerator([int start = 0]) : _counter = start;

  var _counter = 0;

  @override
  LibraryId next() {
    _counter += 1;
    return LibraryId('lib_${_counter.toRadixString(16).padLeft(32, '0')}');
  }
}

Paper libraryPaper({
  String arxivId = '2501.01234',
  String? version = 'v1',
  String title = 'Example title',
  String abstractText = 'Example abstract',
  List<String> authors = const <String>['A. Researcher'],
  List<String> categories = const <String>['cs.AI'],
}) {
  return Paper(
    arxivId: arxivId,
    version: version,
    title: title,
    authors: authors,
    abstractText: abstractText,
    categories: categories,
    publishedAt: DateTime.utc(2025, 1, 3, 17),
    updatedAt: DateTime.utc(2025, 1, 6, 17),
  );
}

Digest libraryDigest({
  String topic = 'Research topic',
  String overview = 'Short synthesis',
  List<DigestItem>? items,
  DateTime? generatedAt,
}) {
  return Digest(
    topic: topic,
    overview: overview,
    items:
        items ??
        <DigestItem>[
          DigestItem(
            arxivId: '2501.01234',
            finding: 'Finding for 2501.01234',
            limitation: 'Изучена только аннотация',
          ),
        ],
    generatedAt: generatedAt ?? DateTime.utc(2025, 1, 6, 12, 5),
  );
}

/// `save_digest` arguments as the MCP wire carries them.
Map<String, Object?> librarySaveArgs({
  String topic = 'Research topic',
  List<Paper>? papers,
  Digest? digest,
  String? runId,
}) {
  final effectivePapers = papers ?? <Paper>[libraryPaper()];
  return <String, Object?>{
    'digest': (digest ?? libraryDigest()).toJson(),
    'papers': effectivePapers
        .map((paper) => paper.toJson())
        .toList(growable: false),
    'topic': topic,
    'runId': ?runId,
  };
}

/// End-to-end harness over the in-process MCP stream transport.
final class LibraryHarness {
  LibraryHarness._({
    required this.host,
    required this.factory,
    required this.storage,
    required this.connection,
    required this.token,
  });

  static Future<LibraryHarness> start({
    FakeMemoryJsonlStorage? storage,
    LibraryRepository? repository,
    LibraryLimits limits = const LibraryLimits(),
    LibraryClock? clock,
    LibraryIdGenerator? ids,
  }) async {
    final secrets = RuntimeMcpSecretResolver();
    final diagnostics = MemoryMcpDiagnosticsSink();
    final effectiveStorage = storage ?? FakeMemoryJsonlStorage();
    final factory = repository == null
        ? LibraryMcpServerFactory(
            storage: effectiveStorage,
            limits: limits,
            clock: clock,
            ids: ids,
          )
        : LibraryMcpServerFactory.withRepository(
            repository: repository,
            limits: limits,
          );
    final host = LocalMcpServerHost(
      preference: McpLocalTransportPreference.stream,
      runtimeSecrets: secrets,
      diagnostics: diagnostics,
    );
    host.register(factory);
    await host.start(libraryServerId);
    final transportFactory = McpSdkTransportFactory(
      streams: host,
      diagnostics: diagnostics,
    );
    final connection =
        await transportFactory.create(
              host.connectionConfig(libraryServerId),
              secrets: secrets,
            )
            as McpSdkConnection;
    final cancellation = CancellationSource();
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: cancellation.token,
    );
    return LibraryHarness._(
      host: host,
      factory: factory,
      storage: effectiveStorage,
      connection: connection,
      token: cancellation.token,
    );
  }

  final LocalMcpServerHost host;
  final LibraryMcpServerFactory factory;
  final FakeMemoryJsonlStorage storage;
  final McpSdkConnection connection;
  final CancellationToken token;

  Future<List<McpToolDescriptor>> listTools() async {
    final page = await connection.listTools(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    return page.tools;
  }

  McpToolDescriptor tool(List<McpToolDescriptor> page, String name) =>
      page.firstWhere((candidate) => candidate.originalName == name);

  Future<McpToolCallResult> call(
    String tool, {
    required Map<String, Object?> arguments,
    CancellationToken? cancellation,
    Duration timeout = const Duration(seconds: 10),
  }) {
    return connection.callTool(
      originalToolName: tool,
      arguments: arguments,
      timeout: timeout,
      cancellation: cancellation ?? token,
    );
  }

  Future<McpToolCallResult> save(
    Map<String, Object?> arguments, {
    CancellationToken? cancellation,
  }) {
    return call(
      librarySaveToolName,
      arguments: arguments,
      cancellation: cancellation,
    );
  }

  Future<McpToolCallResult> list({
    Map<String, Object?> arguments = const <String, Object?>{},
  }) {
    return call(libraryListToolName, arguments: arguments);
  }

  Future<McpToolCallResult> get(
    String libraryId, {
    CancellationToken? cancellation,
  }) {
    return call(
      libraryGetToolName,
      arguments: <String, Object?>{'libraryId': libraryId},
      cancellation: cancellation,
    );
  }

  Future<void> close() async {
    await connection.close();
    await host.stopAll();
  }
}
