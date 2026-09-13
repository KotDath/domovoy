import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
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
}

const _metadata =
    '{"deepseek":{"models":{"deepseek-v4-pro":{"name":"DeepSeek V4 Pro","limit":{"context":1048576,"output":393216}}}}}';
