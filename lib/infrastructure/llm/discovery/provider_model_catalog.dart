import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/llm/capabilities.dart';
import '../../../core/llm/catalog.dart';
import '../../../core/llm/credentials.dart';
import '../../../core/llm/generation.dart';
import '../../../core/llm/identifiers.dart';
import 'provider_manifest.dart';

final class ProviderCatalogSnapshot {
  ProviderCatalogSnapshot({
    required this.generation,
    required this.source,
    required this.refreshedAt,
    required List<LlmModel> models,
    required Map<String, String> providerIssues,
    this.stale = false,
  }) : models = List<LlmModel>.unmodifiable(models),
       providerIssues = Map<String, String>.unmodifiable(providerIssues);

  final int generation;
  final String source;
  final DateTime refreshedAt;
  final List<LlmModel> models;
  final Map<String, String> providerIssues;
  final bool stale;
}

/// Refreshes model IDs without allowing remote metadata to alter app-owned hosts.
final class ProviderModelCatalog {
  ProviderModelCatalog({
    required http.Client client,
    required ProviderCredentialResolver credentials,
    required void Function(List<LlmModel>) publishModels,
    this.metadataEndpoint = 'https://models.dev/api.json',
    Future<String> Function()? loadBundled,
    Future<String?> Function()? readCached,
    Future<void> Function(String)? writeCached,
  }) : _client = client,
       _credentials = credentials,
       _publishModels = publishModels,
       _loadBundled = loadBundled ?? _defaultLoadBundled,
       _readCached = readCached ?? _defaultReadCached,
       _writeCached = writeCached ?? _defaultWriteCached;

  static const _cacheKey = 'domovoy.provider_catalog.v1';
  static const _maxMetadataBytes = 16 * 1024 * 1024;
  static const _maxProviderBytes = 4 * 1024 * 1024;

  final http.Client _client;
  final ProviderCredentialResolver _credentials;
  final void Function(List<LlmModel>) _publishModels;
  final Future<String> Function() _loadBundled;
  final Future<String?> Function() _readCached;
  final Future<void> Function(String) _writeCached;
  final String metadataEndpoint;
  final _updates = StreamController<ProviderCatalogSnapshot>.broadcast();
  ProviderCatalogSnapshot? _snapshot;
  Map<String, Object?>? _metadata;
  var _refreshSerial = 0;
  var _closed = false;

  ProviderCatalogSnapshot? get snapshot => _snapshot;
  Stream<ProviderCatalogSnapshot> get updates => _updates.stream;

  Future<void> initialize() async {
    if (_snapshot != null || _closed) return;
    try {
      final cached = await _readCached();
      if (cached != null) {
        final parsed = jsonDecode(cached);
        if (parsed is Map<String, Object?> &&
            parsed['version'] == 1 &&
            parsed['models'] is List) {
          final models = (parsed['models'] as List)
              .map(LlmModel.fromJson)
              .toList(growable: false);
          if (models.isNotEmpty) {
            _publish(
              models,
              source: 'cached',
              issues: const <String, String>{},
              stale: true,
            );
          }
        }
      }
    } on Object {
      // A corrupt cache is ignored; the bundled catalog remains authoritative.
    }
    try {
      _metadata = _parseMetadata(await _loadBundled());
      if (_snapshot == null) {
        _publish(
          _reconcile(_metadata!, const <String, List<String>>{}),
          source: 'bundled',
          issues: const <String, String>{},
          stale: true,
        );
      }
    } on Object {
      if (_snapshot == null) {
        _publish(
          <LlmModel>[
            BuiltInLlmCatalog.deepSeekFlashModel,
            BuiltInLlmCatalog.deepSeekV4ProModel,
            ...BuiltInLlmCatalog.models.where(
              (model) => model.providerId != BuiltInLlmCatalog.deepSeek,
            ),
          ],
          source: 'minimal fallback',
          issues: const <String, String>{},
          stale: true,
        );
      }
    }
  }

