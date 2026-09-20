import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/llm/discovery/provider_manifest.dart';
import 'package:domovoy/infrastructure/llm/discovery/provider_model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'server-listed new chat model survives absent metadata, old ID retires',
    () async {
      final registry = LlmProviderRegistry();
      final published = <List<LlmModel>>[];
      final client = MockClient((request) async {
        if (request.url.host == 'models.dev') {
          return http.Response(_metadata, 200);
        }
        if (request.url.host == 'api.deepseek.com') {
          expect(request.headers['Authorization'], 'Bearer private-test-key');
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'deepseek-flash'},
                <String, String>{'id': 'deepseek-v4-pro'},
                <String, String>{'id': 'deepseek-future-chat'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      addTearDown(client.close);
      final catalog = ProviderModelCatalog(
        client: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'private-test-key',
          }),
          readEnvironment: (_) => null,
        ),
        publishModels: published.add,
        loadBundled: () async => _metadata,
        readCached: () async => null,
        writeCached: (_) async {},
      );
      addTearDown(catalog.close);
      final refreshed = await catalog.refresh();
      final deepSeek = refreshed.models
          .where((model) => model.providerId.value == 'deepseek')
          .toList();
      expect(deepSeek.map((model) => model.id.value), <String>[
        'deepseek-flash',
        'deepseek-v4-pro',
        'deepseek-future-chat',
      ]);
      expect(deepSeek.last.knownContextBound, isNull);
      expect(deepSeek.last.capabilities.supportsTools, isFalse);
      expect(refreshed.providerIssues['deepseek'], isNull);
      expect(published, hasLength(2));
      expect(registry.catalogGeneration, 0);
    },
  );

  test('offline listing retains bundled model generation with issue', () async {
    final client = MockClient((_) async => http.Response('{}', 503));
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _metadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    expect(snapshot.stale, isTrue);
    expect(
      snapshot.models.any((model) => model.id.value == 'deepseek-flash'),
      isTrue,
    );
    expect(snapshot.providerIssues, contains('metadata'));
  });

  test('Fireworks documented serverless listing follows page tokens', () async {
    var pages = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_metadata, 200);
      }
      if (request.url.host == 'api.fireworks.ai') {
        expect(request.headers['Authorization'], 'Bearer fireworks-test-key');
        expect(
          request.url.queryParameters['filter'],
          'supports_serverless=true',
        );
        pages++;
        if (request.url.queryParameters['pageToken'] == null) {
          return http.Response(
            '{"models":[{"name":"accounts/fireworks/models/chat-one"}],"nextPageToken":"next"}',
            200,
          );
        }
        expect(request.url.queryParameters['pageToken'], 'next');
        return http.Response(
          '{"models":[{"name":"accounts/fireworks/models/chat-two"}]}',
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('fireworks'): 'fireworks-test-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _metadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    expect(pages, 2);
    expect(
      snapshot.models
          .where((m) => m.providerId.value == 'fireworks')
          .map((m) => m.id.value),
      <String>[
        'accounts/fireworks/models/chat-one',
        'accounts/fireworks/models/chat-two',
      ],
    );
  });

  test('Anthropic and Gemini model listings follow their own cursors', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_metadata, 200);
      }
      if (request.url.host == 'api.anthropic.com') {
        expect(request.headers['x-api-key'], 'anthropic-key');
        final after = request.url.queryParameters['after_id'];
        seen.add('anthropic:${after ?? 'first'}');
        return http.Response(
          after == null
              ? '{"data":[{"id":"claude-page-one"}],"has_more":true,"last_id":"claude-page-one"}'
              : '{"data":[{"id":"claude-page-two"}],"has_more":false}',
          200,
        );
      }
      if (request.url.host == 'generativelanguage.googleapis.com') {
        expect(request.headers['x-goog-api-key'], 'google-key');
        final page = request.url.queryParameters['pageToken'];
        seen.add('google:${page ?? 'first'}');
        return http.Response(
          page == null
              ? '{"models":[{"name":"models/gemini-page-one","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next"}'
              : '{"models":[{"name":"models/gemini-page-two","supportedGenerationMethods":["generateContent"]}]}',
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('anthropic'): 'anthropic-key',
          ProviderId('google'): 'google-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _metadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    expect(
      seen,
      containsAll(<String>[
        'anthropic:first',
        'anthropic:claude-page-one',
        'google:first',
        'google:next',
      ]),
    );
    expect(
      snapshot.models
          .where((m) => m.providerId.value == 'anthropic')
          .map((m) => m.id.value),
      <String>['claude-page-one', 'claude-page-two'],
    );
    expect(
      snapshot.models
          .where((m) => m.providerId.value == 'google')
          .map((m) => m.id.value),
      <String>['gemini-page-one', 'gemini-page-two'],
    );
  });

  test(
    'cached new server ID survives offline and retires on successful list',
    () async {
      var online = false;
      final client = MockClient((request) async {
        if (request.url.host == 'models.dev') {
          return http.Response(_metadata, 200);
        }
        if (request.url.host == 'api.deepseek.com' && online) {
          return http.Response('{"data":[{"id":"deepseek-flash"}]}', 200);
        }
        return http.Response('{}', 503);
      });
      addTearDown(client.close);
      final prior = LlmModel(
        providerId: BuiltInLlmCatalog.deepSeek,
        id: ModelId('deepseek-new-server-id'),
        name: 'New server ID',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: null,
        outputBound: null,
      );
      final catalog = ProviderModelCatalog(
        client: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'key',
          }),
          readEnvironment: (_) => null,
        ),
        publishModels: (_) {},
        loadBundled: () async => _metadata,
        readCached: () async => jsonEncode(<String, Object?>{
          'version': 1,
          'models': <Object?>[prior.toJson()],
        }),
        writeCached: (_) async {},
      );
      addTearDown(catalog.close);
      final offline = await catalog.refresh();
      expect(offline.models.any((model) => model.id == prior.id), isTrue);
      online = true;
      final fresh = await catalog.refresh();
      expect(fresh.models.any((model) => model.id == prior.id), isFalse);
    },
  );

  test(
    'cached Perplexity ID survives offline restart and retires on fresh metadata',
    () async {
      var metadataOnline = false;
      final client = MockClient((request) async {
        if (request.url.host == 'models.dev' && metadataOnline) {
          return http.Response(_metadata, 200);
        }
        return http.Response('{}', 503);
      });
      addTearDown(client.close);
      final prior = LlmModel(
        providerId: ProviderId('perplexity'),
        id: ModelId('sonar-new-after-bundle'),
        name: 'New Perplexity model',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: null,
        outputBound: null,
      );
      final cached = jsonEncode(<String, Object?>{
        'version': 1,
        'models': <Object?>[prior.toJson()],
      });
      final catalog = ProviderModelCatalog(
        client: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (_) => null,
        ),
        publishModels: (_) {},
        loadBundled: () async => _metadata,
        readCached: () async => cached,
        writeCached: (_) async {},
      );
      addTearDown(catalog.close);

      final offline = await catalog.refresh();
      expect(offline.source, 'bundled/cached');
      expect(offline.stale, isTrue);
      expect(offline.models.any((model) => model.ref == prior.ref), isTrue);

      metadataOnline = true;
      final fresh = await catalog.refresh();
      expect(fresh.source, 'models.dev');
      expect(fresh.models.any((model) => model.ref == prior.ref), isFalse);
    },
  );

  test('OpenCode Zen publishes only its chat-completions models', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_zenMetadata, 200);
      }
      if (request.url.host == 'opencode.ai') {
        expect(request.url.path, '/zen/v1/models');
        expect(request.headers['Authorization'], 'Bearer zen-test-key');
        return http.Response(
          jsonEncode(<String, Object?>{
            'object': 'list',
            'data': <Map<String, String>>[
              <String, String>{'id': 'deepseek-v4.1-flash'},
              <String, String>{'id': 'deepseek-v4-flash'},
              <String, String>{'id': 'gpt-5.5'},
              <String, String>{'id': 'claude-opus-5'},
              <String, String>{'id': 'gemini-3.8-flash'},
              <String, String>{'id': 'jev-1.13'},
              <String, String>{'id': 'glm-4.7'},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('opencode'): 'zen-test-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _zenMetadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    final zen = snapshot.models
        .where((model) => model.providerId.value == 'opencode')
        .toList();
    // Responses, Anthropic, and Google models are dropped, as are non-chat
    // (jev) and deprecated (glm-4.7) entries. Zen's own deepseek-v4-flash is
    // kept even though the DeepSeek provider hides it.
    expect(zen.map((model) => model.id.value), <String>[
      'deepseek-v4.1-flash',
      'deepseek-v4-flash',
    ]);
    expect(zen.first.wireFamily, LlmWireFamily.openaiChatCompletions);
    expect(zen.first.knownContextBound, 200000);
    expect(zen.first.capabilities.supportsTools, isFalse);
    expect(snapshot.providerIssues['opencode'], isNull);
  });

  test('catalog maps effort reasoning options onto capabilities', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_reasoningMetadata, 200);
      }
      if (request.url.host == 'opencode.ai') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'object': 'list',
            'data': <Map<String, String>>[
              <String, String>{'id': 'deepseek-v4.1-flash'},
              <String, String>{'id': 'hy3'},
              <String, String>{'id': 'kimi-k2.6'},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('opencode-go'): 'go-test-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _reasoningMetadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    final byId = <String, LlmModel>{
      for (final model in snapshot.models)
        if (model.providerId.value == 'opencode-go') model.id.value: model,
    };

    // Effort-only options cannot be turned off.
    final flash = byId['deepseek-v4.1-flash']!.capabilities;
    expect(flash.reasoning, ModelReasoningCapability.required);
    expect(flash.selectableEfforts, <ReasoningEffort>[
      ReasoningEffort.low,
      ReasoningEffort.high,
      ReasoningEffort.max,
    ]);

    // An explicit "none" effort grants an off switch.
    final hy3 = byId['hy3']!.capabilities;
    expect(hy3.reasoning, ModelReasoningCapability.optional);
    expect(hy3.selectableEfforts, <ReasoningEffort>[
      ReasoningEffort.low,
      ReasoningEffort.high,
    ]);

    // Toggle-only options are not representable.
    expect(
      byId['kimi-k2.6']!.capabilities.reasoning,
      ModelReasoningCapability.unsupported,
    );
    expect(byId['kimi-k2.6']!.capabilities.selectableEfforts, isEmpty);

    // Providers without an encodable format ignore the metadata.
    final moonshot = snapshot.models.singleWhere(
      (model) => model.id.value == 'moonshot-toggle',
    );
    expect(
      moonshot.capabilities.reasoning,
      ModelReasoningCapability.unsupported,
    );
  });

  test('catalog honours toggle and budget only for capable formats', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_formatMetadata, 200);
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _formatMetadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    ModelCapabilities capabilitiesOf(String id) => snapshot.models
        .singleWhere((model) => model.id.value == id)
        .capabilities;

    // zai can express level-less reasoning, so a toggle grants on/off.
    expect(
      capabilitiesOf('zai-toggle').reasoning,
      ModelReasoningCapability.optional,
    );
    expect(capabilitiesOf('zai-toggle').selectableEfforts, isEmpty);

    // openrouter carries levels inside a nested reasoning object.
    expect(
      capabilitiesOf('or-levels').reasoning,
      ModelReasoningCapability.required,
    );
    expect(capabilitiesOf('or-levels').selectableEfforts, <ReasoningEffort>[
      ReasoningEffort.low,
      ReasoningEffort.high,
    ]);

    // together and ant-ling declare their own envelopes.
    expect(
      capabilitiesOf('tg-toggle').reasoning,
      ModelReasoningCapability.optional,
    );
    expect(
      capabilitiesOf('al-levels').reasoning,
      ModelReasoningCapability.required,
    );

    // deepseek keeps its own thinking envelope for catalog models.
    expect(
      capabilitiesOf('ds-levels').reasoning,
      ModelReasoningCapability.required,
    );
    expect(capabilitiesOf('ds-levels').selectableEfforts, <ReasoningEffort>[
      ReasoningEffort.high,
      ReasoningEffort.max,
    ]);
  });

  test('manifest marks only encodable reasoning providers', () {
    final openAiEffort = ApiKeyProviderManifest.entries
        .where(
          (entry) =>
              entry.reasoningFormat ==
              ApiKeyProviderReasoningFormat.openAiEffort,
        )
        .map((entry) => entry.id)
        .toSet();
    expect(openAiEffort, containsAll(<String>['opencode', 'opencode-go']));
    for (final id in <String>[
      'deepseek',
      'moonshotai',
      'openrouter',
      'together',
      'zai',
      'ant-ling',
      'nvidia',
      'baseten',
      'qwen-token-plan',
      'qwen-token-plan-cn',
    ]) {
      expect(openAiEffort, isNot(contains(id)), reason: id);
    }
  });

  test('OpenCode Go applies the upstream package mapping', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_goMetadata, 200);
      }
      if (request.url.host == 'opencode.ai') {
        expect(request.url.path, '/zen/go/v1/models');
        expect(request.headers['Authorization'], 'Bearer go-test-key');
        return http.Response(
          jsonEncode(<String, Object?>{
            'object': 'list',
            'data': <Map<String, String>>[
              <String, String>{'id': 'deepseek-v4.1-flash'},
              <String, String>{'id': 'minimax-m2.7'},
              <String, String>{'id': 'qwen3.6-plus'},
              <String, String>{'id': 'qwen3.5-plus'},
              <String, String>{'id': 'minimax-m3'},
              <String, String>{'id': 'grok-4.6'},
              <String, String>{'id': 'gpt-5.6-luna'},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('opencode-go'): 'go-test-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _goMetadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    final go = snapshot.models
        .where((model) => model.providerId.value == 'opencode-go')
        .toList();
    // `minimax-m2.7` and `qwen3.6-plus` are forced to chat despite the
    // Anthropic package; `qwen3.5-plus` stays out because it is deprecated.
    expect(go.map((model) => model.id.value), <String>[
      'deepseek-v4.1-flash',
      'minimax-m2.7',
      'qwen3.6-plus',
    ]);
    expect(
      go.every(
        (model) => model.wireFamily == LlmWireFamily.openaiChatCompletions,
      ),
      isTrue,
    );
    expect(snapshot.providerIssues['opencode-go'], isNull);
  });

  test('OpenCode Zen requires a metadata row before publishing', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'models.dev') {
        return http.Response(_metadata, 200);
      }
      if (request.url.host == 'opencode.ai') {
        return http.Response(
          '{"object":"list","data":[{"id":"mystery-model"}]}',
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final catalog = ProviderModelCatalog(
      client: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('opencode'): 'zen-test-key',
        }),
        readEnvironment: (_) => null,
      ),
      publishModels: (_) {},
      loadBundled: () async => _metadata,
      readCached: () async => null,
      writeCached: (_) async {},
    );
    addTearDown(catalog.close);
    final snapshot = await catalog.refresh();
    expect(
      snapshot.models.any((model) => model.providerId.value == 'opencode'),
      isFalse,
    );
  });
}

