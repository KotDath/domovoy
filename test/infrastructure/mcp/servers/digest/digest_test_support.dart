import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/servers/digest/digest.dart';

/// Deterministic clock for `Digest.generatedAt`.
final class FakeDigestClock implements DigestClock {
  FakeDigestClock([DateTime? now])
    : _now = now ?? DateTime.utc(2025, 1, 6, 12, 5);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

/// Provider whose answer depends on the requested model id and that can hold
/// each model's stream open until the test releases it.
final class ModelScriptedLlmProvider implements LlmProvider {
  ModelScriptedLlmProvider({
    required this.id,
    required this.wireFamily,
    Map<String, List<LlmEvent>>? turnsByModel,
    Map<String, Completer<void>>? gates,
  }) : turnsByModel = <String, List<LlmEvent>>{...?turnsByModel},
       gates = <String, Completer<void>>{...?gates};

  @override
  final ProviderId id;

  @override
  final LlmWireFamily wireFamily;

  final Map<String, List<LlmEvent>> turnsByModel;
  final Map<String, Completer<void>> gates;
  final List<LlmRequest> requests = <LlmRequest>[];

  void script(String modelId, List<LlmEvent> events) {
    turnsByModel[modelId] = events;
  }

  void gate(String modelId) {
    gates.putIfAbsent(modelId, () => Completer<void>());
  }

  void release(String modelId) {
    final gate = gates.remove(modelId);
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    if (cancellation.isCancelled) {
      yield const LlmCancelled();
      return;
    }
    final gate = gates[request.model.modelId.value];
    if (gate != null) {
      await Future.any<void>(<Future<void>>[
        gate.future,
        cancellation.whenCancelled,
      ]);
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
    }
    final events =
        turnsByModel[request.model.modelId.value] ??
        const <LlmEvent>[LlmCompleted(finishReason: LlmFinishReason.stop)];
    for (final event in events) {
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
      yield event;
      if (event.isTerminal) {
        return;
      }
    }
  }
}

/// Registry with the built-in catalog plus [provider].
LlmProviderRegistry digestRegistryWith(LlmProvider provider) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(provider);
  return registry;
}

/// DeepSeek-compatible scripted provider over the built-in catalog.
ModelScriptedLlmProvider digestProvider() => ModelScriptedLlmProvider(
  id: BuiltInLlmCatalog.deepSeek,
  wireFamily: LlmWireFamily.openaiChatCompletions,
);

/// Two pinned models of the same provider, used for isolation tests.
final digestModelA = BuiltInLlmCatalog.deepSeekV4FlashModel.ref;
final digestModelB = BuiltInLlmCatalog.deepSeekV4ProModel.ref;

const digestModelAId = 'deepseek-v4-flash';
const digestModelBId = 'deepseek-v4-pro';

Paper digestPaper({
  String arxivId = '2501.01234',
  String? version = 'v1',
  String title = 'Example title',
  String abstractText = 'Example abstract',
  List<String> categories = const <String>['cs.AI'],
}) {
  return Paper(
    arxivId: arxivId,
    version: version,
    title: title,
    authors: const <String>['A. Researcher'],
    abstractText: abstractText,
    categories: categories,
    publishedAt: DateTime.utc(2025, 1, 3, 17),
    updatedAt: DateTime.utc(2025, 1, 6, 17),
  );
}

/// One `items` entry of a scripted model answer.
Map<String, Object?> digestAnswerItem(
  String arxivId, {
  String? finding,
  String? limitation = 'Изучена только аннотация',
}) {
  return <String, Object?>{
    'arxivId': arxivId,
    'finding': finding ?? 'Finding for $arxivId',
    'limitation': ?limitation,
  };
}

/// Scripted model answer for one invocation.
String digestAnswerJson({
  String topic = 'Research topic',
  String overview = 'Short synthesis',
  required List<Map<String, Object?>> items,
}) {
  return jsonEncode(<String, Object?>{
    'topic': topic,
    'overview': overview,
    'items': items,
  });
}

/// Successful scripted provider turn carrying one digest answer.
List<LlmEvent> digestTurn(String answer, {LlmUsage? usage}) {
  return <LlmEvent>[
    LlmTextDelta(answer),
    LlmCompleted(finishReason: LlmFinishReason.stop, usage: usage),
  ];
}

/// Resolver returning queued pins, one per invocation, and recording scopes.
final class QueueDigestPinResolver implements DigestModelPinResolver {
  QueueDigestPinResolver(this._pins);

  final List<DigestModelPin?> _pins;
  final List<DigestInvocationScope> scopes = <DigestInvocationScope>[];
  var _index = 0;

  @override
  DigestModelPin? resolve(DigestInvocationScope scope) {
    scopes.add(scope);
    if (_index >= _pins.length) {
      return null;
    }
    return _pins[_index++];
  }
}

/// End-to-end harness over the in-process MCP stream transport.
final class DigestHarness {
  DigestHarness._({
    required this.host,
    required this.factory,
    required this.provider,
    required this.pins,
    required this.connection,
    required this.token,
  });

  static Future<DigestHarness> start({
    required LlmProviderRegistry registry,
    required ModelScriptedLlmProvider provider,
    required DigestModelPinResolver pins,
    DigestLimits limits = const DigestLimits(),
    DigestClock? clock,
  }) async {
    final secrets = RuntimeMcpSecretResolver();
    final diagnostics = MemoryMcpDiagnosticsSink();
    final factory = DigestMcpServerFactory(
      registry: registry,
      pins: pins,
      limits: limits,
      clock: clock,
    );
    final host = LocalMcpServerHost(
      preference: McpLocalTransportPreference.stream,
      runtimeSecrets: secrets,
      diagnostics: diagnostics,
    );
    host.register(factory);
    await host.start(digestServerId);
    final transportFactory = McpSdkTransportFactory(
      streams: host,
      diagnostics: diagnostics,
    );
    final connection =
        await transportFactory.create(
              host.connectionConfig(digestServerId),
              secrets: secrets,
            )
            as McpSdkConnection;
    final cancellation = CancellationSource();
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: cancellation.token,
    );
    return DigestHarness._(
      host: host,
      factory: factory,
      provider: provider,
      pins: pins,
      connection: connection,
      token: cancellation.token,
    );
  }

  final LocalMcpServerHost host;
  final DigestMcpServerFactory factory;
  final ModelScriptedLlmProvider provider;
  final DigestModelPinResolver pins;
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

  Future<void> close() async {
    await connection.close();
    await host.stopAll();
  }
}
