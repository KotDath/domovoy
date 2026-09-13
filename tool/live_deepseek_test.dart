// Run explicitly: flutter test tool/live_deepseek_test.dart --reporter expanded
// Sends small paid requests. DEEPSEEK_API_KEY stays in the process environment.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global =
      null; // This explicitly invoked smoke test uses real HTTP.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});
  test(
    'live DeepSeek production usage and fresh JSONL restart',
    () async {
      final key = Platform.environment['DEEPSEEK_API_KEY'];
      expect(
        key,
        isNotNull,
        reason: 'Set DEEPSEEK_API_KEY before this explicit live test.',
      );
      final directory = await Directory.systemTemp.createTemp('domovoy-live-');
      final client = _UsageAuditClient(http.Client());
      final credentials = DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (name) => Platform.environment[name],
      );
      ProductionAgentStack stack() {
        final store = JsonlAgentSessionStore(
          storage: JsonlFilesystemStreamStorage(
            applicationSupportDirectoryResolver: () async => directory,
          ),
        );
        return buildProductionAgentStack(
          httpClient: client,
          credentials: credentials,
          repository: store,
          catalog: store,
        );
      }

      var current = stack();
      try {
        final catalog = await current.providerModelCatalog!.refresh();
        expect(
          catalog.models
              .where((model) => model.providerId == BuiltInLlmCatalog.deepSeek)
              .map((model) => model.id.value),
          containsAll(<String>['deepseek-flash', 'deepseek-v4-pro']),
        );
        final definition = AgentDefinition(
          id: AgentId('live-verification'),
          name: 'Live verification',
          systemPrompt: 'Answer briefly. Remember the user facts accurately.',
          model: current.promptDefinition.model,
          generation: LlmGenerationConfig(
            reasoningMode: ReasoningMode.disabled,
            maxOutputTokens: 128,
          ),
          limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
        );
        var session = await current.runtime
            .agent(definition)
            .createSession(persistence: SessionPersistence.repository);
        final id = session.id;
        await _run(
          session,
          'Название моего проекта — Север. Бюджет 150000 рублей. Ответь: запомнил.',
        );
        _assertWireUsage(session, client.usages.last);
        final before = session.snapshot.tokenAccounting.session.overall.value!;
        await session.close();
        await current.providerModelCatalog?.close();
        await current.runtime.close();
        current = stack();
        session = await current.runtime.agent(definition).restoreSession(id);
        expect(session.snapshot.tokenAccounting.session.overall.value, before);
        await _run(
          session,
          'Как называется мой проект и какой у него бюджет? Бюджет запиши цифрами без пробелов.',
        );
        final answer = session.snapshot.transcript.messages.last.parts
            .whereType<LlmTextPart>()
            .map((part) => part.text)
            .join();
        expect(answer.toLowerCase(), contains('север'));
        expect(answer.replaceAll(RegExp(r'\s'), ''), contains('150000'));
        _assertWireUsage(session, client.usages.last);
        expect(
          session.snapshot.tokenAccounting.session.overall.value,
          before + (client.usages.last['total_tokens'] as int),
        );
        final thinking = AgentSessionSelection(
          model: definition.model,
          reasoningMode: ReasoningMode.enabled,
          reasoningEffort: ReasoningEffort.low,
        );
        await session.changeSelection(thinking);
        await _run(session, 'Вычисли 17 * 19. Дай короткий ответ.');
        _assertWireUsage(session, client.usages.last);
        final usage = session.snapshot.tokenAccounting.latestResponse!.usage;
        final details =
            client.usages.last['completion_tokens_details']
                as Map<String, dynamic>?;
        if (details?['reasoning_tokens'] case final int reasoning) {
          expect(usage.reasoning!.value, reasoning);
          expect(
            usage.output!.value + reasoning,
            usage.responseGenerated!.value,
          );
        }
        await session.changeSelection(
          AgentSessionSelection(
            model: ModelRef(
              providerId: BuiltInLlmCatalog.deepSeek,
              modelId: ModelId('deepseek-v4-pro'),
            ),
            reasoningMode: ReasoningMode.disabled,
            reasoningEffort: ReasoningEffort.modelDefault,
          ),
        );
        await _run(session, 'Ответь одним словом: готово');
        _assertWireUsage(session, client.usages.last);
        expect(client.models.last, 'deepseek-v4-pro');
        expect(session.snapshot.tokenAccounting.byModel.length, 2);
        stdout.writeln(
          jsonEncode({
            'models': client.models,
            'raw_api_usage': client.usages,
            'restart_memory_verified': true,
            'api_usage_matches_ledger': true,
          }),
        );
        await session.close();
      } finally {
        await current.providerModelCatalog?.close();
        await current.runtime.close();
        client.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _run(AgentSession session, String text) async {
  final events = await session.run(text).events.toList();
  final failures = events.whereType<AgentRunFailed>().toList();
  expect(
    failures,
    isEmpty,
    reason: failures.map((event) => event.error.message).join('\n'),
  );
  expect(events.last, isA<AgentRunCompleted>());
}

void _assertWireUsage(AgentSession session, Map<String, dynamic> raw) {
  final usage = session.snapshot.tokenAccounting.latestResponse!.usage;
  expect(usage.requestContext!.value, raw['prompt_tokens']);
  expect(usage.responseGenerated!.value, raw['completion_tokens']);
  expect(usage.overall!.value, raw['total_tokens']);
  expect(usage.cacheRead!.value, raw['prompt_cache_hit_tokens']);
  expect(
    usage.requestContext!.value + usage.responseGenerated!.value,
    usage.overall!.value,
  );
}

class _UsageAuditClient extends http.BaseClient {
  _UsageAuditClient(this.inner);
  final http.Client inner;
  final usages = <Map<String, dynamic>>[];
  final models = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    var pending = '';
    final stream = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          pending += utf8.decode(chunk, allowMalformed: true);
          final lines = pending.split('\n');
          pending = lines.removeLast();
          for (final line in lines) {
            if (!line.startsWith('data: ') || line.trim() == 'data: [DONE]') {
              continue;
            }
            final value = jsonDecode(line.substring(6)) as Map<String, dynamic>;
            if (value['usage'] case final Map<String, dynamic> usage) {
              usages.add(usage);
              models.add(value['model'] as String);
            }
          }
          sink.add(chunk);
        },
      ),
    );
    return http.StreamedResponse(
      stream,
      response.statusCode,
      headers: response.headers,
      request: request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => inner.close();
}