const _metadata =
    '{"deepseek":{"models":{"deepseek-v4-pro":{"name":"DeepSeek V4 Pro","limit":{"context":1048576,"output":393216}}}}}';

const _zenMetadata =
    '{"deepseek":{"models":{"deepseek-v4-pro":{"name":"DeepSeek V4 Pro","limit":{"context":1048576,"output":393216}}}},'
    '"opencode":{"models":{'
    '"deepseek-v4.1-flash":{"name":"DeepSeek V4.1 Flash","tool_call":true,"limit":{"context":200000,"output":65536}},'
    '"deepseek-v4-flash":{"name":"DeepSeek V4 Flash","tool_call":true},'
    '"gpt-5.5":{"name":"GPT-5.5","tool_call":true,"provider":{"npm":"@ai-sdk/openai"}},'
    '"claude-opus-5":{"name":"Claude Opus 5","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"}},'
    '"gemini-3.8-flash":{"name":"Gemini 3.8 Flash","tool_call":true,"provider":{"npm":"@ai-sdk/google"}},'
    '"jev-1.13":{"name":"Jev 1.13","tool_call":false},'
    '"glm-4.7":{"name":"GLM 4.7","tool_call":true,"status":"deprecated"}'
    '}}}';

const _goMetadata =
    '{"deepseek":{"models":{"deepseek-v4-pro":{"name":"DeepSeek V4 Pro"}}},'
    '"opencode-go":{"models":{'
    '"deepseek-v4.1-flash":{"name":"DeepSeek V4.1 Flash","tool_call":true,"limit":{"context":200000,"output":65536}},'
    '"minimax-m2.7":{"name":"MiniMax M2.7","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"}},'
    '"qwen3.6-plus":{"name":"Qwen3.6 Plus","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"}},'
    '"qwen3.5-plus":{"name":"Qwen3.5 Plus","tool_call":true,"status":"deprecated","provider":{"npm":"@ai-sdk/anthropic"}},'
    '"minimax-m3":{"name":"MiniMax M3","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"}},'
    '"grok-4.6":{"name":"Grok 4.6","tool_call":true,"provider":{"npm":"@ai-sdk/openai"}},'
    '"gpt-5.6-luna":{"name":"GPT-5.6 Luna","tool_call":true,"provider":{"npm":"@ai-sdk/openai"}}'
    '}}}';