  Future<ProviderCatalogSnapshot> refresh() async {
    await initialize();
    final serial = ++_refreshSerial;
    var source = 'models.dev';
    var metadataFresh = false;
    final issues = <String, String>{};
    Map<String, Object?> metadata;
    try {
      final body = await _get(
        Uri.parse(metadataEndpoint),
        const <String, String>{
          'Accept': 'application/json',
          'User-Agent': 'Domovoy/1.0',
        },
        maxBytes: _maxMetadataBytes,
      );
      metadata = _parseMetadata(body);
      _metadata = metadata;
      metadataFresh = true;
    } on Object {
      metadata = _metadata ?? _parseMetadata(await _loadBundled());
      source = 'bundled/cached';
      issues['metadata'] = 'Не удалось обновить сведения о моделях.';
    }

    final results = await Future.wait(
      ApiKeyProviderManifest.entries.map((entry) async {
        if (entry.modelsEndpoint == null) return (entry.id, null, null);
        try {
          final headers = <String, String>{'Accept': 'application/json'};
          if (!entry.publicModels) {
            final credential = await _credentials.resolve(
              providerId: ProviderId(entry.id),
              environmentVariable: entry.environmentVariable,
            );
            headers.addAll(_listingHeaders(entry, credential.value));
          }
          return (entry.id, await _fetchModelIds(entry, headers), null);
        } on LlmMissingCredentialException {
          return (entry.id, null, 'Добавьте API-ключ для проверки моделей.');
        } on Object {
          return (entry.id, null, 'Не удалось получить список моделей.');
        }
      }),
    );
    if (serial != _refreshSerial || _closed) return _snapshot!;
    final lists = <String, List<String>>{};
    for (final (id, ids, issue) in results) {
      if (ids != null) lists[id] = ids;
      if (issue != null) issues[id] = issue;
    }
    final models = _reconcile(metadata, lists);
    final present = <(String, String)>{
      for (final model in models) (model.providerId.value, model.id.value),
    };
    final lastGood = _snapshot?.models ?? const <LlmModel>[];
    for (final prior in lastGood) {
      final spec = ApiKeyProviderManifest.find(prior.providerId.value);
      if (spec == null ||
          (spec.id == 'deepseek' && prior.id.value == 'deepseek-v4-flash')) {
        continue;
      }
      // A validated metadata generation is authoritative for providers with
      // no own list endpoint. When metadata is offline, retain their cached
      // server/catalog IDs as the last good generation, including on restart.
      if (spec.modelsEndpoint == null) {
        if (metadataFresh) continue;
      } else if (lists.containsKey(prior.providerId.value)) {
        continue;
      }
      if (present.add((prior.providerId.value, prior.id.value))) {
        models.add(prior);
      }
    }
    _publish(
      models,
      source: source,
      issues: issues,
      stale: source != 'models.dev' || issues.isNotEmpty,
    );
    try {
      await _writeCached(
        jsonEncode(<String, Object?>{
          'version': 1,
          'models': models.map((model) => model.toJson()).toList(),
        }),
      );
    } on Object {
      // Cache persistence is best-effort; the published generation is usable.
    }
    return _snapshot!;
  }

  Future<void> close() async {
    _closed = true;
    _refreshSerial++;
    await _updates.close();
  }

  void _publish(
    List<LlmModel> models, {
    required String source,
    required Map<String, String> issues,
    required bool stale,
  }) {
    if (_closed) return;
    _publishModels(models);
    final next = ProviderCatalogSnapshot(
      generation: (_snapshot?.generation ?? 0) + 1,
      source: source,
      refreshedAt: DateTime.now().toUtc(),
      models: models,
      providerIssues: issues,
      stale: stale,
    );
    _snapshot = next;
    _updates.add(next);
  }

  List<LlmModel> _reconcile(
    Map<String, Object?> metadata,
    Map<String, List<String>> lists,
  ) {
    final models = <LlmModel>[];
    for (final provider in ApiKeyProviderManifest.entries) {
      final source = metadata[provider.metadataId];
      final sourceMap = source is Map ? source : const <String, Object?>{};
      final rows = sourceMap['models'] is Map
          ? sourceMap['models'] as Map
          : const <String, Object?>{};
      final ids =
          lists[provider.id] ??
          <String>[
            for (final id in rows.keys)
              if (id is String) id,
          ];
      // Pi's current Ant Ling default is absent from models.dev; no
      // documented model-list endpoint is available for this provider.
      if (provider.id == 'ant-ling' && ids.isEmpty) {
        ids.add('Ring-2.6-1T');
      }
      final seen = <String>{};
      for (final id in ids) {
        if (!seen.add(id) ||
            (provider.id == 'deepseek' && id == 'deepseek-v4-flash')) {
          continue;
        }
        final row = rows[id];
        if (_isNonChat(id, row)) continue;
        if (!_isSupportedChatCompletionModel(provider, id, row)) continue;
        try {
          models.add(_toModel(provider, id, row));
        } on Object {
          // One malformed upstream row must not poison other providers.
        }
      }
      if (provider.id == 'deepseek' &&
          lists[provider.id] == null &&
          !seen.contains('deepseek-flash')) {
        models.insert(0, BuiltInLlmCatalog.deepSeekFlashModel);
      }
    }
    return models;
  }

  LlmModel _toModel(ApiKeyProviderSpec provider, String id, Object? raw) {
    if (provider.id == 'deepseek' && id == 'deepseek-flash') {
      return BuiltInLlmCatalog.deepSeekFlashModel;
    }
    final known = BuiltInLlmCatalog.models.where(
      (model) => model.providerId.value == provider.id && model.id.value == id,
    );
    if (known.isNotEmpty) return known.first;
    final row = raw is Map ? raw : const <String, Object?>{};
    final limit = row['limit'] is Map
        ? row['limit'] as Map
        : const <String, Object?>{};
    final contextBound = limit['context'];
    final outputBound = limit['output'];
    final reasoning = _reasoningControls(provider, row);
    return LlmModel(
      providerId: ProviderId(provider.id),
      id: ModelId(id),
      name: row['name'] is String && (row['name'] as String).trim().isNotEmpty
          ? row['name'] as String
          : id,
      wireFamily: provider.wireFamily,
      capabilities: ModelCapabilities(
        supportsTextInput: true,
        reasoning: reasoning.capability,
        supportsTools: false,
        supportsTemperature: false,
        selectableEfforts: reasoning.efforts,
      ),
      contextBound: contextBound is int && contextBound > 0
          ? contextBound
          : null,
      outputBound: outputBound is int && outputBound > 0 ? outputBound : null,
    );
  }