const _reasoningMetadata =
    '{"deepseek":{"models":{'
    '"deepseek-v4-flash-vision-exp":{"name":"DeepSeek V4 Flash Vision Exp","reasoning_options":[{"type":"effort","values":["low","high","max"]}]}'
    '}},'
    '"moonshotai":{"models":{'
    '"moonshot-toggle":{"name":"Moonshot","tool_call":true,"reasoning_options":[{"type":"toggle"}]}'
    '}},'
    '"opencode-go":{"models":{'
    '"deepseek-v4.1-flash":{"name":"DeepSeek V4.1 Flash","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","high","max"]}]},'
    '"hy3":{"name":"Hy3","tool_call":true,"reasoning_options":[{"type":"effort","values":["none","low","high"]}]},'
    '"kimi-k2.6":{"name":"Kimi K2.6","tool_call":true,"reasoning_options":[{"type":"toggle"}]}'
    '}}}';

const _formatMetadata =
    '{"deepseek":{"models":{'
    '"ds-levels":{"name":"DS","tool_call":true,"reasoning_options":[{"type":"effort","values":["high","max"]}]}'
    '}},'
    '"zai":{"models":{'
    '"zai-toggle":{"name":"Zai","tool_call":true,"reasoning_options":[{"type":"toggle"}]}'
    '}},'
    '"openrouter":{"models":{'
    '"or-levels":{"name":"OR","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","high"]}]}'
    '}},'
    '"togetherai":{"models":{'
    '"tg-toggle":{"name":"TG","tool_call":true,"reasoning_options":[{"type":"toggle"}]}'
    '}},'
    '"ant-ling":{"models":{'
    '"al-levels":{"name":"AL","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","high"]}]}'
    '}}}';