  /// Derives reasoning controls from models.dev `reasoning_options` for
  /// providers whose wire format this app can encode. Only `effort` options
  /// are representable; toggle/budget-only models stay unavailable. A model
  /// is optional (can be turned off) only when it declares an explicit
  /// `none` effort, matching the upstream Pi catalog generator.
  static ({ModelReasoningCapability capability, List<ReasoningEffort> efforts})
  _reasoningControls(ApiKeyProviderSpec provider, Object? raw) {
    const unavailable = (
      capability: ModelReasoningCapability.unsupported,
      efforts: <ReasoningEffort>[],
    );
    if (provider.reasoningFormat == ApiKeyProviderReasoningFormat.none) {
      return unavailable;
    }
    final row = raw is Map ? raw : const <String, Object?>{};
    final options = row['reasoning_options'];
    if (options is! List) return unavailable;
    final supportsToggle = _formatSupportsLevelLessReasoning(
      provider.reasoningFormat,
    );
    final efforts = <ReasoningEffort>{};
    var canDisable = false;
    var supported = false;
    for (final option in options) {
      final map = option is Map ? option : const <String, Object?>{};
      final type = map['type'];
      if (type == 'toggle' || type == 'budget_tokens') {
        // A toggle or budget control can only be honoured by formats that can
        // express reasoning being on without a chosen level.
        if (supportsToggle) {
          supported = true;
          canDisable = true;
        }
        continue;
      }
      if (type != 'effort') continue;
      final values = map['values'];
      if (values is! List) continue;
      for (final value in values) {
        if (value == 'none') {
          canDisable = true;
          continue;
        }
        final effort = switch (value) {
          'low' => ReasoningEffort.low,
          'medium' => ReasoningEffort.medium,
          'high' => ReasoningEffort.high,
          'max' => ReasoningEffort.max,
          _ => null,
        };
        if (effort != null) {
          efforts.add(effort);
          supported = true;
        }
      }
    }
    if (!supported) return unavailable;
    return (
      capability: canDisable
          ? ModelReasoningCapability.optional
          : ModelReasoningCapability.required,
      efforts: <ReasoningEffort>[
        for (final effort in ReasoningEffort.values)
          if (efforts.contains(effort)) effort,
      ],
    );
  }

  /// Formats whose wire contract can turn reasoning on without a chosen level.
  static bool _formatSupportsLevelLessReasoning(
    ApiKeyProviderReasoningFormat format,
  ) => switch (format) {
    ApiKeyProviderReasoningFormat.deepSeekThinking ||
    ApiKeyProviderReasoningFormat.zaiThinking ||
    ApiKeyProviderReasoningFormat.qwenThinking ||
    ApiKeyProviderReasoningFormat.togetherReasoning => true,
    _ => false,
  };

  static bool _isNonChat(String id, Object? raw) {
    final row = raw is Map ? raw : const <String, Object?>{};
    final modalities = row['modalities'] is Map
        ? row['modalities'] as Map
        : const <String, Object?>{};
    final input = modalities['input'];
    final output = modalities['output'];
    if ((input is List && !input.contains('text')) ||
        (output is List && !output.contains('text'))) {
      return true;
    }
    final type = row['type'];
    if (type is String && type != 'chat' && type != 'language') return true;
    final normalized = id.toLowerCase();
    return <String>[
      'embedding',
      'whisper',
      'transcri',
      'tts',
      'dall-e',
      'image-generation',
      'moderation',
      'rerank',
    ].any(normalized.contains);
  }

  /// OpenCode Zen and OpenCode Go multiplex several wire protocols behind one
  /// gateway. Only models served by their OpenAI Chat Completions endpoint can
  /// be handled by the chat-completions transport wired up in this app; models
  /// routed to the Responses, Anthropic, or Google packages are omitted rather
  /// than sent to the wrong endpoint. This mirrors the upstream Pi/OpenCode
  /// catalog generator, including its Go-specific overrides, and requires a
  /// metadata row so an unknown protocol is skipped instead of guessed.
  static const _chatCompletionGatewayIds = <String>{'opencode', 'opencode-go'};

  /// models.dev reports these OpenCode Go models as Anthropic, but the Go
  /// gateway serves them over OpenAI Chat Completions.
  static const _goChatCompletionsOverrides = <String>{
    'minimax-m2.7',
    'qwen3.5-plus',
    'qwen3.6-plus',
  };

  static bool _isSupportedChatCompletionModel(
    ApiKeyProviderSpec provider,
    String id,
    Object? raw,
  ) {
    if (!_chatCompletionGatewayIds.contains(provider.id)) return true;
    if (raw is! Map) return false;
    if (raw['status'] == 'deprecated') return false;
    if (raw['tool_call'] != true) return false;
    if (provider.id == 'opencode-go' &&
        _goChatCompletionsOverrides.contains(id)) {
      return true;
    }
    final providerMetadata = raw['provider'];
    final npm = providerMetadata is Map ? providerMetadata['npm'] : null;
    if (npm is! String || npm.isEmpty) return true;
    return npm != '@ai-sdk/openai' &&
        npm != '@ai-sdk/anthropic' &&
        npm != '@ai-sdk/google' &&
        !npm.startsWith('@ai-sdk/google-');
  }

  static Map<String, Object?> _parseMetadata(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, Object?> ||
        !value.containsKey('deepseek') ||
        value['deepseek'] is! Map) {
      throw const FormatException('Invalid model metadata');
    }
    return value;
  }

  static List<String> _parseModelIds(String body, ApiKeyProviderSpec provider) {
    final value = jsonDecode(body);
    final rows = value is List
        ? value
        : value is Map
        ? (value['data'] ?? value['models'])
        : null;
    if (rows is! List) throw const FormatException('Invalid model listing');
    final ids = <String>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final rawId = raw['id'] ?? raw['name'];
      if (rawId is! String || rawId.trim().isEmpty) continue;
      if (provider.id == 'google') {
        final methods = raw['supportedGenerationMethods'];
        if (methods is List && !methods.contains('generateContent')) continue;
      }
      if (_isNonChat(rawId, raw)) continue;
      ids.add(rawId.startsWith('models/') ? rawId.substring(7) : rawId);
    }
    return ids;
  }

  static Map<String, String> _listingHeaders(
    ApiKeyProviderSpec provider,
    String key,
  ) => switch (provider.protocol) {
    ApiKeyProviderProtocol.anthropicMessages => <String, String>{
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
    },
    ApiKeyProviderProtocol.geminiGenerateContent => <String, String>{
      'x-goog-api-key': key,
    },
    _ => <String, String>{'Authorization': 'Bearer $key'},
  };

  Future<List<String>> _fetchModelIds(
    ApiKeyProviderSpec provider,
    Map<String, String> headers,
  ) async {
    final endpoint = Uri.parse(provider.modelsEndpoint!);
    if (provider.id != 'fireworks' &&
        provider.id != 'anthropic' &&
        provider.id != 'google') {
      return _parseModelIds(
        await _get(endpoint, headers, maxBytes: _maxProviderBytes),
        provider,
      );
    }
    final ids = <String>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final uri = cursor == null
          ? endpoint
          : endpoint.replace(
              queryParameters: <String, String>{
                ...endpoint.queryParameters,
                provider.id == 'anthropic' ? 'after_id' : 'pageToken': cursor,
              },
            );
      final body = await _get(uri, headers, maxBytes: _maxProviderBytes);
      ids.addAll(_parseModelIds(body, provider));
      final payload = jsonDecode(body);
      if (payload is! Map) throw const FormatException('Invalid model page');
      if (provider.id == 'anthropic') {
        if (payload['has_more'] != true) return ids;
        cursor = payload['last_id'] as String?;
      } else {
        cursor = payload['nextPageToken'] as String?;
      }
      if (cursor == null || cursor.isEmpty) {
        if (provider.id == 'anthropic') {
          throw const FormatException('Missing model page cursor');
        }
        return ids;
      }
    }
    throw const FormatException('Model listing exceeded page limit');
  }

  Future<String> _get(
    Uri uri,
    Map<String, String> headers, {
    required int maxBytes,
  }) async {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const FormatException('Untrusted catalog destination');
    }
    final response = await _client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.length > maxBytes) {
      throw const FormatException('Catalog request failed');
    }
    return utf8.decode(response.bodyBytes);
  }

  static Future<String> _defaultLoadBundled() =>
      rootBundle.loadString('assets/models_fallback.json');

  static Future<String?> _defaultReadCached() async =>
      (await SharedPreferences.getInstance()).getString(_cacheKey);

  static Future<void> _defaultWriteCached(String value) async {
    await (await SharedPreferences.getInstance()).setString(_cacheKey, value);
  }
}
